import type { InfinitusLiveTokenRate } from "@t3tools/contracts/infinitus";
import type { ThreadTurnUsage } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";

/**
 * Fork (#1127): the Utilization page's live output rate, folded from the turns
 * this server recorded. It replaces the Mac's `liveRate`, which tails terminal
 * transcripts — a source the session sweep (#1041) retires.
 *
 * The window is five minutes, the wording the Mac's line already used, and
 * short enough that "live" means it.
 */
const LIVE_TOKEN_RATE_WINDOW_MINUTES = 5;
const LIVE_TOKEN_RATE_WINDOW = Duration.minutes(LIVE_TOKEN_RATE_WINDOW_MINUTES);

/** The instant `foldLiveTokenRate`'s rows must have completed at or after. */
export function liveTokenRateSince(now: DateTime.Utc): string {
  return DateTime.formatIso(DateTime.subtractDuration(now, LIVE_TOKEN_RATE_WINDOW));
}

/** What a read that could not answer reports: no turns, so the page draws no line. */
export const EMPTY_LIVE_TOKEN_RATE: InfinitusLiveTokenRate = {
  windowMinutes: LIVE_TOKEN_RATE_WINDOW_MINUTES,
  turns: 0,
  outputPerMinute: 0,
  totalPerMinute: 0,
};

export interface LiveTokenRateWindow {
  /** The window's end — normally now, when the read was taken. */
  readonly nowMs: number;
  readonly windowMinutes?: number;
}

/**
 * Tokens a minute over the window, and how many turns are behind the figure.
 *
 * A turn's tokens are spread over the wall time it ran (`durationMs`, what the
 * ingestion counted between `turn.started` and `turn.completed`), and only the
 * part of that span lying inside the window counts. Without that clip a turn
 * that ran thirty minutes and completed a minute ago drops all of its output
 * into a five-minute window and reads about six times the true rate — far
 * past what the page's `≈` can carry. Carried over from the withdrawn #1148,
 * which got this right.
 *
 * A row with no `durationMs` — a turn this server never saw start, or one from
 * before the ingestion counted wall time — counts whole at its completion:
 * there is nothing to spread it over, and dropping it would understate a
 * server whose turns all predate that counting.
 *
 * A `usageUnavailable` row is skipped whole: its tokens are zero for "not
 * reported" (Cursor and Grok report none), so counting it would put a turn
 * that burned nothing into the average. A window with no reporting turn
 * answers zero turns, which the page reads as "draw no line" — the rate of a
 * server that ran nothing is not zero, it is unknown.
 */
export function foldLiveTokenRate(
  rows: ReadonlyArray<ThreadTurnUsage>,
  window: LiveTokenRateWindow,
): InfinitusLiveTokenRate {
  const windowMinutes = window.windowMinutes ?? LIVE_TOKEN_RATE_WINDOW_MINUTES;
  const windowStart = window.nowMs - windowMinutes * 60_000;
  let turns = 0;
  let output = 0;
  let total = 0;
  for (const row of rows) {
    if (row.usageUnavailable === true) continue;
    const end = Date.parse(row.completedAt);
    if (Number.isNaN(end)) continue;
    const duration = row.durationMs !== undefined && row.durationMs > 0 ? row.durationMs : 0;
    const start = end - duration;
    // The read already asked for rows completed inside the window, but a turn
    // whose span ends before it or starts after it contributes nothing.
    if (end < windowStart || start > window.nowMs) continue;
    turns += 1;
    if (duration === 0) {
      output += row.outputTokens;
      total += row.inputTokens + row.outputTokens;
      continue;
    }
    const inside = Math.min(end, window.nowMs) - Math.max(start, windowStart);
    if (inside <= 0) continue;
    const share = inside / duration;
    output += row.outputTokens * share;
    total += (row.inputTokens + row.outputTokens) * share;
  }
  const perMinute = (tokens: number) => (turns === 0 ? 0 : tokens / windowMinutes);
  return {
    windowMinutes,
    turns,
    outputPerMinute: perMinute(output),
    totalPerMinute: perMinute(total),
  };
}
