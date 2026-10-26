import * as Schema from "effect/Schema";

import { IsoDateTime, NonNegativeInt, TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Fork (#834, on orchestrator v2 #1627): a thread's completed turns summed by
 * `@infinitus/shared/threadUsage`. The only rollup on the wire is `usageBaseline`,
 * an estimate for turns before this server recorded usage; `runtime` rollups come
 * from turns it ran, `transcript` ones are after-the-fact. Never billing truth.
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
