import type { ThreadId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

import type { TurnStartGateShape } from "../../orchestration/Services/TurnStartGate.ts";

/** What "Run now" did: `released` when a held start was run, otherwise the
    one-line reason (nothing was held for that thread). Never an error. */
export interface InfinitusSessionHoldRelease {
  readonly released: boolean;
  readonly reason?: string;
}

export interface InfinitusSessionHoldShape {
  /** The `TurnStartGate` this layer implements: holds a background thread's
      start while its fleet reads low headroom (#616). */
  readonly start: TurnStartGateShape["start"];
  /** Runs the thread's held starts now, whatever the fleet reads ("Run now"). */
  readonly release: (threadId: ThreadId) => Effect.Effect<InfinitusSessionHoldRelease>;
}

export class InfinitusSessionHold extends Context.Service<
  InfinitusSessionHold,
  InfinitusSessionHoldShape
>()("t3/infinitus/Services/InfinitusSessionHold") {}
