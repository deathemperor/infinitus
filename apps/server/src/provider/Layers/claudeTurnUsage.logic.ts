/**
 * Fork (#834): per-turn cost from the Claude SDK's cumulative totals. A
 * result's `total_cost_usd` and `modelUsage` are running totals for the
 * query() session ("read the latest result rather than summing"), so one
 * turn's share is the difference from the previous result. A total that
 * went down means the session started over (a reconnect, `/clear`, a
 * zeroed crash result), and the new total is the whole turn's. A restart
 * whose first result already exceeds the old total is not detected, and
 * that one turn is under-counted by the old total; the adapter also
 * forgets the totals when it reopens the query, which covers the common
 * case.
 */

export interface ClaudeResultTotals {
  readonly costUsd: number;
  /** Per raw model key: tokens moved (all four counts) and cost so far. */
  readonly perModel: ReadonlyMap<string, { readonly tokens: number; readonly costUsd: number }>;
}

export interface ClaudeTurnUsageDelta {
  /** What to remember for the next result. */
  readonly totals: ClaudeResultTotals | undefined;
  readonly turnCostUsd?: number;
  /** Models whose counts moved this turn, most tokens first. */
  readonly turnModels?: ReadonlyArray<string>;
}

function finiteNonNegative(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function readTotals(result: {
  readonly total_cost_usd?: unknown;
  readonly modelUsage?: unknown;
}): ClaudeResultTotals | undefined {
  const costUsd = finiteNonNegative(result.total_cost_usd);
  if (costUsd === undefined) return undefined;
  const perModel = new Map<string, { tokens: number; costUsd: number }>();
  const modelUsage = result.modelUsage;
  if (modelUsage && typeof modelUsage === "object") {
    for (const [model, value] of Object.entries(modelUsage as Record<string, unknown>)) {
      if (!value || typeof value !== "object" || model.trim().length === 0) continue;
      const usage = value as Record<string, unknown>;
      perModel.set(model, {
        tokens:
          (finiteNonNegative(usage.inputTokens) ?? 0) +
          (finiteNonNegative(usage.outputTokens) ?? 0) +
          (finiteNonNegative(usage.cacheReadInputTokens) ?? 0) +
          (finiteNonNegative(usage.cacheCreationInputTokens) ?? 0),
        costUsd: finiteNonNegative(usage.costUSD) ?? 0,
      });
    }
  }
  return { costUsd, perModel };
}

function startedOver(previous: ClaudeResultTotals, current: ClaudeResultTotals): boolean {
  if (current.costUsd < previous.costUsd) return true;
  for (const [model, before] of previous.perModel) {
    const now = current.perModel.get(model);
    if (now === undefined || now.tokens < before.tokens) return true;
  }
  return false;
}

export function claudeTurnUsageDelta(
  previous: ClaudeResultTotals | undefined,
  result: { readonly total_cost_usd?: unknown; readonly modelUsage?: unknown } | undefined,
): ClaudeTurnUsageDelta {
  const current = result === undefined ? undefined : readTotals(result);
  if (current === undefined) return { totals: previous };
  const base = previous !== undefined && !startedOver(previous, current) ? previous : undefined;
  const turnModels = [...current.perModel]
    .map(([model, usage]) => ({
      model,
      moved: usage.tokens - (base?.perModel.get(model)?.tokens ?? 0),
    }))
    .filter((entry) => entry.moved > 0)
    .sort((left, right) => right.moved - left.moved)
    .map((entry) => entry.model);
  return {
    totals: current,
    turnCostUsd: Math.max(0, current.costUsd - (base?.costUsd ?? 0)),
    ...(result?.modelUsage === undefined ? {} : { turnModels }),
  };
}

/**
 * No prompt cache (#974): a proxy or endpoint that never serves a cache
 * read makes every call re-send the whole context at full price and full
 * latency, and nothing on screen says so. Counted per session from the
 * assistant messages' `usage`: a call whose input is large and neither read
 * nor wrote the cache is a miss, a call that read or wrote it is a hit and
 * clears the run, a small call is neither. One warning per session, at
 * `PROMPT_CACHE_MISS_RUN` misses in a row. A snapshot repeating a message
 * id counts once.
 */
export const PROMPT_CACHE_MISS_RUN = 5;
const PROMPT_CACHE_MIN_INPUT_TOKENS = 10_000;

export interface PromptCacheWatch {
  readonly misses: number;
  readonly warned: boolean;
  readonly lastMessageId: string | undefined;
}

export const INITIAL_PROMPT_CACHE_WATCH: PromptCacheWatch = {
  misses: 0,
  warned: false,
  lastMessageId: undefined,
};

export interface PromptCacheVerdict {
  readonly watch: PromptCacheWatch;
  /** Set on the call that completes the run: what the warning carries. */
  readonly warn: { readonly calls: number; readonly inputTokens: number } | undefined;
}

export function promptCacheVerdict(
  watch: PromptCacheWatch,
  messageId: string | undefined,
  usage: unknown,
): PromptCacheVerdict {
  const none = { watch, warn: undefined };
  if (messageId !== undefined && messageId === watch.lastMessageId) return none;
  if (!usage || typeof usage !== "object") return none;
  const record = usage as Record<string, unknown>;
  const input = finiteNonNegative(record.input_tokens);
  const hit =
    (finiteNonNegative(record.cache_read_input_tokens) ?? 0) > 0 ||
    (finiteNonNegative(record.cache_creation_input_tokens) ?? 0) > 0;
  if (hit) return { watch: { ...watch, misses: 0, lastMessageId: messageId }, warn: undefined };
  if (input === undefined || input < PROMPT_CACHE_MIN_INPUT_TOKENS) {
    return { watch: { ...watch, lastMessageId: messageId }, warn: undefined };
  }
  const misses = watch.misses + 1;
  const warn = misses === PROMPT_CACHE_MISS_RUN && !watch.warned;
  return {
    watch: { misses, warned: watch.warned || warn, lastMessageId: messageId },
    warn: warn ? { calls: misses, inputTokens: input } : undefined,
  };
}

export function promptCacheWarningText(calls: number): string {
  return `No prompt cache: ${calls} calls in a row re-sent the whole context uncached. Each step is slower and costs full price; check the instance's proxy or endpoint.`;
}
