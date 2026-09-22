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
      again on every change. Unresolved failed turns are restored from their
      saved limit markers at startup. */
  readonly stopped: Stream.Stream<ReadonlyArray<InfinitusHeldThread>>;
  readonly isStopped: (threadId: ThreadId) => Effect.Effect<boolean>;
  readonly setStopped: (threads: ReadonlyArray<InfinitusHeldThread>) => Effect.Effect<void>;
  /** The threads a limit resume is sending into right now (#1509), published
      like `stopped`: the list on subscribe, then the whole list again on
      every change, so a reader can act on a thread being let go as well as
      on it being claimed. Why the claim exists:
      `docs/internals/turn-queue.md`. */
  readonly resuming: Stream.Stream<ReadonlyArray<ThreadId>>;
  readonly isResuming: (threadId: ThreadId) => Effect.Effect<boolean>;
  readonly setResuming: (threadId: ThreadId, resuming: boolean) => Effect.Effect<void>;
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
    const resuming = yield* SubscriptionRef.make<ReadonlyArray<ThreadId>>([]);
    return InfinitusLimitStops.of({
      stopped: SubscriptionRef.changes(stopped),
      isStopped: (threadId) =>
        SubscriptionRef.get(stopped).pipe(
          Effect.map((threads) => threads.some((thread) => thread.threadId === threadId)),
        ),
      setStopped: (threads) => SubscriptionRef.set(stopped, threads),
      resuming: SubscriptionRef.changes(resuming),
      isResuming: (threadId) =>
        SubscriptionRef.get(resuming).pipe(Effect.map((threads) => threads.includes(threadId))),
      setResuming: (threadId, value) =>
        SubscriptionRef.update(resuming, (threads) =>
          value
            ? threads.includes(threadId)
              ? threads
              : [...threads, threadId]
            : threads.filter((id) => id !== threadId),
        ),
    });
  }),
);
