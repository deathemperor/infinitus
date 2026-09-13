import type { InfinitusRunRate } from "@t3tools/contracts/infinitus";
import type { ThreadTurnUsage } from "@t3tools/contracts";

/**
 * Fork (#1127): the rolling window behind `infinitus.runRate` — what the
 * turns this server finished in the last few minutes moved, so the
 * Utilization page can show a live rate again now that the Mac's
 * transcript tail is gone.
 *
 * Pure on purpose: the layer keeps the samples and the clock, this file
 * decides what a turn contributes and what the window sums to.
 */

/** The window the page is told about; the reader divides by it. */
const RUN_RATE_WINDOW_MINUTES = 5;
export const RUN_RATE_WINDOW_MS = RUN_RATE_WINDOW_MINUTES * 60_000;

export interface RunRateSample {
  /** The turn's completion, epoch millis. */
  readonly at: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
}

/**
 * What a recorded turn contributes, or null when it contributes nothing: a
 * turn whose provider reported no usage (`usageUnavailable`, Cursor and Grok
 * on every turn) carries zeros that would count as a turn at no tokens and
 * drag the rate down, and a completion this server cannot date cannot be
 * placed in the window.
 */
export function runRateSample(usage: ThreadTurnUsage): RunRateSample | null {
  if (usage.usageUnavailable === true) return null;
  const at = Date.parse(usage.completedAt);
  if (!Number.isFinite(at)) return null;
  return {
    at,
    outputTokens: usage.outputTokens,
    totalTokens:
      usage.inputTokens + usage.outputTokens + usage.cachedInputTokens + usage.cacheCreationTokens,
  };
}

/** The samples still inside the window at `now`, oldest first. A sample the
    window has passed is dropped for good; one dated slightly ahead of this
    clock is kept, since it is the same server's own stamp. */
export function withinWindow(
  samples: ReadonlyArray<RunRateSample>,
  now: number,
): ReadonlyArray<RunRateSample> {
  return samples.filter((sample) => now - sample.at < RUN_RATE_WINDOW_MS);
}

/** The window summed, the shape the RPC answers. No turn in it is a `turns`
    of 0 with zero tokens — "nothing finished here", which the client draws as
    no line at all rather than as a rate of zero. */
export function foldRunRate(samples: ReadonlyArray<RunRateSample>, now: number): InfinitusRunRate {
  const live = withinWindow(samples, now);
  return {
    windowMinutes: RUN_RATE_WINDOW_MINUTES,
    turns: live.length,
    outputTokens: live.reduce((sum, sample) => sum + sample.outputTokens, 0),
    totalTokens: live.reduce((sum, sample) => sum + sample.totalTokens, 0),
  };
}
