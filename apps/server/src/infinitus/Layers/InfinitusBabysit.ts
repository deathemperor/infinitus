import {
  BABYSIT_MAX_ROUNDS,
  CommandId,
  EventId,
  MessageId,
  QueueId,
  type OrchestrationEvent,
  type OrchestrationThreadShell,
  type ThreadId,
  type ThreadPullRequestLink,
} from "@t3tools/contracts";
import { makeDrainableWorker } from "@t3tools/shared/DrainableWorker";
import {
  threadPullRequestKeyOf,
  visibleThreadPullRequests,
} from "@t3tools/shared/threadPullRequests";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";

import { PullRequestSyncReactor } from "../../orchestration/PullRequestSyncReactor.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { threadHasQueuedTurnStart } from "../../orchestration/ThreadSettlementPolicy.ts";
import { forkParked } from "../../serverActivation.ts";
import {
  babysitPrompt,
  babysitVerdict,
  seedBabysitMarks,
  settleBabysitMarks,
  type BabysitMarks,
} from "./infinitusBabysit.logic.ts";

type Input =
  | { readonly kind: "thread"; readonly threadId: ThreadId }
  | { readonly kind: "on"; readonly threadId: ThreadId }
  | { readonly kind: "off"; readonly threadId: ThreadId }
  | { readonly kind: "sweep" };

const eventThreadId = (event: OrchestrationEvent): ThreadId | null => {
  const payload = event.payload as { readonly threadId?: unknown };
  return typeof payload.threadId === "string" ? (payload.threadId as ThreadId) : null;
};

/**
 * Fork (#269 A): babysit. For every thread with `babysit` set, watches its
 * pull requests' snapshots and, when one needs a round (`babysitVerdict`:
 * conflicts, failing checks or a review requesting changes on an open PR,
 * not yet acted on, thread idle), queues the round's message through
 * `thread.turn.queue` — the #806 drain then sends it under the same hold,
 * pause and idle gates as any queued message, and the user sees the row
 * before it runs — and bumps the round count on the thread. At
 * `BABYSIT_MAX_ROUNDS` it turns babysit off with an error activity; a
 * merged pull request turns it off with an info one.
 *
 * What was acted on is remembered in memory (the signature per link and
 * trigger), seeded at boot from the projection without acting, so a
 * restart does not replay a round on a still-red pull request. Turning
 * babysit on forgets the thread's marks and asks the sync reactor for a
 * fresh read; so does a turn ending (the agent may have just pushed), which
 * is why the reactor writes a requested sync even when nothing changed.
 */
export const InfinitusBabysitLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const pullRequestSync = yield* PullRequestSyncReactor;
    const crypto = yield* Crypto.Crypto;

    const babysat = new Set<ThreadId>();
    /** Marks by `${threadId}\n${linkKey}`. */
    const marks = new Map<string, BabysitMarks>();
    const ownQueued = new Set<string>();

    const markKey = (threadId: ThreadId, linkKey: string) => `${threadId}\n${linkKey}`;
    const forgetThread = (threadId: ThreadId) => {
      for (const key of marks.keys()) if (key.startsWith(`${threadId}\n`)) marks.delete(key);
    };
    const serverCommandId = (tag: string) =>
      crypto.randomUUIDv4.pipe(
        Effect.map((uuid) => CommandId.make(`server:babysit-${tag}:${uuid}`)),
      );
    const openLinks = (shell: OrchestrationThreadShell): ReadonlyArray<ThreadPullRequestLink> =>
      visibleThreadPullRequests(shell.pullRequests).filter(
        (link) => link.snapshot === null || link.snapshot.state === "open",
      );
    const requestSync = (shell: OrchestrationThreadShell) =>
      Effect.forEach(openLinks(shell), (link) => pullRequestSync.requestSync(link), {
        discard: true,
      });
    /** Seed, do not act: what is red now was red before this layer looked. */
    const seedThread = (shell: OrchestrationThreadShell) => {
      for (const link of visibleThreadPullRequests(shell.pullRequests)) {
        if (link.snapshot === null) continue;
        marks.set(markKey(shell.id, threadPullRequestKeyOf(link)), seedBabysitMarks(link.snapshot));
      }
    };

    const shellOf = (threadId: ThreadId) =>
      projectionSnapshotQuery
        .getThreadShellById(threadId)
        .pipe(Effect.option, Effect.map(Option.flatten));

    const marksFor = (shell: OrchestrationThreadShell): ReadonlyMap<string, BabysitMarks> => {
      const settled = new Map<string, BabysitMarks>();
      for (const link of visibleThreadPullRequests(shell.pullRequests)) {
        if (link.snapshot === null) continue;
        const linkKey = threadPullRequestKeyOf(link);
        const key = markKey(shell.id, linkKey);
        const current = marks.get(key);
        if (current === undefined) continue;
        const next = settleBabysitMarks(current, link.snapshot);
        marks.set(key, next);
        settled.set(linkKey, next);
      }
      return settled;
    };

    const stop = (
      shell: OrchestrationThreadShell,
      reason: "cap" | "merged",
      link: ThreadPullRequestLink,
    ) =>
      Effect.gen(function* () {
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        yield* orchestrationEngine.dispatch({
          type: "thread.meta.update",
          commandId: yield* serverCommandId("off"),
          threadId: shell.id,
          babysit: false,
        });
        yield* orchestrationEngine.dispatch({
          type: "thread.activity.append",
          commandId: yield* serverCommandId("stopped"),
          threadId: shell.id,
          activity: {
            id: EventId.make(yield* crypto.randomUUIDv4),
            tone: reason === "cap" ? "error" : "info",
            kind: reason === "cap" ? "babysit.stopped" : "babysit.done",
            summary:
              reason === "cap"
                ? `Babysit stopped after ${BABYSIT_MAX_ROUNDS} rounds; PR #${link.number} still needs work.`
                : `Babysit done: PR #${link.number} merged.`,
            payload: { reason, number: link.number },
            turnId: null,
            createdAt,
          },
          createdAt,
        });
        yield* Effect.logInfo("infinitus.babysit.stopped", { threadId: shell.id, reason });
      });

    const consider = (shell: OrchestrationThreadShell) =>
      Effect.gen(function* () {
        const threadId = shell.id;
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        const verdict = babysitVerdict(shell, {
          marks: marksFor(shell),
          ownQueued,
          pendingStart: threadHasQueuedTurnStart(shell, createdAt),
        });
        if (verdict.kind === "wait") return;
        if (verdict.kind === "stop") {
          babysat.delete(threadId);
          forgetThread(threadId);
          return yield* stop(shell, verdict.reason, verdict.link);
        }
        const queueId = QueueId.make(yield* crypto.randomUUIDv4);
        const messageId = MessageId.make(yield* crypto.randomUUIDv4);
        yield* orchestrationEngine.dispatch({
          type: "thread.turn.queue",
          commandId: yield* serverCommandId("queue"),
          threadId,
          queueId,
          message: {
            messageId,
            role: "user",
            text: babysitPrompt(verdict.trigger, verdict.link, verdict.round),
            attachments: [],
          },
          createdAt,
        });
        ownQueued.add(queueId);
        const key = markKey(threadId, verdict.linkKey);
        marks.set(key, { ...marks.get(key), [verdict.trigger]: verdict.signature });
        yield* orchestrationEngine.dispatch({
          type: "thread.meta.update",
          commandId: yield* serverCommandId("round"),
          threadId,
          babysitRounds: verdict.round,
        });
        yield* Effect.logInfo("infinitus.babysit.queued", {
          threadId,
          trigger: verdict.trigger,
          round: verdict.round,
          number: verdict.link.number,
        });
      });

    const onInput = (input: Input) =>
      Effect.gen(function* () {
        switch (input.kind) {
          case "thread": {
            const shell = yield* shellOf(input.threadId);
            if (Option.isNone(shell)) return;
            if (shell.value.babysit == null) {
              babysat.delete(input.threadId);
              forgetThread(input.threadId);
              return;
            }
            if (!babysat.has(input.threadId)) {
              // First sight of the flag (the sweep missed it): seed, then judge.
              babysat.add(input.threadId);
              seedThread(shell.value);
            }
            return yield* consider(shell.value);
          }
          case "on": {
            // Even a thread seen already: the flag was just turned on, and
            // the user expects the red state in front of them to be acted on.
            babysat.add(input.threadId);
            forgetThread(input.threadId);
            const shell = yield* shellOf(input.threadId);
            if (Option.isNone(shell)) return;
            // The fresh read's synced event is what evaluates the thread;
            // a link never synced has no snapshot to act on yet either.
            yield* requestSync(shell.value);
            return yield* consider(shell.value);
          }
          case "off":
            babysat.delete(input.threadId);
            forgetThread(input.threadId);
            return;
          case "sweep": {
            const snapshot = yield* projectionSnapshotQuery.getShellSnapshot();
            for (const thread of snapshot.threads) {
              if (thread.babysit == null) continue;
              if (babysat.has(thread.id)) continue;
              babysat.add(thread.id);
              seedThread(thread);
            }
            return;
          }
        }
      });

    const worker = yield* makeDrainableWorker((input: Input) =>
      onInput(input).pipe(
        // One bad input must not end the worker for every later one.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.babysit.input-failed", {
            kind: input.kind,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      orchestrationEngine.streamDomainEvents.pipe(
        Stream.runForEach((event) => {
          const threadId = eventThreadId(event);
          if (threadId === null) return Effect.void;
          switch (event.type) {
            case "thread.pull-request-synced":
              return worker.enqueue({ kind: "thread", threadId });
            case "thread.turn-queue-removed":
              ownQueued.delete(event.payload.queueId);
              return worker.enqueue({ kind: "thread", threadId });
            case "thread.session-set":
              // A turn ended: the agent may have pushed, so read the host
              // again before deciding; the synced event does the deciding.
              return babysat.has(threadId)
                ? shellOf(threadId).pipe(
                    Effect.flatMap((shell) =>
                      Option.isSome(shell) && shell.value.session?.activeTurnId === null
                        ? requestSync(shell.value)
                        : Effect.void,
                    ),
                  )
                : Effect.void;
            case "thread.meta-updated": {
              const babysit = event.payload.babysit;
              if (babysit === undefined) return Effect.void;
              // Turned on (`rounds` starts at 0; only this layer's bumps set
              // it higher, and they re-emit the payload), off, or a bump.
              return worker.enqueue(
                babysit === null
                  ? { kind: "off", threadId }
                  : babysit.rounds === 0
                    ? { kind: "on", threadId }
                    : { kind: "thread", threadId },
              );
            }
            default:
              return Effect.void;
          }
        }),
      ),
    );
    // Parked like the stream: the projection is only complete once the
    // server has activated, and the sweep is what a restart seeds from.
    yield* forkParked(worker.enqueue({ kind: "sweep" }));
  }),
);
