import type { InfinitusTurnRate as InfinitusTurnRateReply } from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusTurnRateShape {
  /** Fork (#1127): what the threads this server runs spent over the last few
      minutes, folded from the turn usage rows (#834). Never fails: a read the
      projection refuses answers an empty window, which draws no line. */
  readonly read: Effect.Effect<InfinitusTurnRateReply>;
}

export class InfinitusTurnRate extends Context.Service<InfinitusTurnRate, InfinitusTurnRateShape>()(
  "t3/infinitus/Services/InfinitusTurnRate",
) {}
