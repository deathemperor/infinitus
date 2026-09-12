import type { ServerRunningTurn } from "@t3tools/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusRunningTurnsShape {
  /** The provider turns running right now (#829): the server's own state,
      read by the update gate, the HTTP route and the desktop's install
      dialog — never a process heuristic. */
  readonly list: Effect.Effect<ReadonlyArray<ServerRunningTurn>>;
}

export class InfinitusRunningTurns extends Context.Service<
  InfinitusRunningTurns,
  InfinitusRunningTurnsShape
>()("t3/infinitus/Services/InfinitusRunningTurns") {}
