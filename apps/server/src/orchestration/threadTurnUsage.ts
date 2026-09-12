import type { ThreadTurnUsage, TurnCompletedPayload, TurnId } from "@t3tools/contracts";

/**
 * Fork (#834): the usage record of a completed turn, from the runtime's
 * normalized `tokenUsage` (any provider) plus the Claude adapter's per-turn
 * cost and models. Undefined when the provider reported no usage: a turn
 * with nothing to record is not recorded, so the rollup never counts zeros.
 */
export function turnUsageFromCompletedTurn(
  payload: TurnCompletedPayload,
  turnId: TurnId,
  completedAt: string,
): ThreadTurnUsage | undefined {
  const tokens = payload.tokenUsage;
  if (tokens === undefined || tokens.usageStatus === "unavailable") return undefined;
  return {
    turnId,
    model: payload.turnModels?.[0] ?? null,
    inputTokens: tokens.inputTokens ?? 0,
    outputTokens: tokens.outputTokens ?? 0,
    cachedInputTokens: tokens.cachedInputTokens ?? 0,
    cacheCreationTokens: tokens.cacheCreationTokens ?? 0,
    reasoningTokens: tokens.reasoningTokens ?? null,
    complete: tokens.usageStatus === "complete",
    hasSubagents: tokens.hasSubagents,
    costUsd: payload.turnCostUsd ?? null,
    completedAt,
  };
}
