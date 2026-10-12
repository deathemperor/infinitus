import type { InfinitusRunningTurn } from "@infinitus/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusRunningTurnsShape {
  /** The threads whose run is live right now (#829, on orchestrator v2):
      the server's own projection, read by the HTTP route for the Mac's
      busy-session count and `infinitusctl` — never a process heuristic. */
  readonly list: Effect.Effect<ReadonlyArray<InfinitusRunningTurn>>;
}

export class InfinitusRunningTurns extends Context.Service<
  InfinitusRunningTurns,
  InfinitusRunningTurnsShape
>()("t3/infinitus/Services/InfinitusRunningTurns") {}
