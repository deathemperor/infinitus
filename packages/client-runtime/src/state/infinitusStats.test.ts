import { describe, expect, it } from "vite-plus/test";

import {
  activityRows,
  bucketed,
  decodeStatsSummary,
  deltaText,
  effortRows,
  engineRows,
  modelRows,
  modelTitle,
  sessionLengthRows,
  sessionTimeLine,
  statsTileGroups,
  type StatsSummary,
} from "./infinitusStats.ts";

const day = (overrides: Record<string, unknown> = {}) => ({ ...overrides });

const summary = (overrides: Partial<StatsSummary> = {}): StatsSummary =>
  decodeStatsSummary({
    period: "week",
    from: "2026-09-04",
    to: "2026-09-10",
    total: day({
      commits: 12,
      humanMessages: 30,
      phoneMessages: 10,
      agentMessages: 20,
      toolCalls: { Bash: 100, Read: 50 },
      waitingSeconds: 7_500,
      usd: 123.456,
      inputTokens: 1_000,
      cacheReadTokens: 8_000,
      cacheWriteTokens: 500,
      outputTokens: 2_000,
      sessionTally: 4,
      sessionSeconds: 4 * 1800,
      sessionBuckets: [1, 2, 1, 0],
      repoTally: 2,
      activities: {
        code: { n: 5, s: 600, in: 10, out: 20, usd: 3 },
        review: { n: 1, s: 60, in: 1, out: 2, usd: 1 },
        plan: { n: 0, usd: 0 },
      },
      byModel: {
        "claude-opus-4-7": { n: 2, in: 100, out: 50, usd: 2, cr: 300, cw: 100 },
        "claude-opus-4-7[1m]": { n: 1, in: 50, out: 25, usd: 1, cr: 0, cw: 0 },
        other: { n: 1, in: 5, out: 5, usd: 0.5 },
      },
      byEngine: {
        claude: { n: 3, in: 10, out: 10, usd: 3 },
        codex: { n: 1, in: 5, out: 5, usd: 0 },
      },
      byEffort: { unset: { n: 1, usd: 1 }, high: { n: 2, usd: 2 } },
    }),
    previous: day({ commits: 10, humanMessages: 0, usd: 100 }),
    daily: [
      { key: "2026-09-04", day: day({ commits: 5, usd: 50 }) },
      { key: "2026-09-05", day: day({ commits: 7, usd: 73.456 }) },
    ],
    streak: 3,
    ...overrides,
  })!;

describe("decodeStatsSummary", () => {
  it("reads a reply with missing figures as zeros and rejects junk", () => {
    const s = summary();
    expect(s.streak).toBe(3);
    expect(decodeStatsSummary(null)).toBeNull();
    expect(decodeStatsSummary({ period: "hour" })).toBeNull();
    expect(
      decodeStatsSummary({ period: "day", from: "a", to: "b", total: {}, previous: {}, daily: [] }),
    ).not.toBeNull();
  });
});

describe("deltaText / bucketed", () => {
  it("compares against the previous period the way the pane did", () => {
    expect(deltaText(12, 10)).toBe("+20%");
    expect(deltaText(8, 10)).toBe("−20%");
    expect(deltaText(10, 10)).toBe("±0%");
    expect(deltaText(3, 0)).toBe("new");
    expect(deltaText(0, 0)).toBeNull();
  });

  it("collapses a long series to weekly sums, or means", () => {
    const series = Array.from({ length: 70 }, () => 1);
    expect(bucketed(series, false)).toEqual([7, 7, 7, 7, 7, 7, 7, 7, 7, 7]);
    expect(bucketed(series, true)).toEqual([1, 1, 1, 1, 1, 1, 1, 1, 1, 1]);
    expect(bucketed([1, 2, 3], false)).toEqual([1, 2, 3]);
  });
});

describe("statsTileGroups", () => {
  const groups = statsTileGroups(summary());
  const find = (id: string) => groups.flatMap((g) => g.tiles).find((t) => t.id === id)!;

  it("keeps the pane's catalogue order", () => {
    expect(groups.map((g) => g.id)).toEqual([
      "Throughput",
      "Messages & sessions",
      "Autonomy",
      "Friction",
      "Limits",
      "Cost (API-equivalent estimate)",
    ]);
  });

  it("derives counts, ratios, percentages, minutes and money", () => {
    expect(find("Commits")).toEqual({ id: "Commits", value: "12", delta: "+20%", series: [5, 7] });
    expect(find("Tool calls").value).toBe("150");
    expect(find("Sessions").value).toBe("4");
    expect(find("Repos").value).toBe("2");
    expect(find("Messages / commit").value).toBe("3.3");
    expect(find("Tool calls / message").value).toBe("3.8");
    expect(find("Human share").value).toBe("66%");
    expect(find("Longest unattended").value).toBe("0 tool calls");
    expect(find("Waiting on you").value).toBe("2 h 5 m");
    expect(find("Spend")).toEqual({
      id: "Spend",
      value: "$123",
      delta: "+23%",
      series: [50, 73.456],
    });
    expect(find("Processed tokens").value).toBe("11,500");
    expect(find("Uncached input").value).toBe("1,500");
    expect(find("Keyboard").delta).toBe("new");
  });
});

describe("rhythm and effort tables", () => {
  const s = summary();

  it("labels the session buckets and totals session time", () => {
    expect(sessionLengthRows(s).map((r) => `${r.label}:${r.count}`)).toEqual([
      "< 15 min:1",
      "15–60 min:2",
      "1–4 h:1",
      "> 4 h:0",
    ]);
    expect(sessionTimeLine(s)).toBe("2 h total · 30 min per session");
  });

  it("lists activities in catalogue order, dropping empty ones, with $ shares", () => {
    expect(activityRows(s).map((r) => [r.id, r.count, r.minutes, r.share, r.cachedShare])).toEqual([
      ["Code & PR review", 1, 1, 0.25, null],
      ["Coding", 5, 10, 0.75, null],
    ]);
  });

  it("merges model aliases by title, sorts by $, keeps other last", () => {
    const rows = modelRows(s);
    expect(rows.map((r) => [r.id, r.usd, r.tokens])).toEqual([
      ["Opus 4.7", 3, 225],
      ["Other models", 0.5, 10],
    ]);
    expect(rows[0]?.cachedShare).toBeCloseTo(300 / 550);
  });

  it("marks an unpriced engine and capitalises effort levels", () => {
    expect(engineRows(s).map((r) => r.id)).toEqual(["Claude Code", "Codex CLI · unpriced"]);
    expect(effortRows(s).map((r) => r.id)).toEqual(["High", "Unset"]);
  });

  it("titles Claude model ids the way the pane did", () => {
    expect(modelTitle("claude-opus-4-5-20250805")).toBe("Opus 4.5");
    expect(modelTitle("claude-fable-5[1m]")).toBe("Fable 5");
    expect(modelTitle("claude-haiku-4-5-20251001")).toBe("Haiku 4.5");
    expect(modelTitle("gpt-5")).toBe("gpt-5");
  });
});
