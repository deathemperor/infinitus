import { resolveWorktreeT3Home } from "@t3tools/shared/devHome";
import { makeDrainableWorker } from "@t3tools/shared/DrainableWorker";
import { HostProcessEnvironment } from "@t3tools/shared/hostProcess";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";

import * as ServerSecretStore from "../../auth/ServerSecretStore.ts";
import { RELAY_ENVIRONMENT_CREDENTIAL_SECRET, RELAY_URL_SECRET } from "../../cloud/config.ts";
import { ServerConfig } from "../../config.ts";
import { ServerEnvironment } from "../../environment/ServerEnvironment.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import {
  eventThreadId,
  shouldPublishAgentAwarenessEvent,
} from "../../relay/AgentAwarenessRelay.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import {
  COALESCE_MS,
  manifestHasThreadActivityPush,
  nextTerminalExpiryMs,
  threadActivityIdentity,
  threadActivityInputs,
  threadActivityPayload,
  threadActivityState,
  type ThreadActivityState,
} from "./infinitusAgentActivity.logic.ts";
import { serverPortWithheldReason } from "./InfinitusServerPort.ts";

const decodeReply = Schema.decodeUnknownOption(
  Schema.Struct({ pushed: Schema.optional(Schema.Boolean), card: Schema.optional(Schema.Boolean) }),
);

/**
 * The phone's lock-screen thread card (#1047 part 3): the server folds its
 * threads into one card and hands it to the Mac, which pushes it to the
 * phone's Live Activity (#1086). The Mac's `push` verb takes the card on
 * stdin — the request line's `secret` field, `{kind: "thread.activity",
 * state}` — and answers `{pushed, card}`; `state: null` ends the card.
 *
 * Cadence is the T3 Connect relay's (`AgentAwarenessRelay`): a thread event
 * the relay would publish schedules one fold 5 s later, so a burst is one
 * push; the fold reads the whole shell snapshot and sends only when the
 * card's identity (everything but the timestamps) changed since the last
 * push the Mac took — an unavailable Mac leaves the slot empty so the next
 * event tries again. A finished thread leaves the card 15 min later with no
 * event to say so, so each push that shows one arms one wake for that
 * moment. A clean shutdown sends `null`, best-effort, when a card was up.
 * The 5 s also stands in for the relay's "confirm a transient state"
 * deferral: a projector state that settles within it is never sent.
 *
 * Withheld exactly where the port publish is (dev runner, isolated socket,
 * worktree `.t3`), and quiet on a build whose `push` summary does not name
 * the card. Counts and phases reach the log; titles never.
 *
 * Stands down while this server is linked to a T3 Connect relay (#1322):
 * upstream's `AgentAwarenessRelay` then pushes the same card through the
 * relay's own key, and two pushers would draw two cards. The link is the
 * relay url and environment credential in the secret store, read at every
 * fold, so linking or unlinking takes effect at the next event; an unlink
 * that finds a Mac card up leaves it to age out. Reading the store is
 * `AgentAwarenessRelay`'s own gate word for word, so the two cannot both
 * think they are on.
 */
export const InfinitusAgentActivityLive = Layer.effectDiscard(
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
      yield* Effect.logInfo("infinitus.agent-activity.withheld", { reason });
      return;
    }
    const orchestrationEngine = yield* OrchestrationEngineService;
    const snapshotQuery = yield* ProjectionSnapshotQuery;
    const infinitus = yield* InfinitusService;
    const control = yield* InfinitusControlClient;
    const secrets = yield* ServerSecretStore.ServerSecretStore;
    const environmentId = yield* (yield* ServerEnvironment).getEnvironmentId;

    /** True while the relay holds this environment's link (its pusher is on). */
    const relayLinked = Effect.gen(function* () {
      const [url, credential] = yield* Effect.all([
        secrets.get(RELAY_URL_SECRET),
        secrets.get(RELAY_ENVIRONMENT_CREDENTIAL_SECRET),
      ]);
      return url._tag === "Some" && credential._tag === "Some";
    }).pipe(Effect.orElseSucceed(() => false));

    /** Identity of the last card the Mac took; null until one was. */
    let sent: string | null = null;
    let scheduled = false;
    let wake: Fiber.Fiber<void> | null = null;

    // The snapshot answers the last poll and nobody polls a headless server:
    // an unpolled placeholder, or an app last seen down, is polled again so
    // the manifest gate can open.
    const manifestReady = Effect.gen(function* () {
      let snapshot = yield* infinitus.snapshot;
      if (!snapshot.available) {
        yield* infinitus.refresh;
        snapshot = yield* infinitus.snapshot;
        // An app that came back is a new process: whatever it last pushed is
        // its predecessor's, so the next card goes out even when unchanged.
        if (snapshot.available) sent = null;
      }
      return snapshot.available && manifestHasThreadActivityPush(snapshot.commands);
    });

    /** True when the Mac took the card. */
    const send = (card: ThreadActivityState | null) => {
      const context = {
        activeCount: card?.activeCount ?? 0,
        rows: card?.activities.length ?? 0,
        phases: card?.activities.map((row) => row.phase) ?? [],
      };
      return control.request({ command: "push", secret: threadActivityPayload(card) }).pipe(
        Effect.flatMap((reply) => {
          const decoded = decodeReply(reply);
          const drewCard = decoded._tag === "Some" && decoded.value.card === true;
          return Effect.logInfo("infinitus.agent-activity.pushed", {
            ...context,
            card: drewCard,
          }).pipe(Effect.as(true));
        }),
        Effect.catchTags({
          InfinitusUnavailable: () =>
            Effect.logDebug("infinitus.agent-activity.unavailable", context).pipe(Effect.as(false)),
          InfinitusProtocolError: (error) =>
            Effect.logWarning("infinitus.agent-activity.refused", {
              ...context,
              detail: error.detail,
            }).pipe(Effect.as(false)),
          InfinitusCommandFailed: (error) =>
            Effect.logWarning("infinitus.agent-activity.refused", {
              ...context,
              error: error.error,
            }).pipe(Effect.as(false)),
        }),
      );
    };

    // Registered before the worker: finalizers run in reverse, so the null
    // goes out once the worker is dead and no publish can land after it.
    yield* Effect.addFinalizer(() =>
      sent === null || sent === "null"
        ? Effect.void
        : send(null).pipe(Effect.timeout("2 seconds"), Effect.ignore),
    );

    const worker = yield* makeDrainableWorker(() =>
      publish.pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.agent-activity.publish-failed", {
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    /** One wake when the earliest shown finish ages out; the next publish replaces it. */
    const armWake = (at: number | null, nowMs: number) =>
      Effect.gen(function* () {
        if (wake !== null) {
          yield* Fiber.interrupt(wake);
          wake = null;
        }
        if (at === null) return;
        wake = yield* Effect.forkScoped(
          Effect.sleep(Duration.millis(Math.max(0, at - nowMs))).pipe(
            Effect.andThen(worker.enqueue(undefined)),
          ),
        );
      });

    const publish: Effect.Effect<void, never, Scope.Scope> = Effect.gen(function* () {
      if (yield* relayLinked) {
        yield* Effect.logDebug("infinitus.agent-activity.relay-linked");
        return;
      }
      if (!(yield* manifestReady)) {
        yield* Effect.logDebug("infinitus.agent-activity.no-verb");
        return;
      }
      const nowMs = DateTime.toEpochMillis(yield* DateTime.now);
      const snapshot = yield* snapshotQuery.getShellSnapshot().pipe(
        Effect.tapError((error) =>
          Effect.logWarning("infinitus.agent-activity.snapshot-failed", { error: error.message }),
        ),
        Effect.option,
      );
      if (snapshot._tag === "None") return;
      const card = threadActivityState(threadActivityInputs(environmentId, snapshot.value), nowMs);
      const identity = threadActivityIdentity(card);
      if (identity !== sent && (yield* send(card))) sent = identity;
      yield* armWake(nextTerminalExpiryMs(card), nowMs);
    });

    /** A fold 5 s from now, unless one is already coming. */
    const schedule = Effect.gen(function* () {
      if (scheduled) return;
      scheduled = true;
      yield* Effect.forkScoped(
        Effect.sleep(Duration.millis(COALESCE_MS)).pipe(
          Effect.andThen(
            Effect.suspend(() => {
              scheduled = false;
              return worker.enqueue(undefined);
            }),
          ),
        ),
      );
    });

    yield* forkParked(
      schedule.pipe(
        Effect.andThen(
          orchestrationEngine.streamDomainEvents.pipe(
            Stream.filter(
              (event) => eventThreadId(event) !== null && shouldPublishAgentAwarenessEvent(event),
            ),
            Stream.runForEach(() => schedule),
          ),
        ),
      ),
    );
  }),
);
