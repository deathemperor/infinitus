import type { InfinitusHoldRow, ThreadId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

import type { InfinitusSessionHoldRelease } from "./InfinitusSessionHold.ts";

export interface InfinitusSessionInterruptShape {
  /** Continues the thread's paused turn now, whatever the fleet reads
      ("Resume now"). `released` when a paused turn was continued, otherwise
      the one-line reason (nothing is paused for that thread). Never an error. */
  readonly resume: (threadId: ThreadId) => Effect.Effect<InfinitusSessionHoldRelease>;
  /** The turns paused right now, oldest first, as `kind: "paused"` rows for
      the CLI's holds read (#822); the sidebar reads the pause marker instead. */
  readonly paused: Effect.Effect<ReadonlyArray<InfinitusHoldRow>>;
}

export class InfinitusSessionInterrupt extends Context.Service<
  InfinitusSessionInterrupt,
  InfinitusSessionInterruptShape
>()("t3/infinitus/Services/InfinitusSessionInterrupt") {}
