import type {
  OrchestrationV2ProviderSession,
  OrchestrationV2ProviderTurn,
  OrchestrationV2Run,
  OrchestrationV2ThreadProjection,
  ThreadUsageRollup,
} from "@infinitus/contracts";
import * as DateTime from "effect/DateTime";

/**
 * Fork (#834, on orchestrator v2 #1627): one completed turn's usage, read
 * off the provider turn the orchestrator stores (`turnUsageFromProviderTurn`).
 * Never sent: the rollup is folded where it is shown, from the projection
 * every client already holds. All figures are estimates, never billing truth.
 */
export interface ThreadTurnUsage {
  readonly turnId: string;
  /** The model the turn mostly ran on, when the provider named one. */
  readonly model: string | null;
  /** Cache reads and writes included. */
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly cachedInputTokens: number;
  readonly cacheCreationTokens: number;
  /** Part of `outputTokens`; null when the provider does not break it out. */
  readonly reasoningTokens: number | null;
  /** False when the provider gave partial totals. */
  readonly complete: boolean;
  readonly hasSubagents: boolean;
  /** The provider's estimate in USD, null when it gave none. */
  readonly costUsd: number | null;
  readonly completedAt: string;
  /** Tool calls the ingestor counted on the turn's items; absent when it
      did not count, never zero for "not counted". */
  readonly toolCalls?: number;
  /** Wall time from the provider turn's start to its end; absent when
      either instant is unknown. */
  readonly durationMs?: number;
  /** Present on a turn whose provider reported no usage (Cursor and Grok
      report none; an adapter can answer `unavailable`): its tokens are zero
      for "not reported", and the record exists so the tool calls and wall
      time survive. Absent on every turn that reported. */
  readonly usageUnavailable?: true;
  /** The prompt-cache TTL the turn's writes bought (`TurnTokenUsage`);
      absent when the provider does not say. */
  readonly cacheTtlSeconds?: number;
}

const TERMINAL_STATUSES: ReadonlySet<OrchestrationV2ProviderTurn["status"]> = new Set([
  "completed",
  "interrupted",
  "failed",
]);

/**
 * The usage record of a terminal provider turn, or undefined when there is nothing
 * to record. A completed turn whose provider reported no usage is recorded as zero
 * tokens with `usageUnavailable`, so tool calls and wall time survive. Interrupted
 * or failed turns without usage, and cancelled ones, are not counted.
 */
export function turnUsageFromProviderTurn(
  turn: OrchestrationV2ProviderTurn,
  run?: Pick<OrchestrationV2Run, "modelSelection">,
): ThreadTurnUsage | undefined {
  if (!TERMINAL_STATUSES.has(turn.status) || turn.completedAt === null) return undefined;
  const tokens = turn.turnTokenUsage;
  const unavailable = tokens === undefined || tokens.usageStatus === "unavailable";
  if (unavailable && turn.status !== "completed") return undefined;
  const completedAt = isoOf(turn.completedAt);
  const startedMs = turn.startedAt === null ? Number.NaN : epochOf(turn.startedAt);
  const elapsed = epochOf(turn.completedAt) - startedMs;
  const durationMs = Number.isFinite(elapsed) && elapsed >= 0 ? Math.round(elapsed) : undefined;
  return {
    turnId: turn.id,
    model: turn.turnModels?.[0] ?? run?.modelSelection.model ?? null,
    inputTokens: tokens?.inputTokens ?? 0,
    outputTokens: tokens?.outputTokens ?? 0,
    cachedInputTokens: tokens?.cachedInputTokens ?? 0,
    cacheCreationTokens: tokens?.cacheCreationTokens ?? 0,
    reasoningTokens: tokens?.reasoningTokens ?? null,
    complete: tokens?.usageStatus === "complete",
    hasSubagents: tokens?.hasSubagents ?? false,
    costUsd: turn.turnCostUsd ?? null,
    completedAt,
    ...(turn.toolCalls !== undefined ? { toolCalls: turn.toolCalls } : {}),
    ...(durationMs !== undefined ? { durationMs } : {}),
    ...(unavailable ? { usageUnavailable: true as const } : {}),
    ...(tokens?.cacheTtlSeconds !== undefined ? { cacheTtlSeconds: tokens.cacheTtlSeconds } : {}),
  };
}

/**
 * The thread's rollup from its projection: terminal turns of its root provider
 * threads (subagents have an owner node), minus runs a rollback removed, folded
 * onto `usageBaseline`. Undefined with nothing recorded and no baseline: absence,
 * never zero.
 */
export function threadUsageFromProjection(
  projection: Pick<
    OrchestrationV2ThreadProjection,
    "runs" | "attempts" | "providerThreads" | "providerTurns"
  > & {
    readonly thread: Pick<OrchestrationV2ThreadProjection["thread"], "id" | "usageBaseline">;
  },
): ThreadUsageRollup | undefined {
  const rootProviderThreadIds = new Set(
    projection.providerThreads
      .filter(
        (thread) => thread.ownerNodeId === null && thread.appThreadId === projection.thread.id,
      )
      .map((thread) => thread.id),
  );
  const runById = new Map(projection.runs.map((run) => [run.id, run] as const));
  const runByAttemptId = new Map(
    projection.attempts.map((attempt) => [attempt.id, runById.get(attempt.runId)] as const),
  );
  const turns: ThreadTurnUsage[] = [];
  for (const turn of projection.providerTurns) {
    if (!rootProviderThreadIds.has(turn.providerThreadId)) continue;
    const run = turn.runAttemptId === null ? undefined : runByAttemptId.get(turn.runAttemptId);
    if (run?.status === "rolled_back") continue;
    const record = turnUsageFromProviderTurn(turn, run);
    if (record !== undefined) turns.push(record);
  }
  turns.sort((left, right) => left.completedAt.localeCompare(right.completedAt));
  return foldTurnUsage(turns, projection.thread.usageBaseline);
}

/**
 * A thread's usage rollup, folded one completed turn at a time. A rollup
 * keeps its `source`: a transcript estimate that runtime turns are added to
 * still reads as estimated.
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
 * The rollup of a set of turns folded onto `base` (the estimate the backfill
 * left on the thread), or undefined for none: absence, never zero.
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
 * Whether the thread's prompt cache is still warm, from `cacheExpiresAt`;
 * `expiring` is the last fifth of the TTL. `sessionAlive` is whether the provider
 * process that wrote the cache is up: once it ends, the resumed CLI's prompt
 * prefix usually differs and the cache is rewritten (pingdotgg/t3code#10955), so `cold`.
 */
export type PromptCacheState =
  | { readonly kind: "warm" | "expiring"; readonly remainingMs: number; readonly ttlMs: number }
  | { readonly kind: "cold"; readonly reason: "expired" | "restart" };

export function promptCacheState(
  usage: Pick<ThreadUsageRollup, "cacheExpiresAt" | "lastTurnAt">,
  nowMs: number,
  sessionAlive: boolean,
): PromptCacheState | null {
  if (usage.cacheExpiresAt === undefined) return null;
  const expiresAtMs = Date.parse(usage.cacheExpiresAt);
  const ttlMs = expiresAtMs - Date.parse(usage.lastTurnAt);
  if (!Number.isFinite(ttlMs) || ttlMs <= 0) return null;
  const remainingMs = expiresAtMs - nowMs;
  if (remainingMs <= 0) return { kind: "cold", reason: "expired" };
  if (!sessionAlive) return { kind: "cold", reason: "restart" };
  const expiringMs = Math.min(5 * 60_000, ttlMs / 5);
  return { kind: remainingMs <= expiringMs ? "expiring" : "warm", remainingMs, ttlMs };
}

/**
 * Whether the process that wrote the last turn's cache still runs: the provider
 * session is `ready` and unchanged since that turn (any later stop, reap, error
 * or restart moves `updatedAt` past it). A second of grace for ordering.
 */
export function promptCacheWriterAlive(
  session: Pick<OrchestrationV2ProviderSession, "status" | "updatedAt"> | null | undefined,
  lastTurnAt: string,
): boolean {
  if (session?.status !== "ready") return false;
  return epochOf(session.updatedAt) <= Date.parse(lastTurnAt) + 1000;
}

/** Whole minutes left, rounded down so the label never promises more
    than the cache has: "42m", "<1m", "1h" right after a 1-hour write. */
export function promptCacheRemainingLabel(remainingMs: number): string {
  const minutes = Math.floor(remainingMs / 60_000);
  if (minutes >= 60) return "1h";
  return minutes < 1 ? "<1m" : `${minutes}m`;
}

/** Milliseconds until the label or the kind can next change: just past the
    next whole minute before expiry (the label rounds down, so on the
    boundary itself it has not changed yet). Null once cold. */
export function promptCacheNextChangeMs(expiresAt: string, nowMs: number): number | null {
  const remainingMs = Date.parse(expiresAt) - nowMs;
  if (!Number.isFinite(remainingMs) || remainingMs <= 0) return null;
  return (remainingMs % 60_000) + 1;
}

/** The projection's instants are `DateTime.Utc` values; on the wire they
    are ISO strings. Both answer `epochMilliseconds` or parse. */
function epochOf(instant: OrchestrationV2ProviderTurn["completedAt"] | string): number {
  if (typeof instant === "string") return Date.parse(instant);
  return instant === null ? Number.NaN : instant.epochMilliseconds;
}

function isoOf(instant: NonNullable<OrchestrationV2ProviderTurn["completedAt"]>): string {
  return DateTime.formatIso(instant);
}
