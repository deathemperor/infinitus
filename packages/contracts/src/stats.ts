import * as Schema from "effect/Schema";
import { UsageDay, UsagePricing, UsageSource } from "./usage.ts";

export const STATS_PERIODS = ["day", "week", "month", "year"] as const;
export type StatsPeriod = (typeof STATS_PERIODS)[number];

/** `Stats.ActivityTally` travels under compact keys. */
export const ActivityTallyPayload = Schema.Struct({
  n: Schema.optionalKey(Schema.Finite),
  s: Schema.optionalKey(Schema.Finite),
  in: Schema.optionalKey(Schema.Finite),
  out: Schema.optionalKey(Schema.Finite),
  usd: Schema.optionalKey(Schema.Finite),
  unpriced: Schema.optionalKey(Schema.Finite),
  cr: Schema.optionalKey(Schema.Finite),
  cw: Schema.optionalKey(Schema.Finite),
  sv: Schema.optionalKey(Schema.Finite),
});
export type ActivityTallyPayload = typeof ActivityTallyPayload.Type;

const Tallies = Schema.optionalKey(Schema.Record(Schema.String, ActivityTallyPayload));
const Count = Schema.optionalKey(Schema.Finite);

/** One `Stats.Day` in its travelling form. Every key is optional: the struct
    is wide and grows, and a missing figure reads as zero, never as a throw. */
export const DayPayload = Schema.Struct({
  unpricedRecords: Count,
  pricedRecords: Count,
  humanMessages: Count,
  phoneMessages: Count,
  agentMessages: Count,
  nudges: Count,
  turns: Count,
  toolCalls: Schema.optionalKey(Schema.Record(Schema.String, Schema.Finite)),
  toolErrors: Count,
  questions: Count,
  denials: Count,
  waitingSeconds: Count,
  subagents: Count,
  compactions: Count,
  retries: Count,
  longestUnattended: Count,
  inputTokens: Count,
  outputTokens: Count,
  usd: Count,
  cacheReadTokens: Count,
  cacheWriteTokens: Count,
  cacheSavingsUSD: Count,
  peakTokensPerMinute: Count,
  activities: Tallies,
  byModel: Tallies,
  byEngine: Tallies,
  byEffort: Tallies,
  sessions: Schema.optionalKey(Schema.Array(Schema.String)),
  sessionTally: Count,
  sessionSeconds: Count,
  sessionBuckets: Schema.optionalKey(Schema.Array(Schema.Finite)),
  commits: Count,
  linesAdded: Count,
  linesRemoved: Count,
  filesTouched: Count,
  coAuthoredByClaude: Count,
  reverts: Count,
  prsOpened: Count,
  prsMerged: Count,
  mergeHoursTotal: Count,
  mergeCount: Count,
  repos: Schema.optionalKey(Schema.Array(Schema.String)),
  repoTally: Count,
  switches: Count,
  limitStops: Count,
  revivals: Count,
  minutesLostToLimits: Count,
  ignites: Count,
  resumes: Count,
});
export type StatsDay = typeof DayPayload.Type;

export const SummaryPayload = Schema.Struct({
  period: Schema.Literals(STATS_PERIODS),
  from: Schema.String,
  to: Schema.String,
  total: DayPayload,
  previous: DayPayload,
  daily: Schema.Array(Schema.Struct({ key: Schema.String, day: DayPayload })),
  streak: Schema.optionalKey(Schema.Finite),
  streakCapped: Schema.optionalKey(Schema.Boolean),
});
export type StatsSummary = typeof SummaryPayload.Type;

export const StatsRequest = Schema.Struct({
  period: Schema.Literals(STATS_PERIODS),
  today: UsageDay,
  timeZone: Schema.String,
});
export type StatsRequest = typeof StatsRequest.Type;

/** Session identities survive moves between machines. Only counters cross the wire. */
export const StatsSession = Schema.Struct({
  id: Schema.String,
  sourceId: Schema.String,
  updatedAt: Schema.Finite,
  days: Schema.Array(Schema.Struct({ key: Schema.String, day: DayPayload })),
  /** Sparse UTC minute buckets, needed to compute a fleet peak correctly. */
  minutes: Schema.Array(Schema.Tuple([Schema.Finite, Schema.Finite])),
});
export type StatsSession = typeof StatsSession.Type;

export const StatsCommit = Schema.Struct({
  id: Schema.String,
  at: Schema.Finite,
  added: Schema.Finite,
  removed: Schema.Finite,
  files: Schema.Finite,
  coAuthored: Schema.Boolean,
  revert: Schema.Boolean,
});
export type StatsCommit = typeof StatsCommit.Type;
export const StatsPullRequest = Schema.Struct({
  id: Schema.String,
  openedAt: Schema.Finite,
  mergedAt: Schema.NullOr(Schema.Finite),
});
export type StatsPullRequest = typeof StatsPullRequest.Type;
export const StatsRepository = Schema.Struct({
  id: Schema.String,
  commits: Schema.Array(StatsCommit),
  pullRequests: Schema.Array(StatsPullRequest),
  complete: Schema.Boolean,
  pullRequestsAvailable: Schema.Boolean,
});
export type StatsRepository = typeof StatsRepository.Type;

export const STATS_CONTRACT_VERSION = 1;
export const StatsSnapshot = Schema.Struct({
  contractVersion: Schema.Finite,
  readAt: Schema.String,
  timeZone: Schema.String,
  from: Schema.String,
  to: Schema.String,
  previousFrom: Schema.String,
  historyFrom: Schema.String,
  activeDays: Schema.Array(Schema.String),
  sources: Schema.Array(UsageSource),
  sessions: Schema.Array(StatsSession),
  repositories: Schema.Array(StatsRepository),
  pricing: UsagePricing,
  /** Provider-specific or unavailable data must never masquerade as zero. */
  unavailable: Schema.Array(Schema.String),
});
export type StatsSnapshot = typeof StatsSnapshot.Type;
