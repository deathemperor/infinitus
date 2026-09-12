import type { ThreadTurnUsage, ThreadUsageRollup } from "@t3tools/contracts";

/**
 * Fork (#834): a thread's usage rollup, folded one completed turn at a time.
 * The decider folds the thread's current rollup with the turn it records and
 * puts the result on `thread.turn-usage-recorded`, so the projector, the
 * client reducer and the projection pipeline assign it; only a revert
 * refolds from the rows it keeps. A rollup keeps its `source`: a transcript
 * estimate that runtime turns are added to still reads as estimated.
 */
export function addTurnUsage(
  rollup: ThreadUsageRollup | undefined,
  turn: ThreadTurnUsage,
): ThreadUsageRollup {
  const base: ThreadUsageRollup = rollup ?? {
    source: "runtime",
    turns: 0,
    inputTokens: 0,
    outputTokens: 0,
    cachedInputTokens: 0,
    cacheCreationTokens: 0,
    reasoningTokens: 0,
    subagentTurns: 0,
    costUsd: null,
    models: [],
    lastTurnAt: turn.completedAt,
  };
  return {
    source: base.source,
    turns: base.turns + 1,
    inputTokens: base.inputTokens + turn.inputTokens,
    outputTokens: base.outputTokens + turn.outputTokens,
    cachedInputTokens: base.cachedInputTokens + turn.cachedInputTokens,
    cacheCreationTokens: base.cacheCreationTokens + turn.cacheCreationTokens,
    reasoningTokens: base.reasoningTokens + (turn.reasoningTokens ?? 0),
    subagentTurns: base.subagentTurns + (turn.hasSubagents ? 1 : 0),
    costUsd: turn.costUsd === null ? base.costUsd : (base.costUsd ?? 0) + turn.costUsd,
    models:
      turn.model !== null && !base.models.includes(turn.model)
        ? [...base.models, turn.model]
        : base.models,
    lastTurnAt: turn.completedAt > base.lastTurnAt ? turn.completedAt : base.lastTurnAt,
    ...optionalSum("toolCalls", base.toolCalls, turn.toolCalls),
    ...optionalSum("durationMs", base.durationMs, turn.durationMs),
  };
}

/** A sum that stays absent until a turn carries the figure (no key, not
    `undefined`, so a rollup compares equal to its literal). */
function optionalSum<K extends string>(
  key: K,
  base: number | undefined,
  turn: number | undefined,
): { [key in K]?: number } {
  const sum = turn === undefined ? base : (base ?? 0) + turn;
  return sum === undefined ? {} : ({ [key]: sum } as { [key in K]: number });
}

/**
 * The rollup of a set of turns folded onto `base` (a transcript estimate the
 * backfill left on the thread), or undefined for none: absence, never zero.
 */
export function foldTurnUsage(
  turns: Iterable<ThreadTurnUsage>,
  base?: ThreadUsageRollup,
): ThreadUsageRollup | undefined {
  let rollup: ThreadUsageRollup | undefined = base;
  for (const turn of turns) {
    rollup = addTurnUsage(rollup, turn);
  }
  return rollup;
}
