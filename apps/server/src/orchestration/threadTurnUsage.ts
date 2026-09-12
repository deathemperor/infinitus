import type { ThreadId, ThreadTurnUsage, TurnCompletedPayload, TurnId } from "@t3tools/contracts";

/** What the ingestion counted while the turn ran (`TurnTelemetryTracker`). */
export interface TurnTelemetry {
  readonly toolCalls: number;
  readonly durationMs: number;
}

/**
 * Fork (#834): the usage record of a completed turn, from the runtime's
 * normalized `tokenUsage` (any provider) plus the Claude adapter's per-turn
 * cost and models, and the tool calls and wall time the ingestion counted
 * when it saw the turn start. A turn whose provider reported no usage
 * (Cursor and Grok send no `tokenUsage`; an adapter can answer
 * `unavailable`) is still recorded when the ingestion counted something:
 * zero tokens, `usageUnavailable: true`, so the tool calls and wall time
 * survive and the rollup knows those zeros are "not reported". Undefined
 * only when there is neither: a turn with nothing to record is not
 * recorded, so the rollup never counts zeros as figures.
 */
export function turnUsageFromCompletedTurn(
  payload: TurnCompletedPayload,
  turnId: TurnId,
  completedAt: string,
  telemetry?: TurnTelemetry,
): ThreadTurnUsage | undefined {
  const tokens = payload.tokenUsage;
  const unavailable = tokens === undefined || tokens.usageStatus === "unavailable";
  if (unavailable && telemetry === undefined) return undefined;
  return {
    turnId,
    model: payload.turnModels?.[0] ?? null,
    inputTokens: tokens?.inputTokens ?? 0,
    outputTokens: tokens?.outputTokens ?? 0,
    cachedInputTokens: tokens?.cachedInputTokens ?? 0,
    cacheCreationTokens: tokens?.cacheCreationTokens ?? 0,
    reasoningTokens: tokens?.reasoningTokens ?? null,
    complete: tokens?.usageStatus === "complete",
    hasSubagents: tokens?.hasSubagents ?? false,
    costUsd: payload.turnCostUsd ?? null,
    completedAt,
    ...(telemetry !== undefined
      ? { toolCalls: telemetry.toolCalls, durationMs: telemetry.durationMs }
      : {}),
    ...(unavailable ? { usageUnavailable: true as const } : {}),
  };
}

/**
 * Tool calls and wall time per running turn, provider-agnostic: every
 * adapter announces a tool as an `item.started` / `item.completed` pair of
 * a tool lifecycle type (OpenCode sometimes the completion alone), so the
 * count is distinct item ids seen on either. A turn is tracked from the
 * first `turn.started` this server saw (a reconnect's second start keeps
 * the first clock, so the wall time spans it); a tool event for a turn
 * whose start was not seen is dropped, since a partial count would read as
 * a real one. An abort forgets the turn, a session exit the thread, and a
 * server restart everything: those turns record no figures rather than
 * guesses.
 */
export class TurnTelemetryTracker {
  readonly #turns = new Map<string, { readonly startedAt: string; readonly tools: Set<string> }>();

  started(threadId: ThreadId, turnId: TurnId, at: string): void {
    const key = turnKey(threadId, turnId);
    if (!this.#turns.has(key)) this.#turns.set(key, { startedAt: at, tools: new Set() });
  }

  /** `itemKey` is the runtime's item id, or the event id for an id-less item. */
  toolSeen(threadId: ThreadId, turnId: TurnId, itemKey: string): void {
    this.#turns.get(turnKey(threadId, turnId))?.tools.add(itemKey);
  }

  completed(threadId: ThreadId, turnId: TurnId, at: string): TurnTelemetry | undefined {
    const key = turnKey(threadId, turnId);
    const turn = this.#turns.get(key);
    if (turn === undefined) return undefined;
    this.#turns.delete(key);
    const elapsed = Date.parse(at) - Date.parse(turn.startedAt);
    return {
      toolCalls: turn.tools.size,
      durationMs: Number.isFinite(elapsed) && elapsed > 0 ? Math.round(elapsed) : 0,
    };
  }

  aborted(threadId: ThreadId, turnId: TurnId): void {
    this.#turns.delete(turnKey(threadId, turnId));
  }

  threadEnded(threadId: ThreadId): void {
    const prefix = `${threadId}\u0000`;
    for (const key of this.#turns.keys()) {
      if (key.startsWith(prefix)) this.#turns.delete(key);
    }
  }
}

function turnKey(threadId: ThreadId, turnId: TurnId): string {
  return `${threadId}\u0000${turnId}`;
}
