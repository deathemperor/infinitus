import { useAtomValue } from "@effect/atom-react";
import { limitStopKey, limitStopLine } from "@infinitus/client-runtime/state/infinitusLimitStops";
import type { EnvironmentId, ThreadId } from "@infinitus/contracts";
import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";

import { infinitusLimitStopsAtom } from "../../state/infinitus";

/**
 * Fork (#648): the stop a Claude usage limit parked this thread on, if any.
 * A parked turn is still "running" to the orchestrator; the thread list row
 * reads "Limited" (`resolveThreadListV2Status`'s `limitStopped`) with the
 * account on its detail line until the account swaps and the turn resumes.
 */
export function useThreadLimitStop(thread: {
  readonly environmentId: EnvironmentId;
  readonly id: ThreadId;
}): InfinitusLimitStop | null {
  return (
    useAtomValue(infinitusLimitStopsAtom).get(limitStopKey(thread.environmentId, thread.id)) ?? null
  );
}

/** The row's detail line for a limit stop: the account and the reset, in the
    phone's locale time. */
export function limitStopDetailLine(limitStop: InfinitusLimitStop): string {
  return limitStopLine(
    limitStop,
    (iso) => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }),
    Date.now(),
  );
}
