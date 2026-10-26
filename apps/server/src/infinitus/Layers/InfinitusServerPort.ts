import type { AuthEnvironmentScope, AuthSessionId } from "@infinitus/contracts";
import { InfinitusManifest, InfinitusPrefs } from "@infinitus/contracts/infinitus";
import { resolveWorktreeT3Home } from "@infinitus/shared/devHome";
import * as HostProcess from "@infinitus/shared/HostProcess";
import * as NodeOS from "node:os";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import * as Stream from "effect/Stream";
import { HttpServer } from "effect/http";

import * as EnvironmentAuth from "../../auth/EnvironmentAuth.ts";
import { type RuntimeMode, ServerConfig } from "../../config.ts";
import { ServerEnvironmentIdentity } from "../../environment/ServerEnvironment.ts";
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

/**
 * The opt-in (#1487): a server that is not the desktop's bundled one — a dev
 * runner, a worktree `.t3`, a showcase's temp home — keeps its port to itself
 * unless this is set, and one that is set takes the app's slot even from a
 * live installed desktop. Documented in `docs/operations/development.md`.
 */
export const PUBLISH_OPT_IN_ENV = "INFINITUS_PUBLISH_SERVER_PORT";

export const publishOptedIn = (value: string | undefined): boolean =>
  ["1", "true", "yes"].includes((value ?? "").trim().toLowerCase());

/**
 * How the app answers a publish while another environment's server holds its slot (#1487): the
 * words `ForkServerProbe.heldReply` in `apps/mac` opens with. The desktop's heartbeat meets it
 * every minute while an opted-in dev server runs, so it is information, not a warning.
 */
export const HELD_REPLY_PREFIX = "held by environment ";

const decodeManifest = Schema.decodeUnknownEffect(InfinitusManifest);
type Manifest = typeof InfinitusManifest.Type;

const decodePrefs = Schema.decodeUnknownEffect(InfinitusPrefs);

/** How often a publishing server re-checks that the app still names its port
    (#1137). Slow on purpose: the read is one socket request, and the repair it
    guards is a minute of dark `infinitusctl` verbs, not a live user action. */
const HEARTBEAT_INTERVAL = Duration.seconds(60);

/**
 * The port the app's catalog names for `fork_server_port`, or undefined when none is comparable. A
 * foreign value means another server published over us and may have left the tunnel on a closed
 * port (#1137). A missing pref or a non-port value answers undefined: a false positive would
 * republish every minute, and each publish rotates the `infinitusctl` credential.
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
 * Who is publishing, as both verbs tell the app in their options (#1487): the
 * environment id lets the app keep a slot for the server that holds it, and
 * `takeover` — only ever from the opt-in — says this server is the one the
 * user picked, so the app switches even from a live holder.
 */
interface Publisher {
  readonly environmentId: string;
  readonly takeover: boolean;
}

const publisherOptions = (publisher: Publisher): Record<string, string> => ({
  environmentId: publisher.environmentId,
  ...(publisher.takeover ? { takeover: "true" } : {}),
});

/** The session this server last handed the app, kept so a republish can hand
    over the same one instead of minting a row per publish (#1487). */
interface HeldCredential {
  readonly sessionId: AuthSessionId;
  readonly token: string;
  readonly expiresAt: DateTime.Utc;
}

/**
 * Hands the app the session `infinitusctl` uses against this server, on the `secret` field (#822).
 * The session minted before is handed over again while active, so a republish after a port drift
 * (#1137) rotates no token; a new one is minted only when none is, after revoking other
 * `infinitusctl` rows. A refused write revokes a fresh one; the token is never logged.
 */
const publishDesktopCredential = Effect.fn("Infinitus.publishDesktopCredential")(
  function* (input: {
    readonly port: number;
    readonly publisher: Publisher;
    readonly credential: Ref.Ref<HeldCredential | undefined>;
    readonly client: InfinitusControlClient["Service"];
    readonly auth: EnvironmentAuth.EnvironmentAuth["Service"];
  }) {
    const { port, publisher, credential, client, auth } = input;
    const active = yield* auth.listSessions();
    const held = yield* Ref.get(credential);
    const reused =
      held !== undefined && active.some((session) => session.sessionId === held.sessionId)
        ? held
        : undefined;
    const issued = yield* reused !== undefined
      ? Effect.succeed(reused)
      : Effect.gen(function* () {
          for (const session of active) {
            if (session.subject === DESKTOP_CREDENTIAL_SUBJECT)
              yield* auth.revokeSession(session.sessionId);
          }
          const fresh = yield* auth.issueSession({
            subject: DESKTOP_CREDENTIAL_SUBJECT,
            scopes: DESKTOP_CREDENTIAL_SCOPES,
            label: desktopCredentialLabel(),
            ttl: DESKTOP_CREDENTIAL_TTL,
          });
          const minted: HeldCredential = {
            sessionId: fresh.sessionId,
            token: fresh.token,
            expiresAt: fresh.expiresAt,
          };
          yield* Ref.set(credential, minted);
          return minted;
        });
    const expiresAt = DateTime.formatIso(issued.expiresAt);
    yield* client
      .request({
        command: DESKTOP_CREDENTIAL_COMMAND,
        options: {
          origin: `http://127.0.0.1:${port}`,
          expiresAt,
          ...publisherOptions(publisher),
        },
        secret: issued.token,
      })
      .pipe(
        Effect.andThen(
          Effect.logInfo("infinitus.desktop-credential.issued", {
            sessionId: issued.sessionId,
            expiresAt,
            reused: reused !== undefined,
          }),
        ),
        Effect.catch((error) =>
          (reused !== undefined
            ? Effect.void
            : auth
                .revokeSession(issued.sessionId)
                .pipe(Effect.ignore, Effect.andThen(Ref.set(credential, undefined)))
          ).pipe(
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

export interface ServerPortPublisher {
  /**
   * Tells Infinitus which port this server bound, so the pairing-QR tunnel fronts the right one,
   * and (if the manifest takes it) the `infinitusctl` credential (#822). Once, fire-and-forget:
   * every failure logs at most one line. Answers whether the app was there to hear it.
   */
  readonly publish: Effect.Effect<boolean>;
  /**
   * One heartbeat check (#1137): republishes only when the app's catalog names a port that is not
   * ours. A read, not a blind write: republishing on a timer would hand the credential over every
   * minute. Never fails; an away app or undecodable reply is next minute's problem.
   */
  readonly republishIfPortDrifted: Effect.Effect<void>;
}

/**
 * One publisher for one bound port: it carries this environment's id and
 * the opt-in's `takeover` on every publish, and keeps the session it minted
 * so a republish hands over the same one (#1487).
 */
export const makeServerPortPublisher = Effect.fn("Infinitus.makeServerPortPublisher")(function* (
  port: number,
) {
  const client = yield* InfinitusControlClient;
  const auth = yield* EnvironmentAuth.EnvironmentAuth;
  const identity = yield* ServerEnvironmentIdentity;
  const env = yield* HostProcess.Environment;
  const publisher: Publisher = {
    environmentId: yield* identity.getEnvironmentId,
    takeover: publishOptedIn(env[PUBLISH_OPT_IN_ENV]),
  };
  const credential = yield* Ref.make<HeldCredential | undefined>(undefined);

  const publish: Effect.Effect<boolean> = Effect.gen(function* () {
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
      yield* client.request({
        command: PREFS_COMMAND,
        args: ["set", PORT_PREF, String(port)],
        options: publisherOptions(publisher),
      });
      yield* Effect.logInfo("infinitus.server-port.published", { port });
      if (takesDesktopCredential(manifest))
        yield* publishDesktopCredential({ port, publisher, credential, client, auth });
      return true;
    }).pipe(
      Effect.catchTags({
        InfinitusUnavailable: (error) =>
          Effect.logInfo("infinitus.server-port.skipped", { port, reason: error.cause }).pipe(
            Effect.as(false),
          ),
        // The slot is another environment's while its server answers: the
        // installed desktop meets this each heartbeat under an opted-in dev
        // server and takes the slot back the minute that server is gone.
        InfinitusCommandFailed: (error) =>
          (error.error.startsWith(HELD_REPLY_PREFIX)
            ? Effect.logInfo("infinitus.server-port.held", { port, reply: error.error })
            : Effect.logWarning("infinitus.server-port.failed", { port, error })
          ).pipe(Effect.as(true)),
      }),
      Effect.catch((error) =>
        Effect.logWarning("infinitus.server-port.failed", { port, error }).pipe(Effect.as(true)),
      ),
    );
  }).pipe(Effect.withSpan("Infinitus.publishServerPort"));

  const republishIfPortDrifted: Effect.Effect<void> = Effect.gen(function* () {
    const prefs = yield* client
      .request({ command: PREFS_COMMAND })
      .pipe(Effect.flatMap(decodePrefs));
    const published = publishedPort(prefs);
    if (published === undefined || published === port) return;
    // `published` is the one fact that identifies whoever took the pref: log
    // it, so a fight between two live publishers reads as the same foreign
    // port coming back every minute instead of a silent flip-flop.
    yield* Effect.logInfo("infinitus.server-port.drifted", { port, published });
    yield* publish;
  }).pipe(
    Effect.catch((error) =>
      Effect.logDebug("infinitus.server-port.heartbeat-skipped", { error: error._tag }),
    ),
    Effect.withSpan("Infinitus.republishIfPortDrifted"),
  );

  return { publish, republishIfPortDrifted } satisfies ServerPortPublisher;
});

/** One publish from a fresh publisher: the startup shape, and the tests'. */
export const publishServerPort = (port: number) =>
  Effect.flatMap(makeServerPortPublisher(port), (publisher) => publisher.publish);

/**
 * The startup publish, then one each time the app comes back (seen by whichever client polls; this
 * never polls) and a slow heartbeat (#1137): a server nobody watches polls nothing, so after
 * another server published over its port and died, the tunnel fronted a closed port.
 */
export const keepServerPortPublished = Effect.fn("Infinitus.keepServerPortPublished")(function* (
  port: number,
) {
  const client = yield* InfinitusControlClient;
  if (client.socketPath === null) return;
  const infinitus = yield* InfinitusService;
  const publisher = yield* makeServerPortPublisher(port);
  const heard = yield* publisher.publish;
  // The came-back edge and the heartbeat both run a publish that is read-modify-write on the
  // credential; interleaved, the app can hold a token the other call already revoked and the
  // heartbeat, seeing the port match, would never repair it. One permit keeps them in line.
  const publishing = yield* Semaphore.make(1);
  const onReturn = infinitus.observed.pipe(
    // Only the edge: an app the startup publish reached is not "back" on the
    // first snapshot that shows it.
    Stream.mapAccum(
      () => heard,
      (wasAvailable, snapshot) =>
        [snapshot.available, !wasAvailable && snapshot.available ? [port] : []] as const,
    ),
    Stream.runForEach(() => publishing.withPermits(1)(publisher.publish)),
  );
  const heartbeat = Effect.forever(
    Effect.sleep(HEARTBEAT_INTERVAL).pipe(
      Effect.andThen(publishing.withPermits(1)(publisher.republishIfPortDrifted)),
    ),
  );
  yield* Effect.all([onReturn, heartbeat], { concurrency: "unbounded", discard: true });
});

/**
 * Why a server keeps its port to itself, or undefined for the installed one. The pref names the
 * server the phone's tunnel fronts, which must be the desktop's bundled one: a dev-runner server, a
 * worktree-local `.t3` home or an `INFINITUS_CONTROL_SOCKET` override must not take it (#640), nor
 * any non-`desktop` runtime mode (#1487). `INFINITUS_PUBLISH_SERVER_PORT=1` overrides every reason.
 */
export const serverPortWithheldReason = (input: {
  readonly mode: RuntimeMode;
  readonly devUrl: URL | undefined;
  readonly baseDir: string;
  readonly worktreeT3Home: string | undefined;
  /** `INFINITUS_CONTROL_SOCKET` as the process sees it: set means an isolated
      instance pointed at its own (or no) app, never the installed one. */
  readonly controlSocketOverride: string | undefined;
  /** `INFINITUS_PUBLISH_SERVER_PORT` says so. */
  readonly publishOptIn: boolean;
}): string | undefined => {
  if (input.publishOptIn) return undefined;
  if (input.devUrl !== undefined) return "a dev-runner server serves the web app from a dev URL";
  if (input.controlSocketOverride !== undefined && input.controlSocketOverride !== "") {
    return "its control socket is an INFINITUS_CONTROL_SOCKET override (an isolated instance)";
  }
  if (input.worktreeT3Home !== undefined && input.worktreeT3Home === input.baseDir) {
    return "its home is a worktree-local .t3";
  }
  if (input.mode !== "desktop") return "only the desktop's bundled server publishes its port";
  return undefined;
};

/** `serverPortWithheldReason` for this process: what the port publish and the
    startup companion launch both ask before touching the installed app. */
export const resolveServerPortWithheldReason = Effect.gen(function* () {
  const config = yield* ServerConfig;
  const env = yield* HostProcess.Environment;
  return serverPortWithheldReason({
    mode: config.mode,
    devUrl: config.devUrl,
    baseDir: config.baseDir,
    worktreeT3Home: yield* resolveWorktreeT3Home(config.baseDir),
    controlSocketOverride: env.INFINITUS_CONTROL_SOCKET,
    publishOptIn: publishOptedIn(env[PUBLISH_OPT_IN_ENV]),
  });
});

/** Publishes the bound port once the server is listening and activated, and
    again whenever a watched Infinitus comes back — for the installed server
    only; a development one says why it stays quiet and stops. */
export const InfinitusServerPortLive = Layer.effectDiscard(
  forkParked(
    Effect.gen(function* () {
      const server = yield* HttpServer.HttpServer;
      const address = server.address;
      if (typeof address === "string" || !("port" in address)) return;
      const reason = yield* resolveServerPortWithheldReason;
      if (reason !== undefined) {
        yield* Effect.logInfo("infinitus.server-port.withheld", { port: address.port, reason });
        return;
      }
      yield* keepServerPortPublished(address.port);
    }),
  ),
);
