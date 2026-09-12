import type { ThreadId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusSlackBindingsShape {
  /** Whether the Slack bridge (#574) is armed and reports this thread in a
      Slack thread of its own — the push bridge then tells the Mac to skip
      its Slack webhook post for it, so a milestone lands in Slack once. */
  readonly isBound: (threadId: ThreadId) => Effect.Effect<boolean>;
}

export class InfinitusSlackBindings extends Context.Service<
  InfinitusSlackBindings,
  InfinitusSlackBindingsShape
>()("t3/infinitus/Services/InfinitusSlackBindings") {}
