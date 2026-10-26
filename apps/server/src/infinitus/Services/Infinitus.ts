import type {
  InfinitusCommandFailed,
  InfinitusCommandInput,
  InfinitusProtocolError,
  InfinitusSnapshot,
  InfinitusSubscribeInput,
  InfinitusUnavailable,
} from "@infinitus/contracts/infinitus";
import * as Context from "effect/Context";
import type * as Effect from "effect/Effect";
import type * as Stream from "effect/Stream";

export interface InfinitusServiceShape {
  /**
   * The latest snapshot, whatever the socket's state. Never fails: an app that
   * cannot be reached is `available: false` with a reason, not an error.
   * Answers from the last poll — reading this does not start one, so before the
   * first cycle it answers a placeholder that says as much.
   */
  readonly snapshot: Effect.Effect<InfinitusSnapshot>;
  /**
   * The current snapshot, then every change. Subscribing is what makes the service poll: the first
   * subscriber starts the loop, the last to leave stops it. `needs` names lease scopes beyond the
   * fast set (`stats`). The first emission is a polled snapshot, never the pre-poll placeholder, so
   * a subscriber does not flash an offline state.
   */
  readonly changes: (input?: InfinitusSubscribeInput) => Stream.Stream<InfinitusSnapshot>;
  /**
   * Every change some subscriber's poll produces, and nothing else: reading
   * this never starts a poll, so a server nobody is watching still never
   * touches the socket. For work that reacts to the app coming or going only
   * while a client is already looking.
   */
  readonly observed: Stream.Stream<InfinitusSnapshot>;
  /**
   * One poll cycle now, whatever the subscriber count — for a reader that
   * needs a real snapshot once (the environment descriptor's alternate hosts,
   * #663) on a server nobody is watching. Serialized with the loop's own
   * cycle; never fails, an unreachable app lands as `available: false`.
   */
  readonly refresh: Effect.Effect<void>;
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
