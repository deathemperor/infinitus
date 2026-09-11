import { InfinitusManifest } from "@t3tools/contracts/infinitus";
import { resolveWorktreeT3Home } from "@t3tools/shared/devHome";
import { HostProcessEnvironment } from "@t3tools/shared/hostProcess";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { HttpServer } from "effect/unstable/http";

import { ServerConfig } from "../../config.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";

/** The Infinitus pref its fork tunnel fronts; the app's default is 3773. */
const PORT_PREF = "fork_server_port";
/** Absent from the manifest on an app that predates the pref catalog. */
const PREFS_COMMAND = "prefs";

const decodeManifest = Schema.decodeUnknownEffect(InfinitusManifest);

/**
 * Tells Infinitus which port this server bound, so the tunnel it can run for
 * the pairing QR fronts the right one. Once, fire-and-forget: no Infinitus, an
 * old manifest, a refused write — each logs at most one line and never fails.
 * Answers whether the app was there to hear it.
 */
export const publishServerPort = Effect.fn("Infinitus.publishServerPort")(function* (port: number) {
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) return false;
  return yield* Effect.gen(function* () {
    const manifest = yield* client
      .request({ command: "manifest" })
      .pipe(Effect.flatMap(decodeManifest));
    if (!manifest.commands.some((command) => command.name === PREFS_COMMAND)) {
      yield* Effect.logInfo("infinitus.server-port.skipped", {
        port,
        reason: "the running Infinitus has no pref catalog",
      });
      return true;
    }
    yield* client.request({ command: PREFS_COMMAND, args: ["set", PORT_PREF, String(port)] });
    yield* Effect.logInfo("infinitus.server-port.published", { port });
    return true;
  }).pipe(
    Effect.catchTag("InfinitusUnavailable", (error) =>
      Effect.logInfo("infinitus.server-port.skipped", { port, reason: error.cause }).pipe(
        Effect.as(false),
      ),
    ),
    Effect.catch((error) =>
      Effect.logWarning("infinitus.server-port.failed", { port, error }).pipe(Effect.as(true)),
    ),
  );
});

/**
 * The startup publish, then one more each time the app comes back — as seen
 * by whichever client is polling, since this never polls itself. A server that
 * outlives an Infinitus relaunch lands its port the moment somebody looks.
 */
export const keepServerPortPublished = Effect.fn("Infinitus.keepServerPortPublished")(function* (
  port: number,
) {
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) return;
  const infinitus = yield* InfinitusService;
  const heard = yield* publishServerPort(port);
  yield* infinitus.observed.pipe(
    // Only the edge: an app the startup publish reached is not "back" on the
    // first snapshot that shows it.
    Stream.mapAccum(
      () => heard,
      (wasAvailable, snapshot) =>
        [snapshot.available, !wasAvailable && snapshot.available ? [port] : []] as const,
    ),
    Stream.runForEach((returnedPort) => publishServerPort(returnedPort)),
  );
});

/**
 * Why a server keeps its port to itself, or undefined for the installed one.
 * The pref names the server the phone's tunnel fronts, and the installed
 * desktop's bundled server is the one that should own it: a dev-runner server
 * (it serves the web app from Vite, so it carries a dev URL) or any server
 * whose home is a worktree-local `.t3` would otherwise take the tunnel with
 * it, last writer wins (#640). An `INFINITUS_CONTROL_SOCKET` override is an
 * isolated instance by definition (every dev instance runs with one): it
 * neither publishes its port nor opens the installed app.
 */
export const serverPortWithheldReason = (input: {
  readonly devUrl: URL | undefined;
  readonly baseDir: string;
  readonly worktreeT3Home: string | undefined;
  /** `INFINITUS_CONTROL_SOCKET` as the process sees it: set means an isolated
      instance pointed at its own (or no) app, never the installed one. */
  readonly controlSocketOverride: string | undefined;
}): string | undefined => {
  if (input.devUrl !== undefined) return "a dev-runner server serves the web app from a dev URL";
  if (input.controlSocketOverride !== undefined && input.controlSocketOverride !== "") {
    return "its control socket is an INFINITUS_CONTROL_SOCKET override (an isolated instance)";
  }
  if (input.worktreeT3Home !== undefined && input.worktreeT3Home === input.baseDir) {
    return "its home is a worktree-local .t3";
  }
  return undefined;
};

/** Publishes the bound port once the server is listening and activated, and
    again whenever a watched Infinitus comes back — for the installed server
    only; a development one says why it stays quiet and stops. */
export const InfinitusServerPortLive = Layer.effectDiscard(
  forkParked(
    Effect.gen(function* () {
      const server = yield* HttpServer.HttpServer;
      const address = server.address;
      if (typeof address === "string" || !("port" in address)) return;
      const config = yield* ServerConfig;
      const env = yield* HostProcessEnvironment;
      const reason = serverPortWithheldReason({
        devUrl: config.devUrl,
        baseDir: config.baseDir,
        worktreeT3Home: yield* resolveWorktreeT3Home(config.baseDir),
        controlSocketOverride: env.INFINITUS_CONTROL_SOCKET,
      });
      if (reason !== undefined) {
        yield* Effect.logInfo("infinitus.server-port.withheld", { port: address.port, reason });
        return;
      }
      yield* keepServerPortPublished(address.port);
    }),
  ),
);
