/**
 * Fork (#1127): the live output rate the Utilization page draws, computed
 * from this server's own per-turn usage rows (#834) instead of the Mac's
 * transcript tail.
 *
 * A turn's tokens are spread over the wall time it ran (`durationMs`, what
 * the ingestion counted between `turn.started` and `turn.completed`, hold
 * and queue waits excluded), and only the part of that span lying inside
 * the window counts: a ten-minute turn finishing now would otherwise drop
 * all its tokens into a five-minute window and read twice the true rate.
 * A row without a duration — a turn this server did not see start — counts
 * whole at its completion.
 */

/** The window the page's wording promises: "over the last 5 minutes". */
export const LIVE_RATE_WINDOW_MS = 5 * 60_000;

/** What the rate needs of a `ThreadTurnUsage` row. */
export interface LiveRateTurn {
  readonly outputTokens: number;
  readonly completedAt: string;
  readonly durationMs?: number | undefined;
}

export interface LiveOutputRate {
  readonly perMinute: number;
}

/**
 * Output tokens per minute over the five minutes before `nowMs`, or null
 * when no turn of `turns` touched that window — the page then draws
 * nothing rather than a zero that would read as an idle fleet.
 */
export function liveOutputRate(
  turns: ReadonlyArray<LiveRateTurn>,
  nowMs: number,
): LiveOutputRate | null {
  const windowStart = nowMs - LIVE_RATE_WINDOW_MS;
  let tokens = 0;
  let touched = false;
  for (const turn of turns) {
    const end = Date.parse(turn.completedAt);
    if (Number.isNaN(end)) continue;
    const duration = turn.durationMs !== undefined && turn.durationMs > 0 ? turn.durationMs : 0;
    const start = end - duration;
    if (end < windowStart || start > nowMs) continue;
    touched = true;
    if (duration === 0) {
      tokens += turn.outputTokens;
      continue;
    }
    const inside = Math.min(end, nowMs) - Math.max(start, windowStart);
    if (inside > 0) tokens += (turn.outputTokens * inside) / duration;
  }
  if (!touched) return null;
  return { perMinute: Math.round(tokens / (LIVE_RATE_WINDOW_MS / 60_000)) };
}
