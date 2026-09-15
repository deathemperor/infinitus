import * as Effect from "effect/Effect";
import * as Queue from "effect/Queue";
import * as Stream from "effect/Stream";

import type { MobileApplicationActiveWakeup } from "../../connection/app-state-wakeups";

/**
 * A connection wakeup a fork feature asks for (#1277): the thread-card bridge
 * learns of a card iOS started from a push-to-start while the app sits in the
 * background, and the socket to the Mac is down then — the supervisor only
 * re-establishes it on the app becoming active. This is the same
 * `application-active-reconnect` the foreground sends, requested early, so
 * the card's token can go in the background window iOS grants. The stream is
 * merged into the platform's wakeups; requests before the runtime listens are
 * dropped, since the connection is about to be built anyway.
 */
const listeners = new Set<(reason: MobileApplicationActiveWakeup) => void>();

export function requestConnectionWakeup(reason: MobileApplicationActiveWakeup): void {
  for (const listener of listeners) listener(reason);
}

export const requestedConnectionWakeups: Stream.Stream<MobileApplicationActiveWakeup> =
  Stream.callback<MobileApplicationActiveWakeup>((queue) =>
    Effect.acquireRelease(
      Effect.sync(() => {
        const listener = (reason: MobileApplicationActiveWakeup) => {
          Queue.offerUnsafe(queue, reason);
        };
        listeners.add(listener);
        return listener;
      }),
      (listener) => Effect.sync(() => listeners.delete(listener)),
    ).pipe(Effect.asVoid),
  );
