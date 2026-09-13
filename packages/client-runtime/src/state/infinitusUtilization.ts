import {
  InfinitusUtilization,
  InfinitusUtilizationFiveHourWindow,
  InfinitusUtilizationGeneration,
  InfinitusUtilizationReplay,
  type InfinitusUtilizationSample,
  type InfinitusUtilizationTotals,
  type InfinitusUtilizationWindow,
} from "@t3tools/contracts/infinitus";
import * as Schema from "effect/Schema";

/**
 * The Utilization page's history read model (#747): the `utilization --days
 * n` reply decoded defensively and folded into the lines the retired native
 * pane charted — every account's percentage of one window over the range —
 * its run-rate table, and the window telemetry the Mac reconstructs beside
 * them (weekly waste, the five-hour windows, the range's replay). Estimates
 * the Mac read off its own history and transcripts, never billing truth.
 */

const decode = Schema.decodeUnknownOption(InfinitusUtilization);

/** The `utilization` reply as a value, or null for anything else. */
export function decodeUtilization(result: unknown): InfinitusUtilization | null {
  const decoded = decode(result);
  return decoded._tag === "Some" ? decoded.value : null;
}

/** The window names the samples carry, "5h" and "7d" first, then the scoped
    model names as native orders them (`UtilizationModel.windowNames`). */
export function utilizationWindows(u: InfinitusUtilization): ReadonlyArray<string> {
  if (u.windows !== undefined && u.windows.length > 0) return u.windows;
  const names = new Set<string>();
  for (const sample of u.samples) {
    if (sample.fiveHour) names.add("5h");
    if (sample.sevenDay) names.add("7d");
    for (const name of Object.keys(sample.scoped ?? {})) names.add(name);
  }
  return [...names].sort((a, b) =>
    a === "5h" ? -1 : b === "5h" ? 1 : a === "7d" ? -1 : b === "7d" ? 1 : a.localeCompare(b),
  );
}

function windowOf(
  sample: InfinitusUtilizationSample,
  window: string,
): InfinitusUtilizationWindow | null {
  if (window === "5h") return sample.fiveHour ?? null;
  if (window === "7d") return sample.sevenDay ?? null;
  return sample.scoped?.[window] ?? null;
}

export interface HistoryPoint {
  /** Epoch seconds. */
  readonly t: number;
  readonly pct: number;
}

export interface HistoryLine {
  readonly email: string;
  readonly number: number;
  /** The alias the fleet shows for the account, else its email. */
  readonly label: string;
  readonly points: ReadonlyArray<HistoryPoint>;
  /** The line's last percentage, what the legend shows. */
  readonly latestPct: number;
  /** Whether the account was the fleet's active one at its last sample. */
  readonly active: boolean;
}

/** One line per account for the chosen window, in the order the reply lists
    the accounts (`emails`), points oldest first. Accounts with no sample of
    that window are left out. `labels` maps an email to the alias the page
    shows; an unknown email shows as itself. */
export function historyLines(
  u: InfinitusUtilization,
  window: string,
  labels: Readonly<Record<string, string>> = {},
): ReadonlyArray<HistoryLine> {
  const byEmail = new Map<string, { number: number; points: HistoryPoint[]; active: boolean }>();
  const order = u.emails ?? [];
  for (const email of order) byEmail.set(email, { number: 0, points: [], active: false });
  for (const sample of [...u.samples].sort((a, b) => a.t - b.t)) {
    const value = windowOf(sample, window);
    if (value === null) continue;
    const line = byEmail.get(sample.email) ?? { number: sample.number, points: [], active: false };
    line.number = sample.number;
    line.points.push({ t: sample.t, pct: Math.max(0, Math.min(100, value.pct)) });
    line.active = sample.active === true;
    byEmail.set(sample.email, line);
  }
  return [...byEmail.entries()]
    .filter(([, line]) => line.points.length > 0)
    .map(([email, line]) => ({
      email,
      number: line.number,
      label: labels[email] ?? email,
      points: line.points,
      latestPct: line.points[line.points.length - 1]?.pct ?? 0,
      active: line.active,
    }));
}

/** The x-range a history chart spans: the range the Mac was asked for, ending
    at the newest sample (or now when there is none), so a short history still
    fills the axis the way the native chart did. */
export function historyRange(
  u: InfinitusUtilization,
  nowSeconds: number,
): { readonly from: number; readonly to: number } {
  const newest = u.samples.reduce((max, sample) => Math.max(max, sample.t), 0);
  const to = newest > 0 ? Math.max(newest, nowSeconds) : nowSeconds;
  return { from: to - u.days * 86_400, to };
}

/* The window telemetry beside the chart: the Mac reconstructs it off its FULL
   history (a reset may predate the asked range) and ships it with every
   `utilization` reply. Each row decodes on its own, so one the Mac words
   differently drops alone. */

const decodeGeneration = Schema.decodeUnknownOption(InfinitusUtilizationGeneration);
const decodeFiveHour = Schema.decodeUnknownOption(InfinitusUtilizationFiveHourWindow);
const decodeReplay = Schema.decodeUnknownOption(InfinitusUtilizationReplay);

function rows<A>(
  values: ReadonlyArray<unknown> | null | undefined,
  decodeRow: (value: unknown) => { readonly _tag: "None" } | { readonly _tag: "Some"; value: A },
): ReadonlyArray<A> {
  if (values === undefined || values === null) return [];
  const out: A[] = [];
  for (const value of values) {
    const decoded = decodeRow(value);
    if (decoded._tag === "Some") out.push(decoded.value);
  }
  return out;
}

export interface WasteRow {
  /** `email|window|resetAt`, unique across the reply. */
  readonly key: string;
  readonly label: string;
  readonly window: string;
  /** Epoch seconds of the rollover. */
  readonly resetAt: number;
  readonly finalPct: number;
  /** The headroom that expired with the window. */
  readonly wastePct: number;
  /** Seconds between the last observation and the reset; null when the Mac
      sent none. Hours of it mean `finalPct` undercounts the real use. */
  readonly observationGap: number | null;
}

/** A gap this long before a reset means the app was not watching for most of
    the window's tail, so its final percentage is a floor, not a reading. */
export const WASTE_GAP_SECONDS = 6 * 3600;

/** The weekly resets the Mac recorded, newest first, capped. These are the 7d
    and per-model windows only: a 5h window recycles ~34× a week, where unused
    headroom is idle time rather than lost quota. */
export function wasteRows(
  u: InfinitusUtilization,
  labels: Readonly<Record<string, string>> = {},
  limit = 6,
): ReadonlyArray<WasteRow> {
  return rows(u.generations, decodeGeneration)
    .map((generation) => ({
      key: `${generation.email}|${generation.window}|${generation.resetAt}`,
      label: labels[generation.email] ?? generation.email,
      window: generation.window,
      resetAt: generation.resetAt,
      finalPct: generation.finalPct,
      wastePct: Math.max(0, Math.min(100, 100 - generation.finalPct)),
      observationGap: generation.observationGap ?? null,
    }))
    .sort((a, b) => b.resetAt - a.resetAt)
    .slice(0, limit);
}

export interface FiveHourWindowRow {
  /** `email|resetsAt`, native's own identity: two accounts share a reset. */
  readonly key: string;
  readonly label: string;
  /** Epoch seconds; derived by the Mac as `resetsAt - 5h`. */
  readonly start: number;
  readonly resetsAt: number;
  /** The highest percentage observed inside the window — what it was used
      for, since headroom idles rather than leaking. */
  readonly peakPct: number;
  readonly samples: number;
  readonly closed: boolean;
}

export interface FiveHourSummary {
  readonly windows: ReadonlyArray<FiveHourWindowRow>;
  readonly count: number;
  readonly meanPeakPct: number;
  /** Closed windows whose peak never rose above 5 % — opened or ignited, then
      left (native's `WindowTelemetry.summary`). */
  readonly unused: number;
}

/** The five-hour windows the Mac reconstructed, kept to those that started
    inside the asked range, newest first. Null when the reply carries none —
    a build before the telemetry, or a history too short to close a window. */
export function fiveHourSummary(
  u: InfinitusUtilization,
  range: { readonly from: number; readonly to: number },
  labels: Readonly<Record<string, string>> = {},
): FiveHourSummary | null {
  const windows = rows(u.fiveHourWindows, decodeFiveHour)
    .filter((window) => window.start >= range.from)
    .map((window) => ({
      key: `${window.email}|${window.resetsAt}`,
      label: labels[window.email] ?? window.email,
      start: window.start,
      resetsAt: window.resetsAt,
      peakPct: Math.max(0, Math.min(100, window.peakPct)),
      samples: window.samples,
      closed: window.closed,
    }))
    .sort((a, b) => b.start - a.start);
  if (windows.length === 0) return null;
  return {
    windows,
    count: windows.length,
    meanPeakPct: windows.reduce((sum, window) => sum + window.peakPct, 0) / windows.length,
    unused: windows.filter((window) => window.closed && window.peakPct < 5).length,
  };
}

/** One sentence on what the fleet did over the range: how often it switched
    account, how many of those landed on an account with no window ticking
    (which a warm-up request could have started ahead of time), and how long
    the active account sat at its 5h limit. Null when the reply carries no
    replay, or when the history is older than the `active` flag, where no
    switch can be seen at all. */
export function replayText(u: InfinitusUtilization): string | null {
  const decoded = decodeReplay(u.replay);
  if (decoded._tag === "None") return null;
  const replay = decoded.value;
  if (replay.sawActiveFlag === false) return null;
  const switches = `${replay.switches} account ${replay.switches === 1 ? "switch" : "switches"}`;
  const cold = replay.coldSwitches > 0 ? `, ${replay.coldSwitches} onto a cold 5h clock` : "";
  const minutes = Math.round(replay.stalledSeconds / 60);
  const stalled =
    minutes > 0 ? `, ${minutes} min stalled at the 5h limit` : ", nothing stalled at the 5h limit";
  return `Over this range: ${switches}${cold}${stalled}.`;
}

const total = (t: InfinitusUtilizationTotals): number =>
  (t.input ?? 0) + (t.output ?? 0) + (t.cacheRead ?? 0) + (t.cacheWrite ?? 0);

export interface RunRateRow {
  readonly label: "Last hour" | "Last day" | "Last week";
  readonly tokens: number;
  readonly usd: number;
  readonly messages: number;
}

/** The run-rate table's rows, the native pane's order. Null until the Mac has
    scanned its transcripts (`rates` absent). */
export function runRateRows(u: InfinitusUtilization): ReadonlyArray<RunRateRow> | null {
  const rates = u.rates;
  if (rates === undefined || rates === null) return null;
  const periods: ReadonlyArray<{
    readonly label: RunRateRow["label"];
    readonly totals: InfinitusUtilizationTotals;
  }> = [
    { label: "Last hour", totals: rates.lastHour },
    { label: "Last day", totals: rates.lastDay },
    { label: "Last week", totals: rates.lastWeek },
  ];
  return periods.map(({ label, totals }) => ({
    label,
    tokens: total(totals),
    usd: totals.usd ?? 0,
    messages: totals.messages ?? 0,
  }));
}

/** Native's `TokenFormat.compact`: 1.2k, 3.4M, 5.6B. */
export function compactTokens(value: number): string {
  const abs = Math.abs(value);
  if (abs >= 1e9) return `${(value / 1e9).toFixed(1)}B`;
  if (abs >= 1e6) return `${(value / 1e6).toFixed(1)}M`;
  if (abs >= 1e3) return `${(value / 1e3).toFixed(1)}k`;
  return value.toFixed(0);
}

/** The live line under the table: the popup's five-minute output rate. */
export function liveRateText(u: InfinitusUtilization): string | null {
  const live = u.liveRate;
  if (live === undefined || live === null) return null;
  const peak =
    live.peakPerMinute !== undefined && live.peakPerMinute > live.perMinute
      ? `, peak ${compactTokens(live.peakPerMinute)}`
      : "";
  return `Live: ${compactTokens(live.perMinute)} output tokens/min over the last 5 minutes${peak}.`;
}

export const RUN_RATE_NOTE =
  "Read off Claude Code's own transcripts — an estimate at API list prices, not what the subscription costs.";
