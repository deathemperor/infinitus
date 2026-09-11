import type { ThreadId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

/**
 * Fork (#616): the one place a provider turn start passes through before it
 * reaches the provider. `run` is the whole send, built and ready; the gate
 * either runs it now (`started`) or keeps it and runs it later (`held`). The
 * reactor, resume-on-limit and the post-update continuation all hand their
 * sends here, so session priority mode has a single seam and upstream's send
 * paths stay one line each. The passthrough gate below is the server's default;
 * `InfinitusSessionHold` replaces it with the one that holds background
 * threads while their fleet's headroom is low.
 */
export interface TurnStartInput<E, R> {
  readonly threadId: ThreadId;
  /** The send itself, including its own failure handling. A start that runs
      now fails the way it always did; a gate that keeps it owns its later
      failures. It may need the caller's services (a scope to fork into, the
      activation gate): a gate that keeps it captures the caller's context at
      this call and runs it under that context later. */
  readonly run: Effect.Effect<void, E, R>;
}

export type TurnStartVerdict = "started" | "held";

export interface TurnStartGateShape {
  readonly start: <E, R>(input: TurnStartInput<E, R>) => Effect.Effect<TurnStartVerdict, E, R>;
}

export class TurnStartGate extends Context.Service<TurnStartGate, TurnStartGateShape>()(
  "t3/orchestration/Services/TurnStartGate",
) {}

/** The gate that holds nothing: every start runs at once. */
export const TurnStartGatePassthrough = Layer.succeed(TurnStartGate)({
  start: ({ run }) => run.pipe(Effect.as("started" as const)),
});
