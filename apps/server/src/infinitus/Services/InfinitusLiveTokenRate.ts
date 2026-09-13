import type { InfinitusLiveTokenRate as LiveTokenRate } from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusLiveTokenRateShape {
  /** Fork (#1127): this server's rolling output tokens per minute, folded
      from the per-turn usage rows it records (#834) — the replacement for
      the Mac's transcript-tail rate, which retires with the terminal
      sessions (#1041). Null when no turn completed inside the window. */
  readonly read: Effect.Effect<LiveTokenRate | null>;
}

export class InfinitusLiveTokenRate extends Context.Service<
  InfinitusLiveTokenRate,
  InfinitusLiveTokenRateShape
>()("t3/infinitus/Services/InfinitusLiveTokenRate") {}
