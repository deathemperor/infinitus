import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

import type { ClaudeUsageLimitRefusal } from "../../orchestration-v2/Adapters/ClaudeAdapterV2.ts";

export interface InfinitusLimitStopsShape {
  /** The threads whose turn stopped on a Claude usage limit and wait for a
      swap or a reset (#648, #270 I), oldest first: the list on subscribe,
      then the whole list again on every change. `ws.ts` streams it to the
      clients as `subscribeInfinitusLimitStops`. */
  readonly stopped: Stream.Stream<ReadonlyArray<InfinitusLimitStop>>;
  readonly setStopped: (threads: ReadonlyArray<InfinitusLimitStop>) => Effect.Effect<void>;
  /** A rejected usage window on a running Claude turn, as the adapter saw it
      in the SDK's `rate_limit_event` (#1627). The Claude driver hands the
      adapter this as its `onUsageLimitRefusal` hook; the resume layer reads
      `refusals`. Nothing is kept for a reader that is not subscribed. */
  readonly reportRefusal: (refusal: ClaudeUsageLimitRefusal) => Effect.Effect<void>;
  readonly refusals: Stream.Stream<ClaudeUsageLimitRefusal>;
}

export class InfinitusLimitStops extends Context.Service<
  InfinitusLimitStops,
  InfinitusLimitStopsShape
>()("t3/infinitus/Services/InfinitusLimitStops") {}

// State is separate from the resume layer so the transport (`ws.ts`) and the
// Claude driver can reach it without depending on the layer, which itself
// dispatches orchestration commands.
export const InfinitusLimitStopsLive = Layer.effect(
  InfinitusLimitStops,
  Effect.gen(function* () {
    const stopped = yield* SubscriptionRef.make<ReadonlyArray<InfinitusLimitStop>>([]);
    const refusals = yield* PubSub.unbounded<ClaudeUsageLimitRefusal>();
    return InfinitusLimitStops.of({
      stopped: SubscriptionRef.changes(stopped),
      setStopped: Effect.fn("InfinitusLimitStops.setStopped")(function (threads) {
        return SubscriptionRef.set(stopped, threads);
      }),
      reportRefusal: Effect.fn("InfinitusLimitStops.reportRefusal")(function (refusal) {
        return PubSub.publish(refusals, refusal).pipe(Effect.asVoid);
      }),
      refusals: Stream.fromPubSub(refusals),
    });
  }),
);
