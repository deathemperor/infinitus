import { CommandId, type OrchestrationEvent, type ThreadId } from "@t3tools/contracts";
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
import { queueDrainVerdict, releasedThreads } from "./infinitusTurnQueue.logic.ts";

type Input =
  | { readonly kind: "thread"; readonly threadId: ThreadId }
  | { readonly kind: "held"; readonly threadIds: ReadonlyArray<ThreadId> }
  | { readonly kind: "paused"; readonly threadIds: ReadonlyArray<ThreadId> }
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
 * at startup is not drained once before the hold is known. A send the
 * decider rejects leaves the row where it is and is logged; the next event
 * on the thread tries again. A send the provider fails later has already
 * consumed the row: the text is in the timeline as a failed send, like a
 * manual one. `error` sessions are never drained (see the logic module).
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
    const heldKnown = yield* Deferred.make<void>();
    const pausedKnown = yield* Deferred.make<void>();

    const consider = (threadId: ThreadId) =>
      Effect.gen(function* () {
        const shell = yield* projectionSnapshotQuery
          .getThreadShellById(threadId)
          .pipe(Effect.option, Effect.map(Option.flatten));
        if (Option.isNone(shell)) return;
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        const verdict = queueDrainVerdict(shell.value, {
          held: held.has(threadId),
          paused: paused.has(threadId),
          inFlight: inFlight.has(threadId),
          pendingStart: threadHasQueuedTurnStart(shell.value, createdAt),
        });
        if (verdict.kind !== "send") return;
        const row = verdict.row;
        inFlight.add(threadId);
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
            // The row stays; the next event on the thread tries again.
            Effect.catchCause((cause) =>
              Effect.logWarning("infinitus.turn-queue.send-failed", {
                threadId,
                queueId: row.queueId,
                cause: Cause.pretty(cause),
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
          return threadId === null ? Effect.void : worker.enqueue({ kind: "thread", threadId });
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
