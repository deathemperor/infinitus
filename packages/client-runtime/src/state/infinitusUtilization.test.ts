import { describe, expect, it } from "vite-plus/test";

import {
  compactTokens,
  decodeUtilization,
  historyLines,
  historyRange,
  liveRateText,
  runRateRows,
  utilizationWindows,
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
  generations: [{ email: "ada@example.com", window: "7d", resetAt: t0, finalPct: 80 }],
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
  liveRate: { perMinute: 1500, peakPerMinute: 4200 },
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
    expect(liveRateText(decodeUtilization(reply)!)).toBe(
      "Live: 1.5k output tokens/min over the last 5 minutes, peak 4.2k.",
    );
    expect(liveRateText({ days: 1, samples: [], liveRate: { perMinute: 0 } })).toBe(
      "Live: 0 output tokens/min over the last 5 minutes.",
    );
    expect(liveRateText({ days: 1, samples: [] })).toBeNull();
  });
});
