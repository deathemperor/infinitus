import type { InfinitusLaunchResult } from "@t3tools/contracts/infinitus";
import { resolveWorktreeT3Home } from "@t3tools/shared/devHome";
import { HostProcessPlatform } from "@t3tools/shared/hostProcess";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

import { ServerConfig } from "../../config.ts";
import { forkParked } from "../../serverActivation.ts";
import {
  InfinitusCompanion,
  type InfinitusCompanionShape,
} from "../Services/InfinitusCompanion.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import { serverPortWithheldReason } from "./InfinitusServerPort.ts";

/** The menu-bar app's bundle id; LaunchServices finds the app by it, so no
    path is ever assumed (the user may keep it anywhere). */
const INFINITUS_BUNDLE_ID = "run.infinitus";
/** How long the socket may stay quiet after the server starts before the app
    is opened for the user (#654 step 1). */
export const STARTUP_GRACE = Duration.seconds(3);

/** `open` could not be spawned or waited for at all (as opposed to exiting
    non-zero, which is an exit code). */
export class InfinitusOpenFailed extends Schema.TaggedError<InfinitusOpenFailed>()(
  "InfinitusOpenFailed",
  { cause: Schema.Defect() },
) {
  override get message(): string {
    return `open failed: ${this.cause instanceof Error ? this.cause.message : String(this.cause)}`;
  }
}

/** What the startup probe and `launch` share: the host platform, and one run
    of `open -g -b run.infinitus` answering with its exit code. */
export interface InfinitusLaunchDeps {
  readonly platform: NodeJS.Platform;
  readonly runOpen: Effect.Effect<number, InfinitusOpenFailed>;
}

/** Whether `status` answered. Any reply — a failed command included — means
    the app is there; only an unreachable socket is `unavailable`. */
const probeInfinitus = Effect.fn("Infinitus.probe")(function* () {
  const client = yield* InfinitusControlClient;
  return yield* client.request({ command: "status" }).pipe(
    Effect.as("answering" as const),
    Effect.catchTag("InfinitusUnavailable", () => Effect.succeed("unavailable" as const)),
    Effect.catch(() => Effect.succeed("answering" as const)),
  );
});

/** Runs `open` once and reads its exit code into a result. */
const openInfinitus = (runOpen: InfinitusLaunchDeps["runOpen"]) =>
  runOpen.pipe(
    Effect.map((exitCode): InfinitusLaunchResult =>
      exitCode === 0 ? { launched: true } : { launched: false, reason: `open exited ${exitCode}` },
    ),
    Effect.catch((error) =>
      Effect.succeed<InfinitusLaunchResult>({ launched: false, reason: error.message }),
    ),
  );

/** The `infinitus.launch` body: refuses off macOS and without a socket path,
    leaves a running app alone, otherwise opens it. */
export const launchInfinitus = Effect.fn("Infinitus.launch")(function* (
  deps: InfinitusLaunchDeps,
): Effect.fn.Return<InfinitusLaunchResult, never, InfinitusControlClient> {
  if (deps.platform !== "darwin") {
    return { launched: false, reason: "Infinitus runs on macOS only" };
  }
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) {
    return { launched: false, reason: "this host has no Infinitus control socket" };
  }
  if ((yield* probeInfinitus()) === "answering") {
    return { launched: false, reason: "Infinitus is already running" };
  }
  return yield* openInfinitus(deps.runOpen);
});

/**
 * The startup companion: a socket still quiet after `STARTUP_GRACE` gets the
 * app opened once, with one log line either way. No retry, no loop — a user
 * who quits the menu-bar app afterwards keeps it quit (that is what the
 * "Launch Infinitus" button is for).
 */
export const launchInfinitusAtStartup = Effect.fn("Infinitus.launchAtStartup")(function* (
  deps: InfinitusLaunchDeps,
): Effect.fn.Return<InfinitusLaunchResult | null, never, InfinitusControlClient> {
  if (deps.platform !== "darwin") return null;
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) return null;
  if ((yield* probeInfinitus()) === "answering") return null;
  yield* Effect.sleep(STARTUP_GRACE);
  if ((yield* probeInfinitus()) === "answering") return null;
  const result = yield* openInfinitus(deps.runOpen);
  yield* Effect.logInfo("infinitus.companion.launch", result);
  return result;
});

const makeRunOpen = Effect.gen(function* () {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  // `-g` keeps the desktop window in front: the menu-bar app has no window to
  // bring forward anyway. `-b` is the bundle id, so LaunchServices does the
  // finding.
  return Effect.scoped(
    Effect.gen(function* () {
      const child = yield* spawner.spawn(
        ChildProcess.make("open", ["-g", "-b", INFINITUS_BUNDLE_ID], {
          shell: false,
          stdout: "ignore",
          stderr: "ignore",
        }),
      );
      return Number(yield* child.exitCode);
    }).pipe(Effect.mapError((cause) => new InfinitusOpenFailed({ cause }))),
  );
});

const InfinitusCompanionServiceLive = Layer.effect(
  InfinitusCompanion,
  Effect.gen(function* () {
    const platform = yield* HostProcessPlatform;
    const client = yield* InfinitusControlClient;
    const runOpen = yield* makeRunOpen;
    return {
      launch: launchInfinitus({ platform, runOpen }).pipe(
        Effect.provideService(InfinitusControlClient, client),
      ),
    } satisfies InfinitusCompanionShape;
  }),
);

/** The startup launch, for the installed server only: a dev-runner or
    worktree server says why it stays quiet, exactly like the port publish. */
const InfinitusCompanionStartupLive = Layer.effectDiscard(
  forkParked(
    Effect.gen(function* () {
      const config = yield* ServerConfig;
      const reason = serverPortWithheldReason({
        devUrl: config.devUrl,
        baseDir: config.baseDir,
        worktreeT3Home: yield* resolveWorktreeT3Home(config.baseDir),
      });
      if (reason !== undefined) {
        yield* Effect.logInfo("infinitus.companion.withheld", { reason });
        return;
      }
      const platform = yield* HostProcessPlatform;
      const runOpen = yield* makeRunOpen;
      yield* launchInfinitusAtStartup({ platform, runOpen });
    }),
  ),
);

export const InfinitusCompanionLive = Layer.mergeAll(
  InfinitusCompanionServiceLive,
  InfinitusCompanionStartupLive,
);
