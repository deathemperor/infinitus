import { InfinitusManifest } from "@t3tools/contracts/infinitus";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { HttpServer } from "effect/unstable/http";

import { forkParked } from "../../serverActivation.ts";
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
 */
export const publishServerPort = Effect.fn("Infinitus.publishServerPort")(function* (port: number) {
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) return;
  yield* Effect.gen(function* () {
    const manifest = yield* client
      .request({ command: "manifest" })
      .pipe(Effect.flatMap(decodeManifest));
    if (!manifest.commands.some((command) => command.name === PREFS_COMMAND)) {
      yield* Effect.logInfo("infinitus.server-port.skipped", {
        port,
        reason: "the running Infinitus has no pref catalog",
      });
      return;
    }
    yield* client.request({ command: PREFS_COMMAND, args: ["set", PORT_PREF, String(port)] });
    yield* Effect.logInfo("infinitus.server-port.published", { port });
  }).pipe(
    Effect.catchTag("InfinitusUnavailable", (error) =>
      Effect.logInfo("infinitus.server-port.skipped", { port, reason: error.cause }),
    ),
    Effect.catch((error) => Effect.logWarning("infinitus.server-port.failed", { port, error })),
  );
});

/** Publishes the bound port once the server is listening and activated. */
export const InfinitusServerPortLive = Layer.effectDiscard(
  forkParked(
    Effect.gen(function* () {
      const server = yield* HttpServer.HttpServer;
      const address = server.address;
      if (typeof address === "string" || !("port" in address)) return;
      yield* publishServerPort(address.port);
    }),
  ),
);
