import * as Schema from "effect/Schema";

import { IsoDateTime, NonNegativeInt, TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Fork (#834, on orchestrator v2 #1627): a thread's completed turns summed.
 * The per-turn figures live on the provider turns the orchestrator already
 * stores (`OrchestrationV2ProviderTurn.turnTokenUsage`, plus the fork's
 * `turnCostUsd`, `turnModels` and `toolCalls`); clients fold them with
 * `@infinitus/shared/threadUsage`. The only rollup that crosses the wire is a
 * thread's `usageBaseline`: an estimate for turns that ran before this server
 * recorded usage (the v1 rollup an import carried, or the Claude transcript's
 * total), which the fold adds the recorded turns to. `runtime` rollups come
 * from the turns this server ran; `transcript` ones were estimated after the
 * fact. Estimates, never billing truth — show them as such.
 */
export const ThreadUsageSource = Schema.Literals(["runtime", "transcript"]);
export type ThreadUsageSource = typeof ThreadUsageSource.Type;

export const ThreadUsageRollup = Schema.Struct({
  source: ThreadUsageSource,
  turns: NonNegativeInt,
  /** Cache reads and writes included. */
  inputTokens: NonNegativeInt,
  outputTokens: NonNegativeInt,
  cachedInputTokens: NonNegativeInt,
  cacheCreationTokens: NonNegativeInt,
  reasoningTokens: NonNegativeInt,
  /** Turns whose tokens understate because subagents ran. */
  subagentTurns: NonNegativeInt,
  /** The sum of the turns that carried an estimate; null when none did. */
  costUsd: Schema.NullOr(Schema.Number),
  /** Distinct, first seen first. */
  models: Schema.Array(TrimmedNonEmptyString),
  lastTurnAt: IsoDateTime,
  /** Summed over the turns that carried one; absent while none did. */
  toolCalls: Schema.optional(NonNegativeInt),
  durationMs: Schema.optional(NonNegativeInt),
  /** Turns whose provider reported no usage; absent while none did. Tokens
      and cost mean something only while `turns` exceeds it
      (`threadUsageReported`). */
  unreportedTurns: Schema.optional(NonNegativeInt),
  /** When the last turn's prompt cache goes cold: its completion plus its
      `cacheTtlSeconds`. Absent when the last turn carried no TTL. */
  cacheExpiresAt: Schema.optional(IsoDateTime),
});
export type ThreadUsageRollup = typeof ThreadUsageRollup.Type;
