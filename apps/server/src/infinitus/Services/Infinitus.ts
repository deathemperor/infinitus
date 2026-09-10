import type {
  InfinitusCommandFailed,
  InfinitusCommandInput,
  InfinitusProtocolError,
  InfinitusSnapshot,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import type * as Stream from "effect/Stream";

export interface InfinitusServiceShape {
  /**
   * The latest snapshot, whatever the socket's state. Never fails: an app that
   * cannot be reached is `available: false` with a reason, not an error.
   * Answers from the last poll — reading this does not start one.
   */
  readonly snapshot: Effect.Effect<InfinitusSnapshot>;
  /**
   * The current snapshot, then every change to it. Subscribing is what makes
   * the service poll: the first subscriber starts the loop and the last one to
   * leave stops it, so an idle server never touches the socket.
   */
  readonly changes: Stream.Stream<InfinitusSnapshot>;
  /**
   * Forwards one command from the manifest and answers with the reply's
   * `result`. A command the manifest does not list never reaches the socket.
   */
  readonly command: (
    input: InfinitusCommandInput,
  ) => Effect.Effect<
    unknown,
    InfinitusUnavailable | InfinitusProtocolError | InfinitusCommandFailed
  >;
}

export class InfinitusService extends Context.Service<InfinitusService, InfinitusServiceShape>()(
  "t3/infinitus/Services/Infinitus/InfinitusService",
) {}
