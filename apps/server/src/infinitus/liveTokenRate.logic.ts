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

/**
 * Tokens a minute over the window, and how many turns are behind the figure.
 *
 * A `usageUnavailable` row is skipped whole: its tokens are zero for "not
 * reported" (Cursor and Grok report none), so counting it would put a turn
 * that burned nothing into the average. A window with no reporting turn
 * answers zero turns, which the page reads as "draw no line" — the rate of a
 * server that ran nothing is not zero, it is unknown.
 */
export function foldLiveTokenRate(
  rows: ReadonlyArray<ThreadTurnUsage>,
  windowMinutes: number = LIVE_TOKEN_RATE_WINDOW_MINUTES,
): InfinitusLiveTokenRate {
  let turns = 0;
  let output = 0;
  let total = 0;
  for (const row of rows) {
    if (row.usageUnavailable === true) continue;
    turns += 1;
    output += row.outputTokens;
    total += row.inputTokens + row.outputTokens;
  }
  const perMinute = (tokens: number) => (turns === 0 ? 0 : tokens / windowMinutes);
  return {
    windowMinutes,
    turns,
    outputPerMinute: perMinute(output),
    totalPerMinute: perMinute(total),
  };
}
