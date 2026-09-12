import { CommandId, type OrchestrationEvent, type ThreadId } from "@t3tools/contracts";
import { makeDrainableWorker } from "@t3tools/shared/DrainableWorker";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";

import {
  ProjectionTurnUsageRepository,
  type ThreadUsageBackfillCandidate,
} from "../../persistence/ProjectionTurnUsage.ts";
import { forkParked } from "../../serverActivation.ts";
import { UsageService } from "../../usage/UsageService.ts";
import { OrchestrationEngineService } from "../Services/OrchestrationEngine.ts";
import { isLegacyCandidate, transcriptUsageRollup } from "./threadUsageBackfill.logic.ts";

type Input = { readonly kind: "sweep" } | { readonly kind: "thread"; readonly threadId: ThreadId };

/** One boot's worth; a server with more legacy threads gets the rest next boot. */
const SWEEP_LIMIT = 500;

/**
 * Fork (#834): the transcript backfill. Threads whose Claude turns ran before
 * this server recorded usage get one rollup estimated from their transcript
 * (`ProjectionTurnUsageRepository.listBackfillCandidates` says which:
 * a Claude session binding, no rollup yet, nothing running), set through
 * `thread.usage.backfill`, which the decider refuses once a rollup exists.
 * A boot sweep (parked until activation, like the babysit one) covers the
 * backlog; a history import (`thread.created` with the import marker) and
 * a session going idle re-check that one thread. Codex is not estimated.
 *
 * A thread is read at most once per process: a session with no transcript
 * is not re-read on every turn. Only thread ids and counts are logged.
 */
export const ThreadUsageBackfillLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrationEngine = yield* OrchestrationEngineService;
    const turnUsageRepository = yield* ProjectionTurnUsageRepository;
    const usageService = yield* UsageService;
    const crypto = yield* Crypto.Crypto;
    const bootAt = DateTime.formatIso(yield* DateTime.now);
    const attempted = new Set<ThreadId>();

    const backfill = Effect.fn("ThreadUsageBackfill.backfill")(function* (
      candidates: ReadonlyArray<ThreadUsageBackfillCandidate>,
    ) {
      const fresh = candidates.filter(
        (candidate) => !attempted.has(candidate.threadId) && isLegacyCandidate(candidate, bootAt),
      );
      if (fresh.length === 0) return;
      const sessions = yield* usageService.readSessionUsage({
        sessionIds: fresh.map((candidate) => candidate.providerSessionId),
      });
      // Marked after the read, so a failed read (the settings file, the
      // transcript directory) leaves the batch for the next trigger.
      for (const candidate of fresh) attempted.add(candidate.threadId);
      let backfilled = 0;
      for (const candidate of fresh) {
        const session = sessions.get(candidate.providerSessionId);
        if (session === undefined) continue;
        const uuid = yield* crypto.randomUUIDv4;
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        yield* orchestrationEngine
          .dispatch({
            type: "thread.usage.backfill",
            commandId: CommandId.make(`server:usage-backfill:${uuid}`),
            threadId: candidate.threadId,
            usage: transcriptUsageRollup(session, candidate.turns),
            createdAt,
          })
          .pipe(
            Effect.map(() => {
              backfilled += 1;
            }),
            Effect.catchCause((cause) =>
              Effect.logWarning("thread.usage-backfill.refused", {
                threadId: candidate.threadId,
                cause: Cause.pretty(cause),
              }),
            ),
          );
      }
      yield* Effect.logInfo("thread.usage-backfill.done", {
        candidates: fresh.length,
        backfilled,
      });
    });

    const onInput = (input: Input) =>
      input.kind === "sweep"
        ? turnUsageRepository.listBackfillCandidates({ limit: SWEEP_LIMIT }).pipe(
            Effect.tap((candidates) =>
              candidates.length === SWEEP_LIMIT
                ? Effect.logInfo("thread.usage-backfill.sweep-capped", { limit: SWEEP_LIMIT })
                : Effect.void,
            ),
            Effect.flatMap(backfill),
          )
        : attempted.has(input.threadId)
          ? Effect.void
          : turnUsageRepository
              .listBackfillCandidates({ threadId: input.threadId, limit: 1 })
              .pipe(Effect.flatMap(backfill));

    const worker = yield* makeDrainableWorker((input: Input) =>
      onInput(input).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("thread.usage-backfill.input-failed", {
            kind: input.kind,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    const eventThreadId = (event: OrchestrationEvent): ThreadId | null => {
      const payload = event.payload as { readonly threadId?: unknown };
      return typeof payload.threadId === "string" ? (payload.threadId as ThreadId) : null;
    };

    yield* forkParked(
      orchestrationEngine.streamDomainEvents.pipe(
        Stream.runForEach((event) => {
          const threadId = eventThreadId(event);
          if (threadId === null) return Effect.void;
          switch (event.type) {
            case "thread.created":
              return event.metadata?.historyImport === true
                ? worker.enqueue({ kind: "thread", threadId })
                : Effect.void;
            case "thread.session-set":
              return event.payload.session.activeTurnId === null
                ? worker.enqueue({ kind: "thread", threadId })
                : Effect.void;
            default:
              return Effect.void;
          }
        }),
      ),
    );
    // Parked like the stream: the projection is complete once the server
    // has activated, and the sweep is what a restart works through.
    yield* forkParked(worker.enqueue({ kind: "sweep" }));
  }),
);
