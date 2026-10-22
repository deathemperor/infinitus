import { CommandId, type OrchestrationV2TurnItem } from "@infinitus/contracts";
import { makeDrainableWorker } from "@infinitus/shared/DrainableWorker";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";

import * as Orchestrator from "../../orchestration-v2/Orchestrator.ts";
import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import { forkParked } from "../../serverActivation.ts";
import { toolBoundaryOf, toolBoundarySteerCandidate } from "./infinitusToolBoundarySteer.logic.ts";

/**
 * Fork (#1318, #1627): the half of steer mode that watches the running turn.
 * The orchestrator queues a steer as a run with `sendAt: "tool_boundary"`
 * (`Orchestrator.ts`, `message.dispatch`); this layer tails the domain events
 * and, when a tool call of a running turn finishes, promotes the first such
 * row to a steer through the same `queued-message.promote-to-steer` command
 * the row's own "Steer" button sends — one row per boundary, under the
 * thread's dispatch lock, so a row the user sent, edited or removed
 * meanwhile is refused there rather than sent twice. The command id is the
 * tool item's, so a tool whose completion is projected twice is one
 * boundary. A refusal is normal (the turn ended, the row went) and is logged
 * at debug only. If the turn ends first, the idle drain takes the row as an
 * ordinary queued message.
 */
export const InfinitusToolBoundarySteerLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrator = yield* Orchestrator.OrchestratorV2;
    const projectionStore = yield* ProjectionStore.ProjectionStoreV2;

    const onBoundary = Effect.fn("InfinitusToolBoundarySteer.onBoundary")(
      function* (item: OrchestrationV2TurnItem) {
        const targetRunId = item.runId;
        if (targetRunId === null) return;
        const { runs } = yield* projectionStore.getThreadRecords(item.threadId, ["runs"]);
        const queuedRunId = toolBoundarySteerCandidate(runs, targetRunId);
        if (queuedRunId === undefined) return;
        yield* orchestrator.dispatch({
          type: "queued-message.promote-to-steer",
          commandId: CommandId.make(`command:system:tool-boundary-steer:${item.id}`),
          threadId: item.threadId,
          queuedRunId,
          targetRunId,
        });
      },
      (effect, item) =>
        effect.pipe(
          Effect.catchCause((cause) =>
            Effect.logDebug("infinitus.tool-boundary-steer.skipped", {
              threadId: item.threadId,
              itemId: item.id,
              cause: Cause.pretty(cause),
            }),
          ),
        ),
    );

    const worker = yield* makeDrainableWorker(onBoundary);

    yield* forkParked(
      orchestrator.streamDomainEvents.pipe(
        // The live tail only; finished tool calls and nothing else reach the worker.
        Stream.runForEach((event) => {
          const item = toolBoundaryOf(event);
          return item === null ? Effect.void : worker.enqueue(item);
        }),
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.tool-boundary-steer.stream-ended", {
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );
  }),
);
