import type { ExecutionEnvironmentDescriptor } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Effect from "effect/Effect";

import { InfinitusService } from "../Services/Infinitus.ts";
import { isNotPolled } from "./Infinitus.ts";

/** The tunnel's word for "fronting the port right now". */
const TUNNEL_UP = "up";

/**
 * The other base URLs this server answers on, read off the app's status (#663):
 * the fork tunnel's URL while it is up. Empty when the app is away, the tunnel
 * is off or down, or the build predates the tunnel.
 */
export function alternateHttpBaseUrls(snapshot: InfinitusSnapshot): ReadonlyArray<string> {
  const tunnel = snapshot.status?.forkTunnel;
  if (tunnel === undefined || tunnel.state !== TUNNEL_UP || tunnel.url === undefined) return [];
  return [tunnel.url];
}

/**
 * The descriptor with the alternate hosts on it. The snapshot is a passive
 * read, so on a server nobody is watching the first descriptor request runs
 * one poll cycle to have anything to say; after that the loop (or the next
 * request on a still-idle server) keeps it current enough — a phone re-learns
 * the hosts on every connect anyway.
 */
export const withAlternateHttpBaseUrls = Effect.fn("Infinitus.withAlternateHttpBaseUrls")(
  function* (descriptor: ExecutionEnvironmentDescriptor) {
    const infinitus = yield* InfinitusService;
    let snapshot = yield* infinitus.snapshot;
    if (isNotPolled(snapshot)) {
      yield* infinitus.refresh;
      snapshot = yield* infinitus.snapshot;
    }
    const alternates = alternateHttpBaseUrls(snapshot);
    return alternates.length === 0
      ? descriptor
      : { ...descriptor, alternateHttpBaseUrls: alternates };
  },
);
