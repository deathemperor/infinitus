import type { AuthEnvironmentScope } from "@t3tools/contracts";
import { InfinitusManifest, InfinitusPrefs } from "@t3tools/contracts/infinitus";
import { resolveWorktreeT3Home } from "@t3tools/shared/devHome";
import { HostProcessEnvironment } from "@t3tools/shared/hostProcess";
import * as NodeOS from "node:os";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import * as Stream from "effect/Stream";
import { HttpServer } from "effect/unstable/http";

import * as EnvironmentAuth from "../../auth/EnvironmentAuth.ts";
import { ServerConfig } from "../../config.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";

/** The Infinitus pref its fork tunnel fronts; the app's default is 3773. */
const PORT_PREF = "fork_server_port";
/** Absent from the manifest on an app that predates the pref catalog. */
const PREFS_COMMAND = "prefs";

/** The app's verb that stores the CLI's credential (#822): a write whose
    material comes on stdin, so it rides the request line's `secret` field. */
export const DESKTOP_CREDENTIAL_COMMAND = "desktop-credential";
/** The session's subject: one row in Settings › Devices, replaced on every
    publish, never more. */
export const DESKTOP_CREDENTIAL_SUBJECT = "infinitusctl";
/** What `infinitusctl` may do (Infi4's ruling on #822): read and drive
    threads, see its own Devices row; never mint devices or write relay. */
export const DESKTOP_CREDENTIAL_SCOPES: ReadonlyArray<AuthEnvironmentScope> = [
  "orchestration:read",
  "orchestration:operate",
  "access:read",
];
/** No refresh: past this, or after a revoke, the CLI says to relaunch the
    desktop app, whose next publish mints a new one. */
export const DESKTOP_CREDENTIAL_TTL = Duration.days(90);

const decodeManifest = Schema.decodeUnknownEffect(InfinitusManifest);
type Manifest = typeof InfinitusManifest.Type;

const decodePrefs = Schema.decodeUnknownEffect(InfinitusPrefs);

/** How often a publishing server re-checks that the app still names its port
    (#1137). Slow on purpose: the read is one socket request, and the repair it
    guards is a minute of dark `infinitusctl` verbs, not a live user action. */
const HEARTBEAT_INTERVAL = Duration.seconds(60);

/**
 * The port the app's catalog names for `fork_server_port`, or undefined when
 * it names none we can compare. A value that is not ours is the signal that
 * another server published over us and, if it has since died, left the tunnel
 * pointing at a closed port (#1137).
 *
 * Two cases deliberately answer undefined, because a false positive here
 * republishes every minute and each publish rotates the `infinitusctl`
 * credential: a catalog without the pref at all (an app that has no such
 * setting), and a value that is not a port number (an app reporting something
 * we cannot compare). Neither is a port we can claim is stale.
 */
export const publishedPort = (prefs: typeof InfinitusPrefs.Type): number | undefined => {
  const pref = prefs.prefs.find((entry) => entry.key === PORT_PREF);
  if (pref === undefined) return undefined;
  if (typeof pref.value === "number") return pref.value;
  if (typeof pref.value === "string" && /^\d+$/.test(pref.value.trim())) {
    return Number(pref.value.trim());
  }
  return undefined;
};

const takesDesktopCredential = (manifest: Manifest) =>
  manifest.commands.some(
    (command) => command.name === DESKTOP_CREDENTIAL_COMMAND && command.stdin === "secret",
  );

/** "infinitusctl on <Mac>", the Devices row's name; macOS reports the
    hostname as `Name.local`. */
const desktopCredentialLabel = () => `infinitusctl on ${NodeOS.hostname().replace(/\.local$/, "")}`;

/**
 * Mints the session `infinitusctl` uses against this server and hands it to
 * the app on the `secret` field (#822), after revoking the previous one so
 * Settings › Devices shows one row. A write the app refuses revokes the new
 * session again — no orphan row — and logs; the token itself reaches no log,
 * no span, no error.
 */
const publishDesktopCredential = Effect.fn("Infinitus.publishDesktopCredential")(
  function* (port: number) {
    const client = yield* InfinitusControlClient;
    const auth = yield* EnvironmentAuth.EnvironmentAuth;
    const previous = yield* auth.listSessions();
    for (const session of previous) {
      if (session.subject === DESKTOP_CREDENTIAL_SUBJECT)
        yield* auth.revokeSession(session.sessionId);
    }
    const issued = yield* auth.issueSession({
      subject: DESKTOP_CREDENTIAL_SUBJECT,
      scopes: DESKTOP_CREDENTIAL_SCOPES,
      label: desktopCredentialLabel(),
      ttl: DESKTOP_CREDENTIAL_TTL,
    });
    const expiresAt = DateTime.formatIso(issued.expiresAt);
    yield* client
      .request({
        command: DESKTOP_CREDENTIAL_COMMAND,
        options: { origin: `http://127.0.0.1:${port}`, expiresAt },
        secret: issued.token,
      })
      .pipe(
        Effect.andThen(
          Effect.logInfo("infinitus.desktop-credential.issued", {
            sessionId: issued.sessionId,
            expiresAt,
          }),
        ),
        Effect.catch((error) =>
          auth.revokeSession(issued.sessionId).pipe(
            Effect.ignore,
            Effect.andThen(
              Effect.logWarning("infinitus.desktop-credential.failed", {
                error: error._tag,
                detail: "detail" in error ? error.detail : "cause" in error ? error.cause : null,
              }),
            ),
          ),
        ),
      );
  },
  Effect.catch((error) =>
    Effect.logWarning("infinitus.desktop-credential.failed", { error: error._tag }),
  ),
);

/**
 * Tells Infinitus which port this server bound, so the tunnel it can run for
 * the pairing QR fronts the right one, and — on an app whose manifest takes
 * it — the credential `infinitusctl` drives this server with (#822). Once,
 * fire-and-forget: no Infinitus, an old manifest, a refused write — each logs
 * at most one line and never fails. Answers whether the app was there to
 * hear it.
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
    if (takesDesktopCredential(manifest)) yield* publishDesktopCredential(port);
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
 * One heartbeat check (#1137): reads the app's own catalog and republishes
 * only when the port it names is not ours. A read, not a blind write —
 * republishing on a timer would re-mint the `infinitusctl` credential every
 * minute, so a CLI holding a token would lose it mid-command. Never fails:
 * an app that is away, or a reply that will not decode, is next minute's
 * problem.
 */
const republishIfPortDrifted = Effect.fn("Infinitus.republishIfPortDrifted")(
  function* (port: number) {
    const client = yield* InfinitusControlClient;
    const prefs = yield* client
      .request({ command: PREFS_COMMAND })
      .pipe(Effect.flatMap(decodePrefs));
    const published = publishedPort(prefs);
    if (published === undefined || published === port) return;
    // `published` is the one fact that identifies whoever took the pref: log
    // it, so a fight between two live publishers reads as the same foreign
    // port coming back every minute instead of a silent flip-flop.
    yield* Effect.logInfo("infinitus.server-port.drifted", { port, published });
    yield* publishServerPort(port);
  },
  Effect.catch((error) =>
    Effect.logDebug("infinitus.server-port.heartbeat-skipped", { error: error._tag }),
  ),
);

/**
 * The startup publish, then one more each time the app comes back — as seen
 * by whichever client is polling, since this never polls itself — and, from
 * #1137, a slow heartbeat of its own. The edge alone was not enough: a server
 * nobody is watching polls nothing, so when another server published over its
 * port and died, the tunnel fronted a closed port until someone relaunched the
 * app. The heartbeat is the one thing here that does not need a watcher.
 */
export const keepServerPortPublished = Effect.fn("Infinitus.keepServerPortPublished")(function* (
  port: number,
) {
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) return;
  const infinitus = yield* InfinitusService;
  const heard = yield* publishServerPort(port);
  // The came-back edge and the heartbeat are two independent callers of a
  // publish that is read-modify-write on the credential (revoke all, issue,
  // hand over). Interleaved, the app can end up holding a token the other
  // call already revoked, and the heartbeat — seeing the port match — would
  // never repair it. One permit keeps them in line.
  const publishing = yield* Semaphore.make(1);
  const onReturn = infinitus.observed.pipe(
    // Only the edge: an app the startup publish reached is not "back" on the
    // first snapshot that shows it.
    Stream.mapAccum(
      () => heard,
      (wasAvailable, snapshot) =>
        [snapshot.available, !wasAvailable && snapshot.available ? [port] : []] as const,
    ),
    Stream.runForEach((returnedPort) => publishing.withPermits(1)(publishServerPort(returnedPort))),
  );
  const heartbeat = Effect.forever(
    Effect.sleep(HEARTBEAT_INTERVAL).pipe(
      Effect.andThen(publishing.withPermits(1)(republishIfPortDrifted(port))),
    ),
  );
  yield* Effect.all([onReturn, heartbeat], { concurrency: "unbounded", discard: true });
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
