/**
 * The lock-screen card's push registration survives a Mac that is not there
 * yet (#941). iOS vends the push-to-start token the moment the bridge
 * attaches — before the environment's WebSocket is up — so the first send
 * fails with an unreachable RPC, and nothing ever fired it again: the Mac
 * held no start token and no card could begin. These are the two rules the
 * bridge retries by.
 */

/** The longest wait between re-sends; every attempt past the table waits it. */
export const RETRY_CAP_MS = 300_000;

/** The waits between re-sends: 5 s, 15 s, 1 min, then the cap. */
const RETRY_DELAYS_MS: ReadonlyArray<number> = [5_000, 15_000, 60_000, RETRY_CAP_MS];

/** The wait before retry number `attempt` (1-based). */
export function retryDelayMs(attempt: number): number {
  return RETRY_DELAYS_MS[Math.max(attempt, 1) - 1] ?? RETRY_CAP_MS;
}

export interface RetrySchedule {
  /** Retries made so far; 0 once every token is on file. */
  readonly attempt: number;
  /** When to try again, null for "not scheduled". */
  readonly delayMs: number | null;
}

export const NO_RETRY: RetrySchedule = { attempt: 0, delayMs: null };

/**
 * What a round of sends does to the schedule. A round that landed everything
 * ends it; one that failed while the Mac is reachable backs off; one that
 * failed while it is not schedules nothing — the connection coming back is
 * the trigger, and counting attempts against an absent Mac would spend the
 * backoff before it could be of any use.
 */
export function nextRetry(input: {
  readonly attempt: number;
  readonly landed: boolean;
  readonly connected: boolean;
}): RetrySchedule {
  if (input.landed || !input.connected) return NO_RETRY;
  const attempt = input.attempt + 1;
  return { attempt, delayMs: retryDelayMs(attempt) };
}

/** The environment is not reachable right now; the Mac never saw the token. */
export function isEnvironmentUnreachable(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { _tag?: unknown })._tag === "EnvironmentRpcUnavailableError"
  );
}
