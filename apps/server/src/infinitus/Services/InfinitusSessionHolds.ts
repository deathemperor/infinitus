import type { ThreadId } from "@infinitus/contracts";
import type {
  InfinitusHeldThread,
  InfinitusReleaseThreadResult,
} from "@infinitus/contracts/infinitus";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";

/**
 * Session priority mode's face to the clients (#616, #743, #1627): what `subscribeInfinitusHolds`
 * streams and `infinitus.releaseThread` does. The policies that fill it land with the queue lane's
 * gate; until then `InfinitusSessionHoldsIdle` holds nothing.
 */
export interface InfinitusSessionHoldsShape {
  /** The threads held or paused right now, oldest first: the whole list on
      subscribe, then again on every change (#741). */
  readonly held: Stream.Stream<ReadonlyArray<InfinitusHeldThread>>;
  /** "Run now" / "Resume now": runs a held start, else continues a paused
      turn, whatever the fleet reads. `released` when something ran,
      otherwise the one-line reason. Never an error. */
  readonly release: (threadId: ThreadId) => Effect.Effect<InfinitusReleaseThreadResult>;
}

export class InfinitusSessionHolds extends Context.Service<
  InfinitusSessionHolds,
  InfinitusSessionHoldsShape
>()("t3/infinitus/Services/InfinitusSessionHolds") {}

/** Nothing held: the empty list once, and every release answers with the reason. */
export const InfinitusSessionHoldsIdle = Layer.succeed(
  InfinitusSessionHolds,
  InfinitusSessionHolds.of({
    held: Stream.make([]),
    release: Effect.fn("InfinitusSessionHolds.release")(function () {
      return Effect.succeed({ released: false, reason: "nothing is held or paused" });
    }),
  }),
);
