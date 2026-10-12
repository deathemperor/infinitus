import { CommandId, type RunId, type ThreadId } from "@infinitus/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as EffectOutbox from "./EffectOutbox.ts";

/**
 * Fork (#720, #1627): the one place a provider turn start passes before it
 * reaches the provider. `ProviderTurnStartService.start` hands every start
 * here — the first turn, a drained queued run, a restart continuation, a
 * provider switch — so session holds and the worktree cap have a single seam
 * and upstream's start path stays one line. The gate either runs the start
 * now (`started`) or keeps it (`held`). The passthrough below is the
 * server's default; a holding gate replaces it in `server.ts`.
 *
 * The contract a holding gate must keep, and why, is
 * `docs/internals/turn-start-gate.md`. In short: answer `held` at once (the
 * call runs inside the effect worker's per-thread lane, so blocking here
 * blocks the thread's interrupts too), leave the run alone (its `starting`
 * status is the lease: nothing else starts on the thread while it stands),
 * and release through `releaseTurnStart`, never by running `start` later
 * outside the lane.
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
 * Lets a held run go: a fresh `provider-turn.start` effect for it, which the
 * effect worker runs in the thread's lane like the one the gate kept. The
 * start re-reads the run, so a run that stopped being `starting` meanwhile
 * (Stop, a restart) is a no-op. `releaseId` must be fresh per release of the
 * same run: effect ids are unique, so the outbox refuses a repeat.
 */
export const releaseTurnStart = (input: {
  readonly threadId: ThreadId;
  readonly runId: RunId;
  readonly releaseId: string;
}): Effect.Effect<void, EffectOutbox.EffectOutboxError, EffectOutbox.EffectOutboxV2> =>
  Effect.gen(function* () {
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
