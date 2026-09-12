import type { ThreadUsageRollup } from "@t3tools/contracts";

import { formatContextWindowTokens } from "~/lib/contextWindow";

/**
 * Fork (#834): the words of the thread-info popover. Every figure is an
 * estimate the runtime or a transcript reported, never billing truth, so
 * a cost always carries "≈" and a rollup without one says so instead of
 * showing zero.
 */

/** "≈ $0.35", "≈ < $0.01" for a positive cost under half a cent, or the
    absence of a figure — never "$0.00" for "nothing recorded". */
export function threadUsageCostLabel(costUsd: number | null): string {
  if (costUsd === null || !Number.isFinite(costUsd)) return "Cost not recorded";
  if (costUsd > 0 && costUsd < 0.005) return "≈ < $0.01";
  return `≈ $${costUsd.toFixed(2)}`;
}

/** The header badge: the cost when one is known, else the turn count. */
export function threadUsageBadgeLabel(usage: ThreadUsageRollup): string {
  if (usage.costUsd !== null) return threadUsageCostLabel(usage.costUsd);
  return usage.turns === 1 ? "1 turn" : `${usage.turns} turns`;
}

/** The badge's accessible name says "approximately" where the label draws "≈". */
export function threadUsageBadgeAriaLabel(usage: ThreadUsageRollup): string {
  return `Thread usage: ${threadUsageBadgeLabel(usage).replace("≈ ", "approximately ")}`;
}

export interface ThreadUsageRow {
  readonly label: string;
  readonly value: string;
}

/** The popover's label/value rows: turns first, then the token counts
    that moved (a zero row is left out), then the models. */
export function threadUsageRows(usage: ThreadUsageRollup): ReadonlyArray<ThreadUsageRow> {
  const turns =
    usage.subagentTurns > 0
      ? `${usage.turns} (${usage.subagentTurns} with subagents)`
      : `${usage.turns}`;
  const rows: ThreadUsageRow[] = [{ label: "Turns", value: turns }];
  const tokens: ReadonlyArray<readonly [string, number]> = [
    ["Input tokens", usage.inputTokens],
    ["Output tokens", usage.outputTokens],
    ["Cached input", usage.cachedInputTokens],
    ["Cache creation", usage.cacheCreationTokens],
    ["Reasoning", usage.reasoningTokens],
  ];
  for (const [label, count] of tokens) {
    if (count > 0) rows.push({ label, value: formatContextWindowTokens(count) });
  }
  if (usage.models.length > 0) {
    rows.push({
      label: usage.models.length === 1 ? "Model" : "Models",
      value: usage.models.join(", "),
    });
  }
  return rows;
}

/** One line under the rows when the figures came from a transcript rather
    than the runtime, so a backfilled thread reads as what it is. */
export function threadUsageSourceLine(usage: ThreadUsageRollup): string | null {
  return usage.source === "transcript" ? "Estimated from the transcript" : null;
}

/** The source line's tooltip: what a transcript estimate is and is not,
    so the number explains itself (#834). */
export function threadUsageSourceDetail(usage: ThreadUsageRollup): string | null {
  return usage.source === "transcript"
    ? "Turns come from this server; tokens and cost are the whole transcript's total, so turns before this thread or removed by a revert count too. Only the default Claude home is read; Codex threads are not estimated."
    : null;
}
