import { describe, expect, it } from "vite-plus/test";

import {
  compactTokens,
  decodeUtilization,
  fiveHourSummary,
  formatCount,
  historyLines,
  historyRange,
  liveRateText,
  replayText,
  runRateRows,
  utilizationWindows,
  wasteRows,
} from "./infinitusUtilization.ts";

const t0 = 1_800_000_000;
const sample = (
  t: number,
  email: string,
  number: number,
  five: number | null,
  seven: number | null,
  extra: Record<string, unknown> = {},
) => ({
  t,
  email,
  number,
  ...(five === null ? {} : { fiveHour: { pct: five, resetsAt: t + 3600 } }),
  ...(seven === null ? {} : { sevenDay: { pct: seven } }),
  ...extra,
});

const reply = {
  days: 7,
  bucketSeconds: 1800,
  samples: [
    sample(t0 + 1800, "ada@example.com", 1, 40, 50, { active: true }),
    sample(t0, "ada@example.com", 1, 30, 48, { scoped: { Fable: { pct: 7 } } }),
    sample(t0 + 900, "grace@example.com", 2, null, 66),
  ],
  windows: ["5h", "7d", "Fable"],
  emails: ["grace@example.com", "ada@example.com"],
  generations: [
    { email: "ada@example.com", window: "7d", resetAt: t0, finalPct: 80 },
    {
      email: "grace@example.com",
      window: "Fable",
      resetAt: t0 - 86_400,
      finalPct: 30,
      observationGap: 9 * 3600,
    },
    { email: "ada@example.com", window: "7d", resetAt: "yesterday", finalPct: 10 },
  ],
  fiveHourWindows: [
    {
      email: "ada@example.com",
      number: 1,
      start: t0 - 18_000,
      resetsAt: t0,
      peakPct: 62,
      samples: 30,
      closed: true,
    },
    {
      email: "grace@example.com",
      number: 2,
      start: t0 - 36_000,
      resetsAt: t0 - 18_000,
      peakPct: 2,
      samples: 4,
      closed: true,
    },
    {
      email: "ada@example.com",
      number: 1,
      start: t0,
      resetsAt: t0 + 18_000,
      peakPct: 20,
      samples: 6,
      closed: false,
    },
    { email: "ada@example.com", start: t0 - 10 * 86_400, resetsAt: t0, peakPct: 9 },
  ],
  replay: {
    from: t0 - 7 * 86_400,
    to: t0,
    switches: 3,
    coldSwitches: 1,
    stalledSeconds: 900,
    sawActiveFlag: true,
  },
  rates: {
    computedAt: t0,
    lastHour: {
      input: 1000,
      output: 200,
      cacheRead: 5000,
      cacheWrite: 100,
      usd: 0.42,
      messages: 12,
    },
    lastDay: {
      input: 20_000,
      output: 4000,
      cacheRead: 90_000,
      cacheWrite: 1000,
      usd: 7.5,
      messages: 240,
    },
    lastWeek: { input: 100_000, output: 20_000, cacheRead: 400_000, usd: 31, messages: 1200 },
    files: 9,
    unpricedModels: ["mystery-1"],
  },
};

describe("decodeUtilization (#747)", () => {
  it("decodes the reply leniently and refuses anything else", () => {
    const u = decodeUtilization(reply);
    expect(u?.days).toBe(7);
    expect(u?.samples).toHaveLength(3);
    expect(u?.rates?.unpricedModels).toEqual(["mystery-1"]);
    expect(decodeUtilization({ days: 7, samples: [] })?.samples).toEqual([]);
    expect(decodeUtilization(null)).toBeNull();
    expect(decodeUtilization({ samples: "no" })).toBeNull();
  });
});

describe("historyLines", () => {
  const u = decodeUtilization(reply)!;

  it("draws one line per account in the reply's order, points oldest first, clamped", () => {
    const lines = historyLines(u, "5h", { "ada@example.com": "ada" });
    expect(lines.map((line) => line.label)).toEqual(["ada"]);
    expect(lines[0]?.points).toEqual([
      { t: t0, pct: 30 },
      { t: t0 + 1800, pct: 40 },
    ]);
    expect(lines[0]?.latestPct).toBe(40);
    expect(lines[0]?.active).toBe(true);
    const sevenDay = historyLines(u, "7d");
    expect(sevenDay.map((line) => line.label)).toEqual(["grace@example.com", "ada@example.com"]);
    expect(sevenDay[0]?.points).toEqual([{ t: t0 + 900, pct: 66 }]);
  });

  it("reads a scoped model window, and lists the windows 5h, 7d, then the models", () => {
    expect(historyLines(u, "Fable")[0]?.points).toEqual([{ t: t0, pct: 7 }]);
    expect(utilizationWindows(u)).toEqual(["5h", "7d", "Fable"]);
    expect(utilizationWindows({ ...u, windows: [] })).toEqual(["5h", "7d", "Fable"]);
    expect(historyLines(u, "nope")).toEqual([]);
  });

  it("spans the asked range up to the newest sample", () => {
    expect(historyRange(u, t0)).toEqual({ from: t0 + 1800 - 7 * 86_400, to: t0 + 1800 });
    expect(historyRange({ ...u, samples: [] }, t0)).toEqual({ from: t0 - 7 * 86_400, to: t0 });
  });
});

describe("window telemetry", () => {
  const u = decodeUtilization(reply)!;

  it("lists the weekly rollovers newest first, with the headroom that expired", () => {
    const rows = wasteRows(u, { "grace@example.com": "grace" });
    // The third generation is worded wrong (a string `resetAt`) and drops alone.
    expect(rows.map((row) => [row.label, row.window, row.wastePct, row.observationGap])).toEqual([
      ["ada@example.com", "7d", 20, null],
      ["grace", "Fable", 70, 9 * 3600],
    ]);
    expect(wasteRows({ days: 7, samples: [] })).toEqual([]);
  });

  it("summarises the five-hour windows that started inside the range", () => {
    const range = { from: t0 - 7 * 86_400, to: t0 };
    const summary = fiveHourSummary(u, range, { "ada@example.com": "ada" });
    // Newest first; the row missing `samples` and `closed` drops, and the one
    // starting ten days back is outside the range.
    expect(summary?.windows.map((window) => [window.label, window.peakPct, window.closed])).toEqual(
      [
        ["ada", 20, false],
        ["ada", 62, true],
        ["grace@example.com", 2, true],
      ],
    );
    expect(summary?.count).toBe(3);
    expect(Math.round(summary?.meanPeakPct ?? 0)).toBe(28);
    // Only the closed 2 % window counts as never used.
    expect(summary?.unused).toBe(1);
    expect(fiveHourSummary({ days: 7, samples: [] }, range)).toBeNull();
  });

  it("words the range's replay, and stays quiet without the active flag", () => {
    expect(replayText(u)).toBe(
      "Over this range: 3 account switches, 1 onto a cold 5h clock, 15 min stalled at the 5h limit.",
    );
    expect(
      replayText({
        days: 7,
        samples: [],
        replay: { from: t0, to: t0, switches: 1, coldSwitches: 0, stalledSeconds: 0 },
      }),
    ).toBe("Over this range: 1 account switch, nothing stalled at the 5h limit.");
    expect(
      replayText({ ...u, replay: { ...(u.replay as object), sawActiveFlag: false } }),
    ).toBeNull();
    expect(replayText({ days: 7, samples: [] })).toBeNull();
  });
});

describe("run rate", () => {
  it("sums every token kind per period, and is null before the scan", () => {
    const rows = runRateRows(decodeUtilization(reply)!);
    expect(rows?.map((row) => [row.label, row.tokens, row.usd, row.messages])).toEqual([
      ["Last hour", 6300, 0.42, 12],
      ["Last day", 115_000, 7.5, 240],
      ["Last week", 520_000, 31, 1200],
    ]);
    expect(runRateRows({ days: 1, samples: [] })).toBeNull();
  });

  it("formats tokens compactly and words the live rate", () => {
    expect([compactTokens(950), compactTokens(6300), compactTokens(2_400_000)]).toEqual([
      "950",
      "6.3k",
      "2.4M",
    ]);
    // A turn count is grouped, not compacted: a week of turns reads "1,620".
    expect([formatCount(12), formatCount(1620), formatCount(1_200_000)]).toEqual([
      "12",
      "1,620",
      "1,200,000",
    ]);
    // Since #1127 the rate is the server's own, handed in directly.
    expect(liveRateText({ perMinute: 1500 })).toBe(
      "Live: 1.5k output tokens/min over the last 5 minutes on this server's threads.",
    );
    expect(liveRateText({ perMinute: 0 })).toBe(
      "Live: 0 output tokens/min over the last 5 minutes on this server's threads.",
    );
    expect(liveRateText(null)).toBeNull();
  });
});
