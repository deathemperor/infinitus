import type { InfinitusLaunchResult } from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";

export interface InfinitusCompanionShape {
  /**
   * Opens the Infinitus menu-bar app through LaunchServices when its control
   * socket is not answering. Never fails: a host that cannot (not macOS, no
   * socket path) or an `open` that did not exit 0 is a `launched: false` with
   * the reason. The app coming up shows through the snapshot, not here.
   */
  readonly launch: Effect.Effect<InfinitusLaunchResult>;
}

export class InfinitusCompanion extends Context.Service<
  InfinitusCompanion,
  InfinitusCompanionShape
>()("t3/infinitus/Services/InfinitusCompanion") {}
