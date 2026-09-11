/**
 * Quit the menu-bar app with this window (#654 step 1). On the app's
 * `before-quit`, when the pref is on, the shell sends Infinitus its `quit`
 * verb over the control socket — gated on the running app's manifest listing
 * the verb, never on a version. One send per process; an updater-driven quit
 * (the app is about to come back) is left alone.
 */
import * as NodeOS from "node:os";

import { InfinitusManifest } from "@t3tools/contracts/infinitus";
import { resolveInfinitusControlSocketPath } from "@t3tools/shared/infinitusControl";
import {
  type InfinitusControlError,
  type InfinitusControlRequestInput,
  requestInfinitusControl,
} from "@t3tools/shared/infinitusControlSocket";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import * as ElectronApp from "../electron/ElectronApp.ts";
import { InfinitusDesktopPrefsService } from "./InfinitusDesktopPrefs.ts";

const QUIT_COMMAND = "quit";
/** The whole exchange has to fit inside the shell's own shutdown; a socket
    that is slow is one that is not there. */
const QUIT_TIMEOUT_MS = 2_000;

const decodeManifest = Schema.decodeUnknownEffect(InfinitusManifest);

export type QuitInfinitusOutcome = "sent" | "no-quit-verb" | "unavailable" | "failed";

/** Two round trips: the manifest, then `quit` only when it is listed. */
export const quitInfinitusIfListed = Effect.fn("infinitus.quitIfListed")(function* (
  request: (input: InfinitusControlRequestInput) => Effect.Effect<unknown, InfinitusControlError>,
): Effect.fn.Return<QuitInfinitusOutcome> {
  return yield* Effect.gen(function* () {
    const manifest = yield* request({ command: "manifest" }).pipe(Effect.flatMap(decodeManifest));
    if (!manifest.commands.some((command) => command.name === QUIT_COMMAND)) {
      return "no-quit-verb" as const;
    }
    yield* request({ command: QUIT_COMMAND });
    return "sent" as const;
  }).pipe(
    Effect.catchTag("InfinitusUnavailable", () => Effect.succeed("unavailable" as const)),
    Effect.catch(() => Effect.succeed("failed" as const)),
  );
});

const { logInfo, logWarning } = makeComponentLogger("infinitus-quit-with-app");

const register = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const electronApp = yield* ElectronApp.ElectronApp;
  const prefs = yield* InfinitusDesktopPrefsService;
  const socketPath = resolveInfinitusControlSocketPath({
    platform: environment.platform,
    env: process.env,
    homeDir: NodeOS.homedir(),
  });
  if (socketPath === null) return;

  const context = yield* Effect.context<never>();
  const runEffect = Effect.runPromiseWith(context);
  let sent = false;
  let updaterQuit = false;

  yield* electronApp.onBeforeQuitForUpdate(() => {
    updaterQuit = true;
  });
  // Runs alongside the lifecycle's own before-quit handler, which cancels the
  // first event and quits again once the backend is down — a window this
  // exchange fits in. The second event finds `sent` set.
  yield* electronApp.on("before-quit", () => {
    if (sent || updaterQuit) return;
    sent = true;
    void runEffect(
      Effect.gen(function* () {
        const current = yield* prefs.get;
        if (!current.quitInfinitusWithApp) return;
        const outcome = yield* quitInfinitusIfListed((input) =>
          requestInfinitusControl({ socketPath, request: input, timeoutMs: QUIT_TIMEOUT_MS }),
        );
        if (outcome === "sent" || outcome === "unavailable") {
          yield* logInfo("quit with app", { outcome });
        } else {
          yield* logWarning("quit with app did not reach Infinitus", { outcome });
        }
      }).pipe(Effect.withSpan("infinitus.quitWithApp")),
    );
  });
});

export const layer = Layer.effectDiscard(register);
