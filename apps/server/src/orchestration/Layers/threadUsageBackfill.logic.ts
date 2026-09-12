import type { ThreadUsageRollup } from "@t3tools/contracts";

import type { ThreadUsageBackfillCandidate } from "../../persistence/ProjectionTurnUsage.ts";
import type { SessionUsage } from "../../usage/UsageService.ts";

/**
 * Transcript backfill (#834): the pure half. A thread whose turns ran before
 * usage was recorded gets one rollup estimated from its Claude transcript.
 * Transcripts do not delimit turns, so the rollup is thread-level: the turn
 * count comes from the runtime's own rows, the tokens and cost from the
 * transcript's total, and `source: "transcript"` says so.
 */

/**
 * Whether a candidate's turns all predate this server's boot. A turn this
 * server ran is recorded by the runtime (or was interrupted or errored,
 * with its usage half-written to the transcript), so a candidate whose
 * newest turn row postdates boot is not legacy: reading the transcript on
 * top would count that turn twice, or count a turn that never completed.
 */
export function isLegacyCandidate(
  candidate: Pick<ThreadUsageBackfillCandidate, "lastTurnAt">,
  bootAt: string,
): boolean {
  return candidate.lastTurnAt === null || candidate.lastTurnAt < bootAt;
}

/** The rollup a session's transcript total becomes. Subagent turns and reasoning are unknown. */
export function transcriptUsageRollup(session: SessionUsage, turns: number): ThreadUsageRollup {
  const { totals } = session;
  return {
    source: "transcript",
    turns,
    inputTokens: totals.uncachedInputTokens + totals.cachedInputTokens + totals.cacheCreationTokens,
    outputTokens: totals.outputTokens,
    cachedInputTokens: totals.cachedInputTokens,
    cacheCreationTokens: totals.cacheCreationTokens,
    reasoningTokens: totals.reasoningTokens,
    subagentTurns: 0,
    costUsd: session.costUsd,
    models: session.models,
    lastTurnAt: session.lastAt,
  };
}
