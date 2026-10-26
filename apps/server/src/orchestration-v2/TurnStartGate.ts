import { CommandId, type RunId, type ThreadId } from "@infinitus/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as EffectOutbox from "./EffectOutbox.ts";

/**
 * Fork (#720, #1627): the one place a provider turn start passes before reaching the provider, so
 * session holds and the worktree cap share one seam. The gate runs the start (`started`) or keeps
 * it (`held`); a holding gate replaces the passthrough in `server.ts`. Contract:
 * `docs/internals/turn-start-gate.md`.
 */
export interface TurnStartInput<E> {
  readonly threadId: ThreadId;
  readonly runId: RunId;
  /**
   * The start itself, built and ready, with its own failure handling. It is
   * idempotent against the run's current status: a run that was interrupted
   * or settled while held starts nothing.
   */
  readonly start: Effect.Effect<void, E>;
}

export type TurnStartVerdict = "started" | "held";

export interface TurnStartGateShape {
  readonly start: <E>(input: TurnStartInput<E>) => Effect.Effect<TurnStartVerdict, E>;
}

export class TurnStartGate extends Context.Service<TurnStartGate, TurnStartGateShape>()(
  "t3/orchestration-v2/TurnStartGate",
) {}

/** The gate that holds nothing: every start runs at once. */
export const TurnStartGatePassthrough = Layer.succeed(TurnStartGate)({
  start: ({ start }) => start.pipe(Effect.as("started" as const)),
});

/**
 * Lets a held run go: a fresh `provider-turn.start` effect, run in the thread's lane. The start
 * re-reads the run, so one that stopped being `starting` meanwhile (Stop, a restart) is a no-op.
 * `releaseId` must be fresh per release of the same run: effect ids are unique, so the outbox
 * refuses a repeat.
 */
export const releaseTurnStart = Effect.fn("TurnStartGate.releaseTurnStart")(function* (input: {
  readonly threadId: ThreadId;
  readonly runId: RunId;
  readonly releaseId: string;
}): Effect.fn.Return<void, EffectOutbox.EffectOutboxError, EffectOutbox.EffectOutboxV2> {
  const outbox = yield* EffectOutbox.EffectOutboxV2;
  yield* outbox.enqueue([
    {
      id: `effect:turn-start-gate:${input.runId}:${input.releaseId}`,
      commandId: CommandId.make(`command:system:turn-start-gate:${input.runId}`),
      threadId: input.threadId,
      request: { type: "provider-turn.start", runId: input.runId },
    },
  ]);
  yield* outbox.notifyAvailable();
});
