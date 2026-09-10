import { InfinitusManifest } from "@t3tools/contracts/infinitus";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { HttpServer } from "effect/unstable/http";

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

/** Publishes the bound port once the server is listening and activated, and
    again whenever a watched Infinitus comes back. */
export const InfinitusServerPortLive = Layer.effectDiscard(
  forkParked(
    Effect.gen(function* () {
      const server = yield* HttpServer.HttpServer;
      const address = server.address;
      if (typeof address === "string" || !("port" in address)) return;
      yield* keepServerPortPublished(address.port);
    }),
  ),
);
