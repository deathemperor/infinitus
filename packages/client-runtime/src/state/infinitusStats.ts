import * as Schema from "effect/Schema";

/**
 * The Stats page's read model (#659): the `stats --period p` reply — native's
 * `Stats.Summary.compacted()` — decoded defensively and folded into the tile
 * groups, session-length rows and effort tables the pop-out's Stats pane drew
 * (`Sources/InfinitusCore/StatsPresentation.swift`, ported here so web and
 * mobile show the same numbers). Every figure is an estimate the Mac derived
 * from transcripts and repos, never billing truth.
 */

export const STATS_PERIODS = ["day", "week", "month", "year"] as const;
export type StatsPeriod = (typeof STATS_PERIODS)[number];

/** `Stats.ActivityTally` travels under compact keys. */
const ActivityTallyPayload = Schema.Struct({
  n: Schema.optionalKey(Schema.Finite),
  s: Schema.optionalKey(Schema.Finite),
  in: Schema.optionalKey(Schema.Finite),
  out: Schema.optionalKey(Schema.Finite),
  usd: Schema.optionalKey(Schema.Finite),
  cr: Schema.optionalKey(Schema.Finite),
  cw: Schema.optionalKey(Schema.Finite),
  sv: Schema.optionalKey(Schema.Finite),
});
type ActivityTallyPayload = typeof ActivityTallyPayload.Type;

const Tallies = Schema.optionalKey(Schema.Record(Schema.String, ActivityTallyPayload));
const Count = Schema.optionalKey(Schema.Finite);

/** One `Stats.Day` in its travelling form. Every key is optional: the struct
    is wide and grows, and a missing figure reads as zero, never as a throw. */
const DayPayload = Schema.Struct({
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

const SummaryPayload = Schema.Struct({
  period: Schema.Literals(STATS_PERIODS),
  from: Schema.String,
  to: Schema.String,
  total: DayPayload,
  previous: DayPayload,
  daily: Schema.Array(Schema.Struct({ key: Schema.String, day: DayPayload })),
  streak: Schema.optionalKey(Schema.Finite),
});
export type StatsSummary = typeof SummaryPayload.Type;

const decodeSummary = Schema.decodeUnknownOption(SummaryPayload);

/** The `stats` reply as a summary, or null for anything else. */
export function decodeStatsSummary(result: unknown): StatsSummary | null {
  const decoded = decodeSummary(result);
  return decoded._tag === "Some" ? decoded.value : null;
}

// MARK: derived figures (Stats.Day's computed vars)

const n = (value: number | undefined): number => value ?? 0;
const messages = (d: StatsDay) => n(d.humanMessages) + n(d.phoneMessages);
const totalToolCalls = (d: StatsDay) =>
  Object.values(d.toolCalls ?? {}).reduce((sum, count) => sum + count, 0);
const sessionCount = (d: StatsDay) =>
  d.sessions !== undefined && d.sessions.length > 0 ? d.sessions.length : n(d.sessionTally);
const repoCount = (d: StatsDay) =>
  d.repos !== undefined && d.repos.length > 0 ? d.repos.length : n(d.repoTally);
const ratio = (a: number, b: number): number | null => (b > 0 ? a / b : null);
const messagesPerCommit = (d: StatsDay) => ratio(messages(d), n(d.commits));
const toolCallsPerHumanMessage = (d: StatsDay) => ratio(totalToolCalls(d), messages(d));
const humanShare = (d: StatsDay) =>
  ratio(messages(d), messages(d) + n(d.agentMessages) + n(d.nudges));
/** What the engine actually handled: input + cache reads + cache writes + output. */
const processedTokens = (d: StatsDay) =>
  n(d.inputTokens) + n(d.cacheReadTokens) + n(d.cacheWriteTokens) + n(d.outputTokens);
/** `inputTokens` plus cache writes — a cache write is a fresh, uncached read. */
const uncachedInputTokens = (d: StatsDay) => n(d.inputTokens) + n(d.cacheWriteTokens);

// MARK: tiles

export interface StatsTile {
  readonly id: string;
  readonly value: string;
  /** "+12%", "−3%", "±0%", "new", or null when there is nothing to compare. */
  readonly delta: string | null;
  /** One point per day of the period, weekly buckets past two months. */
  readonly series: ReadonlyArray<number>;
}

export interface StatsTileGroup {
  readonly id: string;
  readonly tiles: ReadonlyArray<StatsTile>;
}

/** "+12%" against the previous period; "new" when the previous period had
    nothing and this one does; null when both are zero. */
export function deltaText(value: number, previous: number): string | null {
  if (previous === 0) return value === 0 ? null : "new";
  const pct = Math.round(((value - previous) / previous) * 100);
  return pct === 0 ? "±0%" : pct > 0 ? `+${pct}%` : `−${-pct}%`;
}

/** A year is 365 marks per tile; past ~two months the series collapses to
    weekly buckets — sums for counts, means for money and ratios. */
export function bucketed(series: ReadonlyArray<number>, mean: boolean): ReadonlyArray<number> {
  if (series.length <= 62) return series;
  const out: number[] = [];
  for (let i = 0; i < series.length; i += 7) {
    const week = series.slice(i, i + 7);
    const sum = week.reduce((total, value) => total + value, 0);
    out.push(mean ? sum / week.length : sum);
  }
  return out;
}

const formatInt = (value: number) => Math.round(value).toLocaleString("en-US");
const formatMoney = (usd: number) => `$${usd >= 100 ? usd.toFixed(0) : usd.toFixed(2)}`;
const formatMinutes = (seconds: number) => {
  const minutes = Math.floor(seconds / 60);
  return minutes >= 120 ? `${Math.floor(minutes / 60)} h ${minutes % 60} m` : `${minutes} min`;
};

type DayNumber = (d: StatsDay) => number;
type DayRatio = (d: StatsDay) => number | null;

function tile(
  s: StatsSummary,
  id: string,
  read: DayNumber,
  options: { unit?: string; mean?: boolean; format?: (value: number) => string } = {},
): StatsTile {
  const value = read(s.total);
  const previous = read(s.previous);
  const format = options.format ?? formatInt;
  return {
    id,
    value: format(value) + (options.unit === undefined ? "" : ` ${options.unit}`),
    delta: deltaText(value, previous),
    series: bucketed(
      s.daily.map((point) => read(point.day)),
      options.mean ?? false,
    ),
  };
}

function ratioTile(s: StatsSummary, id: string, read: DayRatio): StatsTile {
  const value = read(s.total);
  const previous = read(s.previous);
  return {
    id,
    value: value === null ? "—" : value.toFixed(1),
    delta: value === null || previous === null ? null : deltaText(value, previous),
    series: bucketed(
      s.daily.map((point) => read(point.day) ?? 0),
      true,
    ),
  };
}

function percentTile(s: StatsSummary, id: string, read: DayRatio): StatsTile {
  const value = read(s.total);
  return {
    id,
    value: value === null ? "—" : `${Math.floor(value * 100)}%`,
    delta: null,
    series: bucketed(
      s.daily.map((point) => (read(point.day) ?? 0) * 100),
      true,
    ),
  };
}

const money = (s: StatsSummary, id: string, read: DayNumber) =>
  tile(s, id, read, { mean: true, format: formatMoney });
const minutes = (s: StatsSummary, id: string, read: DayNumber) =>
  tile(s, id, read, { format: formatMinutes });

/** The pop-out's tile catalogue, in its order. */
export function statsTileGroups(s: StatsSummary): ReadonlyArray<StatsTileGroup> {
  return [
    {
      id: "Throughput",
      tiles: [
        tile(s, "Commits", (d) => n(d.commits)),
        tile(s, "Lines +", (d) => n(d.linesAdded)),
        tile(s, "Lines −", (d) => n(d.linesRemoved)),
        tile(s, "PRs opened", (d) => n(d.prsOpened)),
        tile(s, "PRs merged", (d) => n(d.prsMerged)),
        tile(s, "Turns", (d) => n(d.turns)),
        tile(s, "Tool calls", totalToolCalls),
        tile(s, "Output tokens", (d) => n(d.outputTokens)),
        tile(s, "Peak tokens/min", (d) => n(d.peakTokensPerMinute)),
        tile(s, "Files touched", (d) => n(d.filesTouched)),
        tile(s, "Co-authored by Claude", (d) => n(d.coAuthoredByClaude)),
        tile(s, "Reverts", (d) => n(d.reverts)),
        tile(s, "Repos", repoCount),
      ],
    },
    {
      id: "Messages & sessions",
      tiles: [
        tile(s, "Keyboard", (d) => n(d.humanMessages)),
        tile(s, "Phone", (d) => n(d.phoneMessages)),
        tile(s, "Agents", (d) => n(d.agentMessages)),
        tile(s, "Nudges", (d) => n(d.nudges)),
        tile(s, "Sessions", sessionCount),
        tile(s, "Sub-agents", (d) => n(d.subagents)),
      ],
    },
    {
      id: "Autonomy",
      tiles: [
        ratioTile(s, "Messages / commit", messagesPerCommit),
        ratioTile(s, "Tool calls / message", toolCallsPerHumanMessage),
        tile(s, "Longest unattended", (d) => n(d.longestUnattended), { unit: "tool calls" }),
        percentTile(s, "Human share", humanShare),
      ],
    },
    {
      id: "Friction",
      tiles: [
        minutes(s, "Waiting on you", (d) => n(d.waitingSeconds)),
        tile(s, "Questions", (d) => n(d.questions)),
        tile(s, "Denied tools", (d) => n(d.denials)),
        tile(s, "Tool errors", (d) => n(d.toolErrors)),
        tile(s, "API retries", (d) => n(d.retries)),
        tile(s, "Compactions", (d) => n(d.compactions)),
      ],
    },
    {
      id: "Limits",
      tiles: [
        tile(s, "Switches", (d) => n(d.switches)),
        tile(s, "Accounts hit a limit", (d) => n(d.limitStops)),
        tile(s, "Revivals", (d) => n(d.revivals)),
        tile(s, "Minutes lost, all out", (d) => n(d.minutesLostToLimits)),
        tile(s, "Ignites", (d) => n(d.ignites)),
        tile(s, "Resumes", (d) => n(d.resumes)),
      ],
    },
    {
      id: "Cost (API-equivalent estimate)",
      tiles: [
        money(s, "Spend", (d) => n(d.usd)),
        tile(s, "Input tokens", (d) => n(d.inputTokens)),
        tile(s, "Processed tokens", processedTokens),
        tile(s, "Cached input", (d) => n(d.cacheReadTokens)),
        tile(s, "Uncached input", uncachedInputTokens),
        tile(s, "Cache writes", (d) => n(d.cacheWriteTokens)),
        money(s, "Cache savings", (d) => n(d.cacheSavingsUSD)),
      ],
    },
  ];
}

// MARK: rhythm

/** The four session-length buckets: < 15 min, 15–60 min, 1–4 h, > 4 h. */
export function sessionLengthRows(
  s: StatsSummary,
): ReadonlyArray<{ readonly label: string; readonly count: number }> {
  const labels = ["< 15 min", "15–60 min", "1–4 h", "> 4 h"];
  const buckets = s.total.sessionBuckets ?? [];
  return labels.map((label, index) => ({ label, count: buckets[index] ?? 0 }));
}

export function sessionTimeLine(s: StatsSummary): string {
  const total = n(s.total.sessionSeconds);
  const count = Math.max(1, sessionCount(s.total));
  return `${Math.floor(total / 3600)} h total · ${Math.floor(total / count / 60)} min per session`;
}

// MARK: where the effort went

/** One table row: an activity, a model, an engine or an effort level. `share`
    is the row's $ share of its table (0…1), or its token share when nothing
    in the table has a price. */
export interface EffortRow {
  readonly id: string;
  readonly count: number;
  readonly minutes: number;
  readonly tokens: number;
  readonly usd: number;
  readonly share: number;
  /** Cache reads' share of the row's input; null when the table does not
      track caching at all (per-activity tallies) rather than tracking zero. */
  readonly cachedShare: number | null;
}

const ACTIVITY_TITLES: ReadonlyArray<readonly [string, string]> = [
  ["review", "Code & PR review"],
  ["tests", "Writing tests"],
  ["plan", "Plan & design"],
  ["debug", "Debugging"],
  ["browser", "Browser & computer use"],
  ["simulator", "Simulator & device"],
  ["explanation", "Explanations"],
  ["code", "Coding"],
  ["other", "Other"],
];

const ENGINE_TITLES: Readonly<Record<string, string>> = {
  claude: "Claude Code",
  codex: "Codex CLI",
};

export const ACTIVITY_FOOTNOTE =
  "Heuristic: each stretch between two of your messages is labeled by its strongest signal. A stretch counts on the day it started; sub-agent spend shows under models, engines and effort only. Models without a price count tokens at $0.";

function row(id: string, tally: ActivityTallyPayload, share: number): EffortRow {
  const cache = n(tally.cr) + n(tally.cw);
  const inputTotal = n(tally.in) + cache;
  return {
    id,
    count: n(tally.n),
    minutes: Math.floor(n(tally.s) / 60),
    tokens: n(tally.in) + n(tally.out),
    usd: n(tally.usd),
    share,
    cachedShare: cache > 0 ? n(tally.cr) / inputTotal : null,
  };
}

function shares(table: Readonly<Record<string, ActivityTallyPayload>>) {
  const usdTotal = Object.values(table).reduce((sum, t) => sum + n(t.usd), 0);
  const tokenTotal = Object.values(table).reduce((sum, t) => sum + n(t.in) + n(t.out), 0);
  return (t: ActivityTallyPayload): number => {
    if (usdTotal > 0) return n(t.usd) / usdTotal;
    if (tokenTotal > 0) return (n(t.in) + n(t.out)) / tokenTotal;
    return 0;
  };
}

/** By $ descending, ties by key; an "other" fold sits last. */
function keyedRows(
  table: Readonly<Record<string, ActivityTallyPayload>>,
  title: (key: string, tally: ActivityTallyPayload) => string,
): ReadonlyArray<EffortRow> {
  const share = shares(table);
  return Object.entries(table)
    .sort(([keyA, a], [keyB, b]) => {
      if (keyA === "other") return 1;
      if (keyB === "other") return -1;
      return n(b.usd) - n(a.usd) || keyA.localeCompare(keyB);
    })
    .map(([key, tally]) => row(title(key, tally), tally, share(tally)));
}

/** Catalogue order; activities with no stretches are left out. */
export function activityRows(s: StatsSummary): ReadonlyArray<EffortRow> {
  const table = s.total.activities ?? {};
  const share = shares(table);
  return ACTIVITY_TITLES.flatMap(([key, title]) => {
    const tally = table[key];
    if (tally === undefined || (n(tally.n) === 0 && n(tally.usd) === 0)) return [];
    return [row(title, tally, share(tally))];
  });
}

/** `claude-opus-4-5-20250805` → "Opus 4.5"; `claude-fable-5[1m]` → "Fable 5".
    Anything that is not a Claude id is shown as-is. */
export function modelTitle(id: string): string {
  if (id === "other") return "Other models";
  if (!id.startsWith("claude-")) return id;
  const bare = id.split("[")[0] ?? id;
  const parts = bare.slice("claude-".length).split("-");
  const family = parts[0];
  if (family === undefined || family === "") return id;
  const version: string[] = [];
  for (const part of parts.slice(1)) {
    if (part.length > 2 || !/^\d+$/.test(part)) break;
    version.push(part);
  }
  return (
    family.charAt(0).toUpperCase() +
    family.slice(1) +
    (version.length === 0 ? "" : ` ${version.join(".")}`)
  );
}

/** By $ descending, aliases of one model merged by title, the compacted
    "other" fold last. */
export function modelRows(s: StatsSummary): ReadonlyArray<EffortRow> {
  const titled: Record<string, ActivityTallyPayload> = {};
  for (const [key, t] of Object.entries(s.total.byModel ?? {})) {
    const mapKey = key === "other" ? "other" : modelTitle(key);
    const current = titled[mapKey] ?? {};
    titled[mapKey] = {
      n: n(current.n) + n(t.n),
      s: n(current.s) + n(t.s),
      in: n(current.in) + n(t.in),
      out: n(current.out) + n(t.out),
      usd: n(current.usd) + n(t.usd),
      cr: n(current.cr) + n(t.cr),
      cw: n(current.cw) + n(t.cw),
      sv: n(current.sv) + n(t.sv),
    };
  }
  return keyedRows(titled, (key) => (key === "other" ? "Other models" : key));
}

/** An engine whose models carry no price is marked unpriced: its tokens are
    real, its $0 is not a saving. */
export function engineRows(s: StatsSummary): ReadonlyArray<EffortRow> {
  return keyedRows(s.total.byEngine ?? {}, (key, tally) => {
    const title = ENGINE_TITLES[key] ?? key;
    return n(tally.usd) === 0 && n(tally.in) + n(tally.out) > 0 ? `${title} · unpriced` : title;
  });
}

export function effortRows(s: StatsSummary): ReadonlyArray<EffortRow> {
  return keyedRows(s.total.byEffort ?? {}, (key) =>
    key === "unset" ? "Unset" : key.charAt(0).toUpperCase() + key.slice(1),
  );
}

/** "$1.23" / "$120"; "12k" / "1.2M" tokens; "2 h 5 m" — the table's cells. */
export const effortText = {
  usd: formatMoney,
  tokens: (tokens: number): string => {
    if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}M`;
    if (tokens >= 10_000) return `${Math.round(tokens / 1_000)}k`;
    return formatInt(tokens);
  },
  minutes: (minutes: number): string =>
    minutes >= 120 ? `${Math.floor(minutes / 60)} h ${minutes % 60} m` : `${minutes} min`,
  cached: (share: number | null): string => (share === null ? "—" : `${Math.round(share * 100)}%`),
  share: (share: number): string => `${Math.round(share * 100)}%`,
};
