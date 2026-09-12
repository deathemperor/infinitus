import type { ThreadUsageRollup } from "@t3tools/contracts";
import { formatDuration } from "@t3tools/shared/orchestrationTiming";
import { threadUsageReported } from "@t3tools/shared/threadUsage";
import { formatDateTimeShort, formatTokens, formatUsd } from "@t3tools/shared/usageFormat";

/** One card of the thread usage sheet. */
export interface ThreadUsageRow {
  readonly label: string;
  readonly value: string;
}

/**
 * Fork (#834): the thread usage sheet's rows from the server's rollup, worded
 * like the web's thread-info popover (#907). Every number is the provider's
 * own estimate, so each value carries "≈" itself rather than a caption a
 * reader can skip; a token share that is zero is left out; a rollup no turn
 * of which carried a cost says so instead of showing $0.00 (Codex turns
 * record tokens and no cost). Tool calls and the time working (#927) show
 * only when the server counted them — absent, never zero, on turns it did
 * not see start. A thread no recorded turn of which reported usage (a Cursor
 * or Grok thread, `threadUsageReported` false) keeps those counts and the
 * last turn; its zero tokens and missing cost are not figures, so the token
 * and cost rows go and the first note says so.
 */
export function threadUsageRows(usage: ThreadUsageRollup): ReadonlyArray<ThreadUsageRow> {
  const reported = threadUsageReported(usage);
  const tokens = (label: string, count: number): ThreadUsageRow[] =>
    count === 0 || !reported ? [] : [{ label, value: `≈ ${formatTokens(count)}` }];
  return [
    { label: "Turns", value: turnsValue(usage) },
    ...(usage.toolCalls === undefined
      ? []
      : [{ label: "Tool calls", value: String(usage.toolCalls) }]),
    ...(usage.durationMs === undefined
      ? []
      : [{ label: "Duration", value: formatDuration(usage.durationMs) }]),
    ...tokens("Input tokens", usage.inputTokens),
    ...tokens("Output tokens", usage.outputTokens),
    ...tokens("Cached input", usage.cachedInputTokens),
    ...tokens("Cache creation", usage.cacheCreationTokens),
    ...tokens("Reasoning", usage.reasoningTokens),
    ...(usage.models.length === 0
      ? []
      : [
          { label: usage.models.length === 1 ? "Model" : "Models", value: usage.models.join(", ") },
        ]),
    ...(reported
      ? [
          {
            label: "Cost",
            value: usage.costUsd === null ? "Cost not recorded" : `≈ ${formatUsd(usage.costUsd)}`,
          },
        ]
      : []),
    { label: "Last turn", value: formatDateTimeShort(usage.lastTurnAt) },
  ];
}

function turnsValue(usage: ThreadUsageRollup): string {
  if (usage.subagentTurns === 0) return String(usage.turns);
  return `${usage.turns} (${usage.subagentTurns} ran subagents)`;
}

/**
 * The caveats under the rows: what the numbers are, and where they
 * understate. Always at least the first.
 */
export function threadUsageNotes(usage: ThreadUsageRollup): ReadonlyArray<string> {
  const notes = [
    threadUsageReported(usage)
      ? "Estimates from the provider, not billing."
      : "Usage not reported by this provider.",
  ];
  if (usage.source === "transcript") notes.push("Estimated from the transcript.");
  if (usage.subagentTurns > 0) notes.push("Subagent tokens are not counted.");
  return notes;
}
