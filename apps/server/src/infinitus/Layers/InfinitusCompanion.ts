import type { InfinitusLaunchResult } from "@t3tools/contracts/infinitus";
import { resolveWorktreeT3Home } from "@t3tools/shared/devHome";
import { HostProcessEnvironment, HostProcessPlatform } from "@t3tools/shared/hostProcess";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";

import { ServerConfig } from "../../config.ts";
import { forkParked } from "../../serverActivation.ts";
import { collectUint8StreamText } from "../../stream/collectUint8StreamText.ts";
import {
  InfinitusCompanion,
  type InfinitusCompanionShape,
} from "../Services/InfinitusCompanion.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import { serverPortWithheldReason } from "./InfinitusServerPort.ts";

/** The menu-bar app's bundle id; LaunchServices finds the app by it, so no
    path is ever assumed (the user may keep it anywhere). */
const INFINITUS_BUNDLE_ID = "run.infinitus";
/** Where the fork's desktop bundle nests the menu-bar app (#777): the one
    path `SMAppService.loginItem` accepts. The desktop names its own bundle in
    `INFINITUS_DESKTOP_BUNDLE`; CLI and dev servers never set it. */
const NESTED_HELPER_RELATIVE_PATH = "Contents/Library/LoginItems/Infinitus Menu Bar.app";
/** How long the socket may stay quiet after the server starts before the app
    is opened for the user (#654 step 1). */
export const STARTUP_GRACE = Duration.seconds(3);
/** A socket file that refuses is re-probed this often, this many times, before
    it counts as stale (20 s in all): a relaunching Infinitus rebinds within
    seconds, a crash's leftover never does (#637). */
export const RELAUNCH_REPROBE = Duration.seconds(2);
export const RELAUNCH_REPROBES = 10;

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

/** One finished run of `open`: its exit code and what it printed to stderr. */
export interface InfinitusOpenOutcome {
  readonly exitCode: number;
  readonly stderr: string;
}

/** What one `open` run is asked to open: the bundle id (LaunchServices finds
    the app, wherever it is) or the nested helper's path (a bundle
    LaunchServices has not indexed yet, right after a DMG install). */
export type InfinitusOpenTarget =
  | { readonly by: "bundleId" }
  | { readonly by: "path"; readonly path: string };

/** The helper nested in the desktop bundle, as shipped: its path and the
    version its Info.plist carries. */
export interface InfinitusNestedHelper {
  readonly path: string;
  readonly version: string;
}

/** What the startup probe and `launch` share: the host platform, one run of
    `open -g` for a target answering with its exit code and stderr, and the
    nested helper (null on CLI and dev servers, and on a desktop that nests
    nothing). */
export interface InfinitusLaunchDeps {
  readonly platform: NodeJS.Platform;
  readonly runOpen: (
    target: InfinitusOpenTarget,
  ) => Effect.Effect<InfinitusOpenOutcome, InfinitusOpenFailed>;
  readonly nested: InfinitusNestedHelper | null;
}

/** What one `status` probe found. Any reply — a failed command included —
    means the app is there (`answering`). An unreachable socket is `gone` when
    the path does not exist (ENOENT) and `refusing` when it does but nobody
    listens (ECONNREFUSED, a hang-up, EACCES): the app never unlinks its
    socket, so a quitting or relaunching Infinitus leaves the file behind
    until the next instance rebinds it (#637). */
type Probe =
  | { readonly state: "answering"; readonly reply: unknown }
  | { readonly state: "gone" }
  | { readonly state: "refusing"; readonly path: string; readonly cause: string };

const probeInfinitus = Effect.fn("Infinitus.probe")(function* () {
  const client = yield* InfinitusControlClient;
  return yield* client.request({ command: "status" }).pipe(
    Effect.map<unknown, Probe>((reply) => ({ state: "answering", reply })),
    Effect.catchTag("InfinitusUnavailable", (error) =>
      Effect.succeed<Probe>(
        error.cause === "ENOENT"
          ? { state: "gone" }
          : { state: "refusing", path: error.path, cause: error.cause },
      ),
    ),
    Effect.catch(() => Effect.succeed<Probe>({ state: "answering", reply: undefined })),
  );
});

/** Reads one `open` run into a result. A non-zero exit whose stderr names the
    bundle id is LaunchServices saying no such app is installed (#731); any
    other failure keeps its first stderr line so the user reads more than an
    exit code. */
const launchResultFromOpen = (outcome: InfinitusOpenOutcome): InfinitusLaunchResult => {
  if (outcome.exitCode === 0) return { launched: true };
  if (outcome.stderr.includes(INFINITUS_BUNDLE_ID)) {
    return {
      launched: false,
      installed: false,
      reason: "No Infinitus app is installed on this Mac.",
    };
  }
  const detail = outcome.stderr.trim().split("\n")[0] ?? "";
  return {
    launched: false,
    reason:
      detail === ""
        ? `open exited ${outcome.exitCode}`
        : `open exited ${outcome.exitCode}: ${detail}`,
  };
};

/** Runs `open` once for a target and reads its outcome into a result. */
const openTarget = (runOpen: InfinitusLaunchDeps["runOpen"], target: InfinitusOpenTarget) =>
  runOpen(target).pipe(
    Effect.map(launchResultFromOpen),
    Effect.catch((error) =>
      Effect.succeed<InfinitusLaunchResult>({ launched: false, reason: error.message }),
    ),
  );

/** Opens the app: the nested helper by path first when there is one (a
    brew-cask copy may still carry the same bundle id, #7, and a fresh DMG
    install is not in LaunchServices yet), the bundle id otherwise or as the
    fallback. */
const openInfinitus = Effect.fn("Infinitus.open")(function* (deps: InfinitusLaunchDeps) {
  if (deps.nested === null) return yield* openTarget(deps.runOpen, { by: "bundleId" });
  const byPath = yield* openTarget(deps.runOpen, { by: "path", path: deps.nested.path });
  return byPath.launched ? byPath : yield* openTarget(deps.runOpen, { by: "bundleId" });
});

/** The fields of a `status` reply the reconcile reads; a helper from before
    `bundlePath` (#777) reports none. */
const readStatusIdentity = (reply: unknown): { version?: string; bundlePath?: string } => {
  if (typeof reply !== "object" || reply === null) return {};
  const { version, bundlePath } = reply as { version?: unknown; bundlePath?: unknown };
  return {
    ...(typeof version === "string" ? { version } : {}),
    ...(typeof bundlePath === "string" ? { bundlePath } : {}),
  };
};

/**
 * The desktop updater installs by moving bundles, so a helper started from
 * the nested bundle keeps running on the old version after an update, at a
 * path that now holds the new one (#777). When the answering helper says it
 * came from our nested bundle and its version is not the one we ship, it is
 * quit (the existing verb), the socket is re-probed until it stops answering
 * (a second `open` on top of a shutting-down app is the #637 race), and the
 * nested bundle is opened by path. A standalone Infinitus (a brew-cask copy,
 * #7) is left alone whatever its version, and a helper that predates
 * `bundlePath` only gets its skew logged: the rule is not armed on a guess.
 */
const reconcileNestedHelper = Effect.fn("Infinitus.reconcile")(function* (
  deps: InfinitusLaunchDeps,
  nested: InfinitusNestedHelper,
  reply: unknown,
): Effect.fn.Return<InfinitusLaunchResult | null, never, InfinitusControlClient> {
  const identity = readStatusIdentity(reply);
  if (identity.version === undefined || identity.version === nested.version) return null;
  if (identity.bundlePath === undefined) {
    yield* Effect.logInfo("infinitus.companion.skew-unarmed", {
      running: identity.version,
      shipped: nested.version,
    });
    return null;
  }
  if (identity.bundlePath !== nested.path) return null;
  const client = yield* InfinitusControlClient;
  const quit = yield* client.request({ command: "quit" }).pipe(Effect.option);
  if (quit._tag === "None") {
    yield* Effect.logWarning("infinitus.companion.stale-helper-quit-failed", {
      running: identity.version,
      shipped: nested.version,
    });
    return null;
  }
  let probe: Probe = { state: "answering", reply };
  for (let attempt = 0; attempt < RELAUNCH_REPROBES && probe.state === "answering"; attempt++) {
    yield* Effect.sleep(RELAUNCH_REPROBE);
    probe = yield* probeInfinitus();
  }
  if (probe.state === "answering") {
    yield* Effect.logWarning("infinitus.companion.stale-helper-still-up", {
      running: identity.version,
      waited: Duration.format(Duration.times(RELAUNCH_REPROBE, RELAUNCH_REPROBES)),
    });
    return null;
  }
  const result = yield* openTarget(deps.runOpen, { by: "path", path: nested.path });
  yield* Effect.logInfo("infinitus.companion.stale-helper-reopened", {
    running: identity.version,
    shipped: nested.version,
    ...result,
  });
  return result;
});

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
  if ((yield* probeInfinitus()).state === "answering") {
    return { launched: false, reason: "Infinitus is already running" };
  }
  return yield* openInfinitus(deps);
});

/** Waits out a socket file that refuses: an Infinitus mid-relaunch (its own
    reopen shell runs `open` once the old pid exits; a second `open` on top is
    the race of #637/#756) rebinds within seconds, so the file is re-probed
    until it answers, vanishes, or the window runs out — then it is a crash's
    stale leftover and the app is as gone as with no file at all. */
const awaitRelaunch = Effect.fn("Infinitus.awaitRelaunch")(function* (
  first: Extract<Probe, { state: "refusing" }>,
): Effect.fn.Return<Probe, never, InfinitusControlClient> {
  let probe: Probe = first;
  for (let attempt = 0; attempt < RELAUNCH_REPROBES && probe.state === "refusing"; attempt++) {
    yield* Effect.sleep(RELAUNCH_REPROBE);
    probe = yield* probeInfinitus();
  }
  if (probe.state === "refusing") {
    yield* Effect.logInfo("infinitus.companion.stale-socket", {
      path: probe.path,
      cause: probe.cause,
      waited: Duration.format(Duration.times(RELAUNCH_REPROBE, RELAUNCH_REPROBES)),
    });
  }
  return probe;
});

/**
 * The startup companion: a socket still quiet after `STARTUP_GRACE` gets the
 * app opened once, with one log line either way. No retry, no loop — a user
 * who quits the menu-bar app afterwards keeps it quit (that is what the
 * "Launch Infinitus" button is for). A socket file that refuses gets the
 * relaunch window first (`awaitRelaunch`).
 */
export const launchInfinitusAtStartup = Effect.fn("Infinitus.launchAtStartup")(function* (
  deps: InfinitusLaunchDeps,
): Effect.fn.Return<InfinitusLaunchResult | null, never, InfinitusControlClient> {
  if (deps.platform !== "darwin") return null;
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) return null;
  const first = yield* probeInfinitus();
  if (first.state === "answering") {
    return deps.nested === null
      ? null
      : yield* reconcileNestedHelper(deps, deps.nested, first.reply);
  }
  yield* Effect.sleep(STARTUP_GRACE);
  let probe = yield* probeInfinitus();
  if (probe.state === "refusing") probe = yield* awaitRelaunch(probe);
  if (probe.state === "answering") return null;
  const result = yield* openInfinitus(deps);
  yield* Effect.logInfo("infinitus.companion.launch", result);
  return result;
});

const makeRunOpen = Effect.gen(function* () {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  // `-g` keeps the desktop window in front: the menu-bar app has no window to
  // bring forward anyway. `-b` is the bundle id, so LaunchServices does the
  // finding; `-a` is the nested helper by path.
  return (target: InfinitusOpenTarget) =>
    Effect.scoped(
      Effect.gen(function* () {
        const child = yield* spawner.spawn(
          ChildProcess.make(
            "open",
            target.by === "path" ? ["-g", "-a", target.path] : ["-g", "-b", INFINITUS_BUNDLE_ID],
            {
              shell: false,
              stdout: "ignore",
            },
          ),
        );
        // stderr is where `open` says why it could not (#731); read it alongside
        // the exit so a chatty child never blocks on a full pipe.
        const [stderr, exitCode] = yield* Effect.all(
          [collectUint8StreamText({ stream: child.stderr, maxBytes: 4_096 }), child.exitCode],
          { concurrency: "unbounded" },
        );
        return { exitCode: Number(exitCode), stderr: stderr.text } satisfies InfinitusOpenOutcome;
      }).pipe(Effect.mapError((cause) => new InfinitusOpenFailed({ cause }))),
    );
});

/** The nested helper the desktop ships, from `INFINITUS_DESKTOP_BUNDLE`: its
    path, and the version PlistBuddy reads off its Info.plist (the server
    parses no plist itself). Null when the env is unset (CLI, dev runner),
    the bundle nests nothing, or the read fails (logged). */
const resolveNestedHelper = Effect.gen(function* () {
  const env = yield* HostProcessEnvironment;
  const bundle = env.INFINITUS_DESKTOP_BUNDLE?.trim();
  if (!bundle) return null;
  const path = yield* Path.Path;
  const fileSystem = yield* FileSystem.FileSystem;
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const helperPath = path.join(bundle, NESTED_HELPER_RELATIVE_PATH);
  const plist = path.join(helperPath, "Contents/Info.plist");
  if (!(yield* fileSystem.exists(plist).pipe(Effect.orElseSucceed(() => false)))) return null;
  const version = yield* Effect.scoped(
    Effect.gen(function* () {
      const child = yield* spawner.spawn(
        ChildProcess.make(
          "/usr/libexec/PlistBuddy",
          ["-c", "Print CFBundleShortVersionString", plist],
          { shell: false, stderr: "ignore" },
        ),
      );
      const [stdout, exitCode] = yield* Effect.all(
        [collectUint8StreamText({ stream: child.stdout, maxBytes: 4_096 }), child.exitCode],
        { concurrency: "unbounded" },
      );
      return Number(exitCode) === 0 ? stdout.text.trim() : "";
    }),
  ).pipe(Effect.orElseSucceed(() => ""));
  if (version === "") {
    yield* Effect.logWarning("infinitus.companion.nested-version-unread", { helperPath });
    return null;
  }
  return { path: helperPath, version } satisfies InfinitusNestedHelper;
});

const InfinitusCompanionServiceLive = Layer.effect(
  InfinitusCompanion,
  Effect.gen(function* () {
    const platform = yield* HostProcessPlatform;
    const client = yield* InfinitusControlClient;
    const runOpen = yield* makeRunOpen;
    const nested = yield* resolveNestedHelper;
    return {
      launch: launchInfinitus({ platform, runOpen, nested }).pipe(
        Effect.provideService(InfinitusControlClient, client),
      ),
    } satisfies InfinitusCompanionShape;
  }),
);

/** The startup launch, for the installed server only: a dev-runner server, a
    worktree server or an isolated instance (an `INFINITUS_CONTROL_SOCKET`
    override) says why it stays quiet, exactly like the port publish. */
const InfinitusCompanionStartupLive = Layer.effectDiscard(
  forkParked(
    Effect.gen(function* () {
      const config = yield* ServerConfig;
      const env = yield* HostProcessEnvironment;
      const reason = serverPortWithheldReason({
        devUrl: config.devUrl,
        baseDir: config.baseDir,
        worktreeT3Home: yield* resolveWorktreeT3Home(config.baseDir),
        controlSocketOverride: env.INFINITUS_CONTROL_SOCKET,
      });
      if (reason !== undefined) {
        yield* Effect.logInfo("infinitus.companion.withheld", { reason });
        return;
      }
      const platform = yield* HostProcessPlatform;
      const runOpen = yield* makeRunOpen;
      const nested = yield* resolveNestedHelper;
      yield* launchInfinitusAtStartup({ platform, runOpen, nested });
    }),
  ),
);

export const InfinitusCompanionLive = Layer.mergeAll(
  InfinitusCompanionServiceLive,
  InfinitusCompanionStartupLive,
);
