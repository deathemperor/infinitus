/**
 * The pure half of the live token rate (#1127): the per-turn usage rows this
 * server recorded (#834) folded into a rolling output-tokens-per-minute, and
 * split by the account #779's swap log says each turn ran on.
 *
 * The Mac's own figure tailed terminal transcripts and retires with them
 * (#1041 Lane 4), so this is thread-side arithmetic over records the server
 * already has — no verb, no scan. Nothing here logs; emails reach the caller
 * only as the label the fleet already shows.
 */
import type { InfinitusLiveTokenRate } from "@t3tools/contracts/infinitus";

import type { ProjectionTurnUsage } from "../../persistence/ProjectionTurnUsage.ts";

/** The window the page draws, matching the five minutes the Mac's live line
    reported so the replacement reads the same way. */
export const LIVE_RATE_WINDOW_MINUTES = 5;

export interface LiveRateAccountLookup {
  /** The account's email at the instant, `null` when nothing can say. */
  readonly accountAt: (timestampMs: number) => string | null;
  /** How the fleet names that account. */
  readonly describe: (email: string) => { readonly label: string };
}

/**
 * The rate over `[now - windowMinutes, now]`. Rows are taken as the window's
 * membership test — the caller's query is `completed_at >= since`, and a row
 * whose mark cannot be parsed, or sits in the future, is dropped here rather
 * than counted at an unknown instant.
 *
 * Null when no turn completed in the window: the page shows nothing then,
 * instead of a zero that reads like "nothing is running" when it means "no
 * turn finished". A turn the provider reported no usage for still counts as
 * a turn — it ran — but adds no tokens.
 */
export function liveTokenRate(options: {
  readonly rows: ReadonlyArray<ProjectionTurnUsage>;
  readonly nowMs: number;
  readonly windowMinutes?: number;
  readonly accounts?: LiveRateAccountLookup | null;
}): InfinitusLiveTokenRate | null {
  const windowMinutes = options.windowMinutes ?? LIVE_RATE_WINDOW_MINUTES;
  const fromMs = options.nowMs - windowMinutes * 60_000;
  let outputTokens = 0;
  let turns = 0;
  const threads = new Set<string>();
  const byEmail = new Map<string, number>();
  for (const row of options.rows) {
    const atMs = Date.parse(row.turnUsage.completedAt);
    if (Number.isNaN(atMs) || atMs < fromMs || atMs > options.nowMs) continue;
    turns += 1;
    threads.add(row.threadId);
    const tokens = Math.max(0, row.turnUsage.outputTokens);
    outputTokens += tokens;
    const email = options.accounts?.accountAt(atMs) ?? null;
    if (email !== null) byEmail.set(email, (byEmail.get(email) ?? 0) + tokens);
  }
  if (turns === 0) return null;
  const perMinute = (total: number): number => total / windowMinutes;
  return {
    windowMinutes,
    outputTokens,
    perMinute: perMinute(outputTokens),
    turns,
    threads: threads.size,
    accounts: [...byEmail.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([email, tokens]) => ({
        label: options.accounts?.describe(email).label ?? email,
        outputTokens: tokens,
        perMinute: perMinute(tokens),
      })),
  };
}
