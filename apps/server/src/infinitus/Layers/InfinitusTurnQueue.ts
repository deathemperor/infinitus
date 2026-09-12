import {
  CommandId,
  EventId,
  MessageId,
  type OrchestrationEvent,
  type OrchestrationQueuedTurn,
  type ThreadId,
} from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import { makeDrainableWorker } from "@t3tools/shared/DrainableWorker";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { threadHasQueuedTurnStart } from "../../orchestration/ThreadSettlementPolicy.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusSessionHold } from "../Services/InfinitusSessionHold.ts";
import { InfinitusSessionInterrupt } from "../Services/InfinitusSessionInterrupt.ts";
import {
  isRetryQueueId,
  queueDrainVerdict,
  queueHeadOrderKey,
  queueSendRefusal,
  queuedTurnSignature,
  releasedThreads,
  retryQueueId,
} from "./infinitusTurnQueue.logic.ts";

type Input =
  | { readonly kind: "thread"; readonly threadId: ThreadId }
  | { readonly kind: "held"; readonly threadIds: ReadonlyArray<ThreadId> }
  | { readonly kind: "paused"; readonly threadIds: ReadonlyArray<ThreadId> }
  | {
      readonly kind: "start-failed";
      readonly threadId: ThreadId;
      readonly requestId: string | null;
    }
  | { readonly kind: "sweep" };

/** The events after which a thread's queue is looked at again: a session
    change (a turn ending shows as `activeTurnId` going null), the queue
    itself changing, a thread coming back from the archive, and a turn start
    that failed before running (its pending row is gone). */
const WATCHED_EVENTS = new Set<OrchestrationEvent["type"]>([
  "thread.session-set",
  "thread.turn-queued",
  "thread.turn-queue-updated",
  "thread.turn-queue-removed",
  "thread.turn-queue-moved",
  "thread.unarchived",
  "thread.activity-appended",
]);

/** How long the boot sweep waits for the hold and interrupt layers' first
    lists before sweeping anyway (a layer that never publishes must not keep
    every queued message parked). */
const SWEEP_GATE_TIMEOUT = "5 seconds";

const eventThreadId = (event: OrchestrationEvent): ThreadId | null => {
  const payload = event.payload as { readonly threadId?: unknown };
  return typeof payload.threadId === "string" ? (payload.threadId as ThreadId) : null;
};

/** The message a failed-start activity names (`requestId` on the reactor's
    `provider.turn.start.failed` payload). */
const failedStartRequestId = (event: OrchestrationEvent): string | null => {
  if (event.type !== "thread.activity-appended") return null;
  const payload = event.payload.activity.payload as { readonly requestId?: unknown } | null;
  return typeof payload?.requestId === "string" ? payload.requestId : null;
};

/**
 * Fork (#806): the server-side message queue's drain. Queued rows live in
 * the projection (`OrchestrationThread.queuedTurns`); this layer sends the
 * first row of a thread as a `thread.turn.start` carrying `queuedFrom`, so
 * the decider removes the row in the same batch as the send, whenever the
 * thread is idle by every gate the client drain used (`queueDrainVerdict`):
 * no turn running or pending, not held (#616), not paused (#743), not
 * archived, and no send of ours still in flight. One send per thread at a
 * time; the next row waits for the session to settle again.
 *
 * It wakes on the watched events, on a hold or pause letting a thread go,
 * and once at boot: the sweep runs after the hold and interrupt layers have
 * published their first lists (or `SWEEP_GATE_TIMEOUT`), so a thread held
 * at startup is not drained once before the hold is known. `error`
 * sessions are never drained (see the logic module).
 *
 * A send the decider refuses leaves the row where it is, appends an `error`
 * activity (`queue.send.failed`, the refusal in its payload) and skips the
 * row until it is edited, moved or removed; a row already sent or removed
 * is the one refusal that only logs. A send the provider fails to start
 * has consumed the row and left the message in the timeline as a failed
 * send; the drain puts it back once, at the head of the queue under
 * `retryQueueId` with a fresh message id, and says so with an `info`
 * activity (`queue.requeued`). The session reads `error` after such a
 * failure, so the retry waits in the card until the next manual turn
 * recovers the session. Only the drain's own sends are put back: "Send now"
 * from the card is a manual send.
 */
export const InfinitusTurnQueueLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const sessionHold = yield* InfinitusSessionHold;
    const sessionInterrupt = yield* InfinitusSessionInterrupt;
    const crypto = yield* Crypto.Crypto;
    const commandId = crypto.randomUUIDv4.pipe(Effect.map(CommandId.make));

    let held: ReadonlySet<ThreadId> = new Set();
    let paused: ReadonlySet<ThreadId> = new Set();
    const inFlight = new Set<ThreadId>();
    /** Rows the decider refused, by `queuedTurnSignature`. */
    const failed = new Set<string>();
    /** The last row sent per thread, until the provider starts it or
        fails it: what a failed-start activity's `requestId` is matched to. */
    const sent = new Map<ThreadId, OrchestrationQueuedTurn>();
    const heldKnown = yield* Deferred.make<void>();
    const serverCommandId = (tag: string) =>
      crypto.randomUUIDv4.pipe(
        Effect.map((uuid) => CommandId.make(`server:turn-queue-${tag}:${uuid}`)),
      );

    const appendActivity = (input: {
      readonly threadId: ThreadId;
      readonly tone: "error" | "info";
      readonly kind: string;
      readonly summary: string;
      readonly payload: unknown;
      readonly createdAt: string;
    }) =>
      Effect.gen(function* () {
        yield* orchestrationEngine.dispatch({
          type: "thread.activity.append",
          commandId: yield* serverCommandId("activity"),
          threadId: input.threadId,
          activity: {
            id: EventId.make(yield* crypto.randomUUIDv4),
            tone: input.tone,
            kind: input.kind,
            summary: input.summary,
            payload: input.payload,
            turnId: null,
            createdAt: input.createdAt,
          },
          createdAt: input.createdAt,
        });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.turn-queue.activity-failed", {
            threadId: input.threadId,
            kind: input.kind,
            cause: Cause.pretty(cause),
          }),
        ),
      );

    /** A provider failed to start the row `requestId` names: put it back
        once (never a row that is itself the retry), ahead of the queue. */
    const onStartFailed = (threadId: ThreadId, requestId: string | null) =>
      Effect.gen(function* () {
        const row = sent.get(threadId);
        if (row === undefined || requestId === null || row.messageId !== requestId) return;
        sent.delete(threadId);
        if (isRetryQueueId(row.queueId)) {
          yield* Effect.logInfo("infinitus.turn-queue.retry-failed", {
            threadId,
            queueId: row.queueId,
          });
          return;
        }
        const shell = yield* projectionSnapshotQuery
          .getThreadShellById(threadId)
          .pipe(Effect.option, Effect.map(Option.flatten));
        if (Option.isNone(shell)) return;
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        const queueId = retryQueueId(row.queueId);
        const messageId = MessageId.make(yield* crypto.randomUUIDv4);
        const orderKey = queueHeadOrderKey(shell.value.queuedTurns);
        yield* orchestrationEngine.dispatch({
          type: "thread.turn.queue",
          commandId: yield* serverCommandId("retry"),
          threadId,
          queueId,
          message: { messageId, role: "user", text: row.text, attachments: row.attachments },
          ...(row.modelSelection !== undefined ? { modelSelection: row.modelSelection } : {}),
          ...(orderKey !== undefined ? { orderKey } : {}),
          createdAt,
        });
        yield* Effect.logInfo("infinitus.turn-queue.requeued", { threadId, queueId });
        yield* appendActivity({
          threadId,
          tone: "info",
          kind: "queue.requeued",
          summary: "Queued message returned to the queue after the send failed",
          payload: { queueId, from: row.queueId, messageId },
          createdAt,
        });
      });
    const pausedKnown = yield* Deferred.make<void>();

    const consider = (threadId: ThreadId) =>
      Effect.gen(function* () {
        const shell = yield* projectionSnapshotQuery
          .getThreadShellById(threadId)
          .pipe(Effect.option, Effect.map(Option.flatten));
        if (Option.isNone(shell)) return;
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        // A refused row that was edited, moved or removed is forgotten.
        const live = new Set(
          (shell.value.queuedTurns ?? []).map((row) => queuedTurnSignature(threadId, row)),
        );
        for (const signature of failed) {
          if (signature.startsWith(`${threadId}\n`) && !live.has(signature)) {
            failed.delete(signature);
          }
        }
        const verdict = queueDrainVerdict(shell.value, {
          held: held.has(threadId),
          paused: paused.has(threadId),
          inFlight: inFlight.has(threadId),
          pendingStart: threadHasQueuedTurnStart(shell.value, createdAt),
          failed,
        });
        if (verdict.kind !== "send") return;
        const row = verdict.row;
        inFlight.add(threadId);
        sent.set(threadId, row);
        yield* orchestrationEngine
          .dispatch({
            type: "thread.turn.start",
            commandId: yield* commandId,
            threadId,
            message: {
              messageId: row.messageId,
              role: "user",
              text: row.text,
              attachments: row.attachments,
            },
            ...(row.modelSelection !== undefined ? { modelSelection: row.modelSelection } : {}),
            runtimeMode: shell.value.runtimeMode,
            interactionMode: shell.value.interactionMode,
            queuedFrom: row.queueId,
            createdAt,
          })
          .pipe(
            Effect.tap(() =>
              Effect.logInfo("infinitus.turn-queue.sent", { threadId, queueId: row.queueId }),
            ),
            // The row stays. A refusal is shown and the row skipped until
            // it changes; a row already gone is nobody's failure.
            Effect.catchCause((cause) =>
              Effect.gen(function* () {
                sent.delete(threadId);
                yield* Effect.logWarning("infinitus.turn-queue.send-failed", {
                  threadId,
                  queueId: row.queueId,
                  cause: Cause.pretty(cause),
                });
                const detail = queueSendRefusal(Cause.squash(cause));
                if (detail === null) return;
                failed.add(queuedTurnSignature(threadId, row));
                yield* appendActivity({
                  threadId,
                  tone: "error",
                  kind: "queue.send.failed",
                  summary: "Queued message was not sent",
                  payload: { queueId: row.queueId, detail },
                  createdAt,
                });
              }),
            ),
            Effect.ensuring(Effect.sync(() => inFlight.delete(threadId))),
          );
      });

    const onInput = (input: Input) =>
      Effect.gen(function* () {
        switch (input.kind) {
          case "thread":
            return yield* consider(input.threadId);
          case "held": {
            const next = new Set(input.threadIds);
            const released = releasedThreads(held, next);
            held = next;
            yield* Deferred.succeed(heldKnown, undefined);
            for (const threadId of released) yield* consider(threadId);
            return;
          }
          case "paused": {
            const next = new Set(input.threadIds);
            const released = releasedThreads(paused, next);
            paused = next;
            yield* Deferred.succeed(pausedKnown, undefined);
            for (const threadId of released) yield* consider(threadId);
            return;
          }
          case "start-failed":
            yield* onStartFailed(input.threadId, input.requestId);
            return yield* consider(input.threadId);
          case "sweep": {
            const snapshot = yield* projectionSnapshotQuery.getShellSnapshot();
            for (const thread of snapshot.threads) {
              if ((thread.queuedTurns?.length ?? 0) > 0) yield* consider(thread.id);
            }
            return;
          }
        }
      });

    const worker = yield* makeDrainableWorker((input: Input) =>
      onInput(input).pipe(
        // One bad input must not end the worker for every later one.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.turn-queue.input-failed", {
            kind: input.kind,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      orchestrationEngine.streamDomainEvents.pipe(
        Stream.filter(
          (event) =>
            WATCHED_EVENTS.has(event.type) &&
            // Of the activity rows, only a start that failed before running.
            (event.type !== "thread.activity-appended" ||
              event.payload.activity.kind === "provider.turn.start.failed"),
        ),
        Stream.runForEach((event) => {
          const threadId = eventThreadId(event);
          if (threadId === null) return Effect.void;
          return worker.enqueue(
            event.type === "thread.activity-appended"
              ? { kind: "start-failed", threadId, requestId: failedStartRequestId(event) }
              : { kind: "thread", threadId },
          );
        }),
      ),
    );
    yield* forkParked(
      Stream.runForEach(sessionHold.held, (entries) =>
        worker.enqueue({ kind: "held", threadIds: entries.map((entry) => entry.threadId) }),
      ),
    );
    yield* forkParked(
      Stream.runForEach(sessionInterrupt.pausedThreads, (threadIds) =>
        worker.enqueue({ kind: "paused", threadIds }),
      ),
    );
    yield* forkParked(
      Effect.gen(function* () {
        yield* Deferred.await(heldKnown).pipe(Effect.timeoutOption(SWEEP_GATE_TIMEOUT));
        yield* Deferred.await(pausedKnown).pipe(Effect.timeoutOption(SWEEP_GATE_TIMEOUT));
        yield* worker.enqueue({ kind: "sweep" });
      }),
    );
  }),
);
