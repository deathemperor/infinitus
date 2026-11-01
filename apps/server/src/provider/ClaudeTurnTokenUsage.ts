import type { SDKResultMessage } from "@anthropic-ai/claude-agent-sdk";
import type { RuntimeTurnState, TurnTokenUsage } from "@infinitus/contracts";

function finiteNonNegativeInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.round(value)
    : undefined;
}

/**
 * Fork (#1557): the prompt-cache TTL a Claude turn's writes bought, from the result's
 * `usage.cache_creation` split (`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`); one
 * account writes both, so never assume a constant. 1 hour wins a mixed turn; undefined when nothing
 * was written.
 */
export function claudeCacheTtlSeconds(value: unknown): number | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const creation = value as Record<string, unknown>;
  if ((finiteNonNegativeInteger(creation.ephemeral_1h_input_tokens) ?? 0) > 0) return 3600;
  if ((finiteNonNegativeInteger(creation.ephemeral_5m_input_tokens) ?? 0) > 0) return 300;
  return undefined;
}

const BILLED_USAGE_FIELDS = [
  "input_tokens",
  "cache_read_input_tokens",
  "cache_creation_input_tokens",
  "output_tokens",
] as const;

function addKnownCount(finalCount: unknown, earlierCounts: ReadonlyArray<unknown>): unknown {
  const counts = [finalCount, ...earlierCounts]
    .map(finiteNonNegativeInteger)
    .filter((count) => count !== undefined);
  return counts.length === 0 ? finalCount : counts.reduce((sum, count) => sum + count, 0);
}

// Steering aborts the current segment; each SDK result reports only that segment's usage.
function withEarlierSegmentUsage(
  usage: Record<string, unknown>,
  earlierSegmentUsage: ReadonlyArray<unknown>,
): Record<string, unknown> {
  if (earlierSegmentUsage.length === 0) return usage;
  const segments = earlierSegmentUsage.map((segment) => (segment ?? {}) as Record<string, unknown>);
  const total = { ...usage };
  for (const field of BILLED_USAGE_FIELDS) {
    total[field] = addKnownCount(
      usage[field],
      segments.map((segment) => segment[field]),
    );
  }
  const outputDetails = usage.output_tokens_details as Record<string, unknown> | undefined;
  total.output_tokens_details = {
    ...outputDetails,
    thinking_tokens: addKnownCount(
      outputDetails?.thinking_tokens,
      segments.map(
        (segment) =>
          (segment.output_tokens_details as Record<string, unknown> | undefined)?.thinking_tokens,
      ),
    ),
  };
  return total;
}

export function normalizeClaudeTurnTokenUsage(
  result: { readonly subtype: SDKResultMessage["subtype"]; readonly usage?: unknown } | undefined,
  hasSubagents: boolean,
  terminalStatus: RuntimeTurnState,
  earlierSegmentUsage: ReadonlyArray<unknown> = [],
): TurnTokenUsage {
  const finalUsage = result?.usage as Record<string, unknown> | undefined;
  const usage = withEarlierSegmentUsage(finalUsage ?? {}, earlierSegmentUsage);
  const uncachedInputTokens = finiteNonNegativeInteger(usage.input_tokens);
  const cachedInputTokens = finiteNonNegativeInteger(usage.cache_read_input_tokens);
  const cacheCreationTokens = finiteNonNegativeInteger(usage.cache_creation_input_tokens);
  const rawOutputTokens = finiteNonNegativeInteger(usage.output_tokens);
  const outputDetails = usage.output_tokens_details as Record<string, unknown> | undefined;
  const thinkingTokens = finiteNonNegativeInteger(outputDetails?.thinking_tokens);
  const cachedInputContribution = usage.cache_read_input_tokens == null ? 0 : cachedInputTokens;
  const cacheCreationContribution =
    usage.cache_creation_input_tokens == null ? 0 : cacheCreationTokens;
  const inputTokens =
    uncachedInputTokens !== undefined &&
    cachedInputContribution !== undefined &&
    cacheCreationContribution !== undefined
      ? uncachedInputTokens + cachedInputContribution + cacheCreationContribution
      : undefined;
  const hasKnownUsage =
    uncachedInputTokens !== undefined ||
    cachedInputTokens !== undefined ||
    cacheCreationTokens !== undefined ||
    rawOutputTokens !== undefined;
  const hasPositiveUsage =
    (uncachedInputTokens ?? 0) +
      (cachedInputTokens ?? 0) +
      (cacheCreationTokens ?? 0) +
      (rawOutputTokens ?? 0) >
    0;

  if (!hasKnownUsage || (result?.subtype !== "success" && !hasPositiveUsage)) {
    return {
      usageStatus: "unavailable",
      usageScope: "main_agent",
      hasSubagents,
    };
  }

  const cacheTtlSeconds = claudeCacheTtlSeconds(usage.cache_creation);
  const commonUsage = {
    usageScope: "main_agent",
    ...(cachedInputTokens !== undefined ? { cachedInputTokens } : {}),
    ...(cacheCreationTokens !== undefined ? { cacheCreationTokens } : {}),
    ...(cacheTtlSeconds !== undefined ? { cacheTtlSeconds } : {}),
    ...(thinkingTokens !== undefined && rawOutputTokens !== undefined
      ? { reasoningTokens: Math.min(rawOutputTokens, thinkingTokens) }
      : {}),
    hasSubagents,
  } as const;
  if (
    terminalStatus === "completed" &&
    result?.subtype === "success" &&
    finiteNonNegativeInteger(finalUsage?.input_tokens) !== undefined &&
    finiteNonNegativeInteger(finalUsage?.output_tokens) !== undefined &&
    inputTokens !== undefined &&
    rawOutputTokens !== undefined &&
    BILLED_USAGE_FIELDS.every(
      (field) =>
        finalUsage?.[field] == null || finiteNonNegativeInteger(finalUsage[field]) !== undefined,
    )
  ) {
    return {
      ...commonUsage,
      usageStatus: "complete",
      inputTokens,
      outputTokens: rawOutputTokens,
    };
  }
  return {
    ...commonUsage,
    usageStatus: "partial",
    ...(inputTokens !== undefined ? { inputTokens } : {}),
    ...(rawOutputTokens !== undefined ? { outputTokens: rawOutputTokens } : {}),
  };
}
