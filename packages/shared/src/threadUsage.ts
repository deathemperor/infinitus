import type { ThreadTurnUsage, ThreadUsageRollup } from "@infinitus/contracts";
import * as DateTime from "effect/DateTime";

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
  const isLatest = turn.completedAt >= base.lastTurnAt;
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
    lastTurnAt: isLatest ? turn.completedAt : base.lastTurnAt,
    ...optionalSum("toolCalls", base.toolCalls, turn.toolCalls),
    ...optionalSum("durationMs", base.durationMs, turn.durationMs),
    ...optionalSum(
      "unreportedTurns",
      base.unreportedTurns,
      turn.usageUnavailable === true ? 1 : undefined,
    ),
    ...cacheExpiry(isLatest ? turn : undefined, base.cacheExpiresAt),
  };
}

/** The latest turn's cache expiry, or the rollup's when an older turn is
    folded in; a latest turn without a TTL clears it, since its provider
    (or a turn that wrote nothing) says nothing about the cache. */
function cacheExpiry(
  latest: ThreadTurnUsage | undefined,
  current: string | undefined,
): { cacheExpiresAt?: string } {
  if (latest === undefined) return current === undefined ? {} : { cacheExpiresAt: current };
  if (latest.cacheTtlSeconds === undefined) return {};
  const expiresAtMs = Date.parse(latest.completedAt) + latest.cacheTtlSeconds * 1000;
  return Number.isFinite(expiresAtMs)
    ? { cacheExpiresAt: DateTime.formatIso(DateTime.makeUnsafe(expiresAtMs)) }
    : {};
}

/**
 * Whether the rollup's tokens and cost mean anything: at least one recorded
 * turn reported usage, or the figures came from a transcript. A thread of
 * turns whose provider reports no usage (Cursor, Grok) keeps its turn, tool
 * call and duration counts and says "not reported" for the rest.
 */
export function threadUsageReported(rollup: ThreadUsageRollup): boolean {
  return rollup.source === "transcript" || rollup.turns > (rollup.unreportedTurns ?? 0);
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

/**
 * Whether the thread's prompt cache is still warm, from the rollup's
 * `cacheExpiresAt` (the last turn's completion plus the TTL its writes
 * bought). `expiring` covers the last fifth of the TTL, at most five
 * minutes. Null when the last turn said nothing about the cache.
 */
export type PromptCacheState =
  | { readonly kind: "warm" | "expiring"; readonly remainingMs: number; readonly ttlMs: number }
  | { readonly kind: "cold" };

export function promptCacheState(
  usage: Pick<ThreadUsageRollup, "cacheExpiresAt" | "lastTurnAt">,
  nowMs: number,
): PromptCacheState | null {
  if (usage.cacheExpiresAt === undefined) return null;
  const expiresAtMs = Date.parse(usage.cacheExpiresAt);
  const ttlMs = expiresAtMs - Date.parse(usage.lastTurnAt);
  if (!Number.isFinite(ttlMs) || ttlMs <= 0) return null;
  const remainingMs = expiresAtMs - nowMs;
  if (remainingMs <= 0) return { kind: "cold" };
  const expiringMs = Math.min(5 * 60_000, ttlMs / 5);
  return { kind: remainingMs <= expiringMs ? "expiring" : "warm", remainingMs, ttlMs };
}

/** Whole minutes left, rounded down so the label never promises more
    than the cache has: "42m", "<1m", "1h" right after a 1-hour write. */
export function promptCacheRemainingLabel(remainingMs: number): string {
  const minutes = Math.floor(remainingMs / 60_000);
  if (minutes >= 60) return "1h";
  return minutes < 1 ? "<1m" : `${minutes}m`;
}

/** "1-hour" or "5-minute", for the cache a TTL names. */
export function promptCacheTtlLabel(ttlMs: number): string {
  return ttlMs >= 60 * 60_000 ? "1-hour" : `${Math.round(ttlMs / 60_000)}-minute`;
}

/** Milliseconds until the label or the kind can next change: just past the
    next whole minute before expiry (the label rounds down, so on the
    boundary itself it has not changed yet). Null once cold. */
export function promptCacheNextChangeMs(expiresAt: string, nowMs: number): number | null {
  const remainingMs = Date.parse(expiresAt) - nowMs;
  if (!Number.isFinite(remainingMs) || remainingMs <= 0) return null;
  return (remainingMs % 60_000) + 1;
}
