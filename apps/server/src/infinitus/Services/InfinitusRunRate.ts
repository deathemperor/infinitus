import type { InfinitusRunRate as InfinitusRunRateReply } from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusRunRateShape {
  /** What the turns this server finished inside the window moved (#1127).
      Read by `infinitus.runRate`; never fails — an empty window is a
      `turns: 0`. */
  readonly read: Effect.Effect<InfinitusRunRateReply>;
}

export class InfinitusRunRate extends Context.Service<InfinitusRunRate, InfinitusRunRateShape>()(
  "t3/infinitus/Services/InfinitusRunRate",
) {}
