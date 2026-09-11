import type { InfinitusHoldRow, ThreadId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import type * as Stream from "effect/Stream";

import type { InfinitusSessionHoldRelease } from "./InfinitusSessionHold.ts";

export interface InfinitusSessionInterruptShape {
  /** Continues the thread's paused turn now, whatever the fleet reads
      ("Resume now"). `released` when a paused turn was continued, otherwise
      the one-line reason (nothing is paused for that thread). Never an error. */
  readonly resume: (threadId: ThreadId) => Effect.Effect<InfinitusSessionHoldRelease>;
  /** The turns paused right now, oldest first, as `kind: "paused"` rows for
      the CLI's holds read (#822); the sidebar reads the pause marker instead. */
  readonly paused: Effect.Effect<ReadonlyArray<InfinitusHoldRow>>;
  /** The threads paused right now, oldest first: the list on subscribe, then
      every change. The queue drain (#806) waits on it like on `held`. */
  readonly pausedThreads: Stream.Stream<ReadonlyArray<ThreadId>>;
}

export class InfinitusSessionInterrupt extends Context.Service<
  InfinitusSessionInterrupt,
  InfinitusSessionInterruptShape
>()("t3/infinitus/Services/InfinitusSessionInterrupt") {}
