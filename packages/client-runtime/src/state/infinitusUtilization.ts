import {
  InfinitusUtilization,
  type InfinitusUtilizationSample,
  type InfinitusUtilizationTotals,
  type InfinitusUtilizationWindow,
} from "@t3tools/contracts/infinitus";
import * as Schema from "effect/Schema";

/**
 * The Utilization page's history read model (#747): the `utilization --days
 * n` reply decoded defensively and folded into the lines the retired native
 * pane charted — every account's percentage of one window over the range —
 * and its run-rate table. Estimates the Mac read off its own history and
 * transcripts, never billing truth.
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
