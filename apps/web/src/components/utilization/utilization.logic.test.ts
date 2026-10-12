import {
  historyLines,
  historyRange,
  replayText,
  runRateRows,
  utilizationWindows,
  wasteRows,
  fiveHourSummary,
  liveRateText,
} from "@infinitus/client-runtime/state/infinitusUtilization";
import type { InfinitusSnapshot, InfinitusUtilization } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import { mergeUtilization, utilizationAliases } from "./utilization.logic";

const now = 1_800_000_000;
const totals = (n: number) => ({
  input: n,
  output: n,
  cacheRead: n,
  cacheWrite: n,
  usd: n / 100,
  messages: n / 10,
});

/** Mac A: two days of alpha's history, a scanned run rate, a closed window. */
const macA: InfinitusUtilization = {
  days: 7,
  bucketSeconds: 1800,
  samples: [
    { t: now - 2 * 86_400, email: "alpha@example.com", number: 1, fiveHour: { pct: 20 } },
    { t: now - 3600, email: "alpha@example.com", number: 1, active: true, fiveHour: { pct: 60 } },
  ],
  windows: ["5h", "7d"],
  emails: ["alpha@example.com"],
  generations: [{ email: "alpha@example.com", window: "7d", resetAt: now - 86_400, finalPct: 40 }],
  fiveHourWindows: [
    {
      email: "alpha@example.com",
      number: 1,
      start: now - 21_600,
      resetsAt: now - 3600,
      peakPct: 70,
      samples: 10,
      closed: true,
    },
  ],
  replay: { from: now - 7 * 86_400, to: now, switches: 2, coldSwitches: 1, stalledSeconds: 600 },
  rates: {
    computedAt: now - 60,
    lastHour: totals(100),
    lastDay: totals(1000),
    lastWeek: totals(10_000),
    files: 3,
    unpricedModels: ["mystery-1"],
  },
  liveRate: { perMinute: 1000, peakPerMinute: 3000 },
};

/** Mac B: six days of beta's history plus the same alpha window seen more
    often, a per-model window, no run rate yet. */
const macB: InfinitusUtilization = {
  days: 7,
  bucketSeconds: 3600,
  samples: [
    { t: now - 6 * 86_400, email: "beta@example.com", number: 2, fiveHour: { pct: 5 } },
    {
      t: now - 7200,
      email: "beta@example.com",
      number: 2,
      fiveHour: { pct: 90 },
      scoped: { Fable: { pct: 30 } },
    },
  ],
  windows: ["Fable", "5h"],
  emails: ["beta@example.com", "alpha@example.com"],
  generations: [
    { email: "alpha@example.com", window: "7d", resetAt: now - 86_400, finalPct: 55 },
    { email: "beta@example.com", window: "Fable", resetAt: now - 3 * 86_400, finalPct: 80 },
  ],
  fiveHourWindows: [
    {
      email: "alpha@example.com",
      number: 1,
      start: now - 21_600,
      resetsAt: now - 3600,
      peakPct: 72,
      samples: 25,
      closed: true,
    },
  ],
  replay: { from: now - 6 * 86_400, to: now - 60, switches: 1, coldSwitches: 0, stalledSeconds: 0 },
  rates: {
    computedAt: now - 30,
    lastHour: totals(10),
    lastDay: totals(100),
    lastWeek: totals(1000),
    files: 1,
  },
  liveRate: { perMinute: 500 },
};

describe("mergeUtilization", () => {
  it("returns one machine's reply as it came, and null for none", () => {
    expect(mergeUtilization([macA])).toBe(macA);
    expect(mergeUtilization([])).toBeNull();
  });

  it("adds the run rate and the live rate of two machines", () => {
    const merged = mergeUtilization([macA, macB])!;
    expect(runRateRows(merged)).toEqual([
      { label: "Last hour", tokens: 440, usd: 1.1, messages: 11 },
      { label: "Last day", tokens: 4400, usd: 11, messages: 110 },
      { label: "Last week", tokens: 44_000, usd: 110, messages: 1100 },
    ]);
    expect(merged.rates?.computedAt).toBe(now - 60);
    expect(merged.rates?.files).toBe(4);
    expect(merged.rates?.unpricedModels).toEqual(["mystery-1"]);
    // One machine sent no peak, so the sum carries none rather than a low one.
    expect(liveRateText(merged)).toBe("Live: 1.5k output tokens/min over the last 5 minutes.");
  });

  it("leaves a failed machine out: the other's figures stand alone", () => {
    const merged = mergeUtilization([macB])!;
    expect(merged).toBe(macB);
    expect(runRateRows(merged)?.[0]).toEqual({
      label: "Last hour",
      tokens: 40,
      usd: 0.1,
      messages: 1,
    });
  });

  it("unions the series across machines with different spans, oldest first", () => {
    const merged = mergeUtilization([macA, macB])!;
    expect(merged.days).toBe(7);
    expect(utilizationWindows(merged)).toEqual(["5h", "7d", "Fable"]);
    expect(merged.emails).toEqual(["alpha@example.com", "beta@example.com"]);

    const lines = historyLines(merged, "5h");
    expect(lines.map((line) => line.email)).toEqual(["alpha@example.com", "beta@example.com"]);
    expect(lines[1]!.points.map((point) => point.t)).toEqual([now - 6 * 86_400, now - 7200]);
    expect(lines[0]!.active).toBe(true);
    // The x-axis ends at the newest sample of either machine and spans the range.
    expect(historyRange(merged, now - 86_400)).toEqual({
      from: now - 3600 - 7 * 86_400,
      to: now - 3600,
    });
    expect(historyLines(merged, "Fable").map((line) => line.latestPct)).toEqual([30]);
  });

  it("counts a window both machines watched once, keeping the better observation", () => {
    const merged = mergeUtilization([macA, macB])!;
    const waste = wasteRows(merged);
    expect(waste.map((row) => [row.label, row.finalPct])).toEqual([
      ["alpha@example.com", 55],
      ["beta@example.com", 80],
    ]);
    const windows = fiveHourSummary(merged, { from: now - 7 * 86_400, to: now })!;
    expect(windows.count).toBe(1);
    expect(windows.windows[0]!.samples).toBe(25);
    expect(replayText(merged)).toBe(
      "Over this range: 3 account switches, 1 onto a cold 5h clock, 10 min stalled at the 5h limit.",
    );
  });

  it("leaves the run rate out only when no machine has scanned", () => {
    const { rates: _a, liveRate: _l, ...bareA } = macA;
    const { rates: _b, liveRate: _m, ...bareB } = macB;
    const merged = mergeUtilization([bareA, bareB])!;
    expect(runRateRows(merged)).toBeNull();
    expect(liveRateText(merged)).toBeNull();
    expect(mergeUtilization([bareA, macB])!.rates?.lastHour.usd).toBe(0.1);
  });
});

describe("utilizationAliases", () => {
  it("collects every machine's aliases, the first seen winning", () => {
    const fleet = (alias: string | undefined, email: string) => ({
      key: "swapd/claude",
      engineID: "swapd",
      provider: "claude",
      capabilities: [],
      accounts: [
        {
          number: 1,
          email,
          ...(alias === undefined ? {} : { alias }),
          active: true,
          isOrganization: false,
          usageStatus: "ok",
        },
      ],
    });
    const snapshot = (alias: string | undefined, email: string): InfinitusSnapshot => ({
      available: true,
      fleets: [fleet(alias, email)],
      commands: [],
    });
    expect(
      utilizationAliases([
        snapshot("work", "alpha@example.com"),
        null,
        snapshot("other", "alpha@example.com"),
        snapshot(undefined, "beta@example.com"),
      ]),
    ).toEqual({ "alpha@example.com": "work" });
  });
});
