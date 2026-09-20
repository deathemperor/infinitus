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
  /** Whether a resume is sending into this thread right now (#1509). The
      resume replaces the thread's CLI and then sends its continuation, and
      between the two the new session reports `ready` with no turn on it —
      idle to everything that reads the projection. The queue drain asks
      here so it does not put a second send into that window: both turns then
      run, the CLI answers under one, and the other never completes, which
      leaves the session `running` and the row reading "Working" for good. */
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
    // Read on demand rather than published: the window is a few seconds, and
    // the send that ends it wakes the drain through the session events it
    // already watches.
    const resuming = new Set<ThreadId>();
    return InfinitusLimitStops.of({
      stopped: SubscriptionRef.changes(stopped),
      isStopped: (threadId) =>
        SubscriptionRef.get(stopped).pipe(
          Effect.map((threads) => threads.some((thread) => thread.threadId === threadId)),
        ),
      setStopped: (threads) => SubscriptionRef.set(stopped, threads),
      isResuming: (threadId) => Effect.sync(() => resuming.has(threadId)),
      setResuming: (threadId, value) =>
        Effect.sync(() => {
          if (value) resuming.add(threadId);
          else resuming.delete(threadId);
        }),
    });
  }),
);
