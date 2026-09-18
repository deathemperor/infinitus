import type { InfinitusHeldThread } from "@infinitus/contracts/infinitus";
import type { ThreadId } from "@infinitus/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

export interface InfinitusLimitStopsShape {
  /** The threads whose turn stopped on a usage limit and wait for a swap
      (#648, #270 I), oldest first: the list on subscribe, then the whole list
      again on every change. Lost with a restart, like the stops. */
  readonly stopped: Stream.Stream<ReadonlyArray<InfinitusHeldThread>>;
  readonly isStopped: (threadId: ThreadId) => Effect.Effect<boolean>;
  readonly setStopped: (threads: ReadonlyArray<InfinitusHeldThread>) => Effect.Effect<void>;
}

export class InfinitusLimitStops extends Context.Service<
  InfinitusLimitStops,
  InfinitusLimitStopsShape
>()("t3/infinitus/Services/InfinitusLimitStops") {}

// State is separate from the resume worker so settlement can read it without
// depending on the worker, which itself dispatches orchestration commands.
export const InfinitusLimitStopsLive = Layer.effect(
  InfinitusLimitStops,
  Effect.gen(function* () {
    const stopped = yield* SubscriptionRef.make<ReadonlyArray<InfinitusHeldThread>>([]);
    return InfinitusLimitStops.of({
      stopped: SubscriptionRef.changes(stopped),
      isStopped: (threadId) =>
        SubscriptionRef.get(stopped).pipe(
          Effect.map((threads) => threads.some((thread) => thread.threadId === threadId)),
        ),
      setStopped: (threads) => SubscriptionRef.set(stopped, threads),
    });
  }),
);
