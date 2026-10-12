import {
  InfinitusUtilizationFiveHourWindow,
  InfinitusUtilizationGeneration,
  InfinitusUtilizationReplay,
  type InfinitusSnapshot,
  type InfinitusUtilization,
  type InfinitusUtilizationTotals,
} from "@infinitus/contracts/infinitus";
import * as Schema from "effect/Schema";

/**
 * The Utilization page across machines (#1581): every connected environment
 * answers `utilization --days n` for the Mac it runs on, and the page adds
 * the replies up here. One reply passes through untouched, so a single
 * machine reads exactly as it did. Several merge as follows: the run rate
 * and the live rate are sums (each Mac's transcripts are its own); the
 * samples, the weekly generations and the five-hour windows are unions — a
 * percentage is of one account's quota, and an account signed in on two
 * Macs reports the same one — deduplicated on the keys the page's rows use,
 * since both Macs saw the same reset; the replay sums its counts. The
 * planner's dry run is one Mac's and is dropped.
 */

const decodeGeneration = Schema.decodeUnknownOption(InfinitusUtilizationGeneration);
const decodeFiveHour = Schema.decodeUnknownOption(InfinitusUtilizationFiveHourWindow);
const decodeReplay = Schema.decodeUnknownOption(InfinitusUtilizationReplay);

function decodedRows<A>(
  values: ReadonlyArray<unknown> | null | undefined,
  decodeRow: (value: unknown) => { readonly _tag: "None" } | { readonly _tag: "Some"; value: A },
): ReadonlyArray<A> {
  const out: A[] = [];
  for (const value of values ?? []) {
    const decoded = decodeRow(value);
    if (decoded._tag === "Some") out.push(decoded.value);
  }
  return out;
}

/** The better observation of one row wins: two Macs watching the same account
    saw the same reset, the one that looked more often read it higher. */
function dedupe<A>(
  rows: ReadonlyArray<A>,
  keyOf: (row: A) => string,
  better: (candidate: A, kept: A) => boolean,
): ReadonlyArray<A> {
  const byKey = new Map<string, A>();
  for (const row of rows) {
    const key = keyOf(row);
    const kept = byKey.get(key);
    if (kept === undefined || better(row, kept)) byKey.set(key, row);
  }
  return [...byKey.values()];
}

/** The window names in the page's order: "5h" and "7d" first, then the rest as
    first seen. */
function unionWindows(replies: ReadonlyArray<InfinitusUtilization>): ReadonlyArray<string> {
  const names = new Set<string>();
  for (const reply of replies) for (const name of reply.windows ?? []) names.add(name);
  return [...names].sort((a, b) =>
    a === "5h" ? -1 : b === "5h" ? 1 : a === "7d" ? -1 : b === "7d" ? 1 : 0,
  );
}

function sumTotals(totals: ReadonlyArray<InfinitusUtilizationTotals>): InfinitusUtilizationTotals {
  const sum = (pick: (t: InfinitusUtilizationTotals) => number | undefined) =>
    totals.reduce((acc, t) => acc + (pick(t) ?? 0), 0);
  return {
    input: sum((t) => t.input),
    output: sum((t) => t.output),
    cacheRead: sum((t) => t.cacheRead),
    cacheWrite: sum((t) => t.cacheWrite),
    usd: sum((t) => t.usd),
    messages: sum((t) => t.messages),
  };
}

function mergeRates(
  replies: ReadonlyArray<InfinitusUtilization>,
): NonNullable<InfinitusUtilization["rates"]> | null {
  const rates = replies.flatMap((reply) =>
    reply.rates === undefined || reply.rates === null ? [] : [reply.rates],
  );
  if (rates.length === 0) return null;
  const unpriced = new Set<string>();
  for (const rate of rates) for (const model of rate.unpricedModels ?? []) unpriced.add(model);
  return {
    computedAt: Math.min(...rates.map((rate) => rate.computedAt)),
    lastHour: sumTotals(rates.map((rate) => rate.lastHour)),
    lastDay: sumTotals(rates.map((rate) => rate.lastDay)),
    lastWeek: sumTotals(rates.map((rate) => rate.lastWeek)),
    files: rates.reduce((acc, rate) => acc + (rate.files ?? 0), 0),
    unpricedModels: [...unpriced],
  };
}

/** The machines' output rates added up. The peak is the sum of each Mac's own
    peak — an upper bound, since they need not have peaked together — and is
    left out when any contributor sent none. */
function mergeLiveRate(
  replies: ReadonlyArray<InfinitusUtilization>,
): NonNullable<InfinitusUtilization["liveRate"]> | null {
  const lives = replies.flatMap((reply) =>
    reply.liveRate === undefined || reply.liveRate === null ? [] : [reply.liveRate],
  );
  if (lives.length === 0) return null;
  const perMinute = lives.reduce((acc, live) => acc + live.perMinute, 0);
  return lives.every((live) => live.peakPerMinute !== undefined)
    ? { perMinute, peakPerMinute: lives.reduce((acc, live) => acc + (live.peakPerMinute ?? 0), 0) }
    : { perMinute };
}

function mergeReplay(replies: ReadonlyArray<InfinitusUtilization>): { readonly replay?: unknown } {
  const replays = decodedRows(
    replies.map((reply) => reply.replay),
    decodeReplay,
  );
  if (replays.length === 0) return {};
  return {
    replay: {
      from: Math.min(...replays.map((replay) => replay.from)),
      to: Math.max(...replays.map((replay) => replay.to)),
      switches: replays.reduce((acc, replay) => acc + replay.switches, 0),
      coldSwitches: replays.reduce((acc, replay) => acc + replay.coldSwitches, 0),
      stalledSeconds: replays.reduce((acc, replay) => acc + replay.stalledSeconds, 0),
      sawActiveFlag: replays.every((replay) => replay.sawActiveFlag !== false),
    },
  };
}

/** Every machine's reply folded into one. Null when none answered; one reply
    is returned as it came. */
export function mergeUtilization(
  replies: ReadonlyArray<InfinitusUtilization>,
): InfinitusUtilization | null {
  if (replies.length === 0) return null;
  if (replies.length === 1) return replies[0]!;
  const emails = new Set<string>();
  for (const reply of replies) for (const email of reply.emails ?? []) emails.add(email);
  const buckets = replies.flatMap((reply) =>
    reply.bucketSeconds === undefined ? [] : [reply.bucketSeconds],
  );
  return {
    days: Math.max(...replies.map((reply) => reply.days)),
    ...(buckets.length === 0 ? {} : { bucketSeconds: Math.max(...buckets) }),
    samples: replies.flatMap((reply) => reply.samples),
    windows: unionWindows(replies),
    emails: [...emails],
    generations: dedupe(
      replies.flatMap((reply) => decodedRows(reply.generations, decodeGeneration)),
      (row) => `${row.email}|${row.window}|${row.resetAt}`,
      (candidate, kept) => candidate.finalPct > kept.finalPct,
    ),
    fiveHourWindows: dedupe(
      replies.flatMap((reply) => decodedRows(reply.fiveHourWindows, decodeFiveHour)),
      (row) => `${row.email}|${row.resetsAt}`,
      (candidate, kept) => candidate.samples > kept.samples,
    ),
    ...mergeReplay(replies),
    rates: mergeRates(replies),
    liveRate: mergeLiveRate(replies),
  };
}

/** The alias a fleet shows for an account, keyed by the email the history
    carries, across every machine's snapshot; the first alias seen wins. */
export function utilizationAliases(
  snapshots: ReadonlyArray<InfinitusSnapshot | null>,
): Readonly<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const snapshot of snapshots) {
    for (const fleet of snapshot?.fleets ?? []) {
      for (const account of fleet.accounts) {
        if (account.alias !== undefined && account.alias !== "" && out[account.email] === undefined)
          out[account.email] = account.alias;
      }
    }
  }
  return out;
}
