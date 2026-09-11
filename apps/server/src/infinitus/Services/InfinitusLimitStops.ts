import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Stream from "effect/Stream";

export interface InfinitusLimitStopsShape {
  /** The threads whose turn stopped on a usage limit and wait for a swap
      (#648, #270 I), oldest first: the list on subscribe, then the whole list
      again on every change. Lost with a restart, like the stops. */
  readonly stopped: Stream.Stream<ReadonlyArray<InfinitusHeldThread>>;
}

export class InfinitusLimitStops extends Context.Service<
  InfinitusLimitStops,
  InfinitusLimitStopsShape
>()("t3/infinitus/Services/InfinitusLimitStops") {}
