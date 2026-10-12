import type { EnvironmentId, ThreadId } from "@infinitus/contracts";
import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";
import { AsyncResult, Atom } from "effect/reactivity";

import type { EnvironmentCatalogState } from "./connections.ts";

/** The key a thread's stop is filed under across environments. */
export function limitStopKey(environmentId: EnvironmentId, threadId: ThreadId): string {
  return `${environmentId}:${threadId}`;
}

/**
 * The threads a Claude usage limit stopped, over every connected environment
 * (#648, #1627): one subscription per environment (`subscribeInfinitusLimitStops`),
 * folded into one map the sidebar and the phone's thread list read per row.
 * An environment whose stream is still loading, refused or gone contributes
 * nothing — a plain server has no limit stops to show. The map is only
 * replaced when a stop appears, leaves or changes, so rows do not re-render
 * on every snapshot tick.
 */
export function createInfinitusLimitStopsAtom(input: {
  readonly catalogValueAtom: Atom.Atom<EnvironmentCatalogState>;
  readonly limitStopsAtom: (target: {
    readonly environmentId: EnvironmentId;
    readonly input: {};
  }) => Atom.Atom<AsyncResult.AsyncResult<ReadonlyArray<InfinitusLimitStop>, unknown>>;
}): Atom.Atom<ReadonlyMap<string, InfinitusLimitStop>> {
  let previous: ReadonlyMap<string, InfinitusLimitStop> = new Map();
  return Atom.make((get) => {
    const next = new Map<string, InfinitusLimitStop>();
    for (const [environmentId, entry] of get(input.catalogValueAtom).entries) {
      if (!entry.enabled) continue;
      const result = get(input.limitStopsAtom({ environmentId, input: {} }));
      const stops = AsyncResult.value(result);
      if (stops._tag !== "Some") continue;
      for (const stop of stops.value) {
        next.set(limitStopKey(environmentId, stop.threadId), stop);
      }
    }
    if (limitStopMapsEqual(previous, next)) return previous;
    previous = next;
    return previous;
  }).pipe(Atom.withLabel("infinitus-limit-stops"));
}

function limitStopMapsEqual(
  left: ReadonlyMap<string, InfinitusLimitStop>,
  right: ReadonlyMap<string, InfinitusLimitStop>,
): boolean {
  if (left.size !== right.size) return false;
  for (const [key, stop] of left) {
    const other = right.get(key);
    if (
      other === undefined ||
      other.kind !== stop.kind ||
      other.since !== stop.since ||
      other.account !== stop.account ||
      other.resetsAt !== stop.resetsAt ||
      other.proxy !== stop.proxy
    )
      return false;
  }
  return true;
}

/**
 * The stop's one line for a tooltip or a row: who hit the limit, and when the
 * window resets while that is still ahead. `formatTime` is the client's own
 * timestamp format, so the instant reads in the user's zone and preference.
 */
export function limitStopLine(
  stop: Pick<InfinitusLimitStop, "account" | "resetsAt" | "proxy">,
  formatTime: (iso: string) => string,
  now: number,
): string {
  const head =
    stop.proxy !== undefined
      ? `Limit hit on the proxy instance ${stop.proxy}`
      : stop.account === null
        ? "Limit hit"
        : `Limit hit on ${stop.account}`;
  if (stop.resetsAt === null) return head;
  const resetsAt = Date.parse(stop.resetsAt);
  if (!Number.isFinite(resetsAt) || resetsAt <= now) return head;
  return `${head} · resets ${formatTime(stop.resetsAt)}`;
}
