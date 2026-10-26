import type { ThreadId, ThreadUsageRollup } from "@infinitus/contracts";

import type { SessionUsage } from "../usage/UsageService.ts";

/**
 * Usage backfill (#834, #1627): the pure half. A thread whose turns ran before this server recorded
 * usage gets one baseline on its app thread (`usageBaseline`): the fork's v1 rollup (`v1Usage`) if
 * any, else the Claude transcript total. Transcripts do not delimit turns, so that estimate is
 * thread-level (turn count from completed runs) and `source: "transcript"` says so.
 */
export interface ThreadUsageBackfillCandidate {
  readonly threadId: ThreadId;
  /** The v1 rollup the import left behind, already decoded; null for none. */
  readonly v1Usage: ThreadUsageRollup | null;
  /** The root Claude session's id, from the provider thread's native ref or
      the v1 session binding; null when the thread never ran on Claude. */
  readonly claudeSessionId: string | null;
  /** Completed runs the orchestrator knows. */
  readonly turns: number;
  /** The newest mark on any run, whatever its state; null for none. */
  readonly lastTurnAt: string | null;
  /** Whether a provider turn of this server already carries usage: then a
      transcript total would count those turns twice. */
  readonly recordedUsage: boolean;
}

/**
 * Whether a candidate's turns all predate this server's boot. A turn this server ran is recorded by
 * the orchestrator (or was interrupted, with usage half-written to the transcript), so a candidate
 * whose newest run postdates boot is not legacy: reading the transcript would count that turn
 * twice.
 */
export function isLegacyCandidate(
  candidate: Pick<ThreadUsageBackfillCandidate, "lastTurnAt">,
  bootAt: string,
): boolean {
  return candidate.lastTurnAt === null || candidate.lastTurnAt < bootAt;
}

/** Whether the transcript is worth reading for this candidate. */
export function wantsTranscript(candidate: ThreadUsageBackfillCandidate, bootAt: string): boolean {
  return (
    candidate.v1Usage === null &&
    candidate.claudeSessionId !== null &&
    !candidate.recordedUsage &&
    isLegacyCandidate(candidate, bootAt)
  );
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

/**
 * The baseline a candidate gets, or undefined for none: the v1 rollup when
 * the import carried one, else the transcript's total when the session was
 * read and the thread's turns all predate boot.
 */
export function baselineForCandidate(
  candidate: ThreadUsageBackfillCandidate,
  sessions: ReadonlyMap<string, SessionUsage>,
  bootAt: string,
): ThreadUsageRollup | undefined {
  if (candidate.v1Usage !== null) return candidate.v1Usage;
  if (!wantsTranscript(candidate, bootAt) || candidate.claudeSessionId === null) return undefined;
  const session = sessions.get(candidate.claudeSessionId);
  return session === undefined ? undefined : transcriptUsageRollup(session, candidate.turns);
}
