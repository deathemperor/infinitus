import { describe, expect, it } from "vite-plus/test";
import type { ThreadUsageRollup } from "@t3tools/contracts";

import {
  threadUsageBadgeAriaLabel,
  threadUsageBadgeLabel,
  threadUsageCostLabel,
  threadUsageRows,
  threadUsageSourceDetail,
  threadUsageSourceLine,
} from "./threadUsage.logic";

function rollup(overrides: Partial<ThreadUsageRollup> = {}): ThreadUsageRollup {
  return {
    source: "runtime",
    turns: 3,
    inputTokens: 12_400,
    outputTokens: 980,
    cachedInputTokens: 0,
    cacheCreationTokens: 2_000,
    reasoningTokens: 0,
    subagentTurns: 0,
    costUsd: 0.35,
    models: ["claude-opus-5"],
    lastTurnAt: "2026-09-12T08:00:00.000Z",
    ...overrides,
  };
}

describe("threadUsageCostLabel (#834)", () => {
  it("always marks a cost as an estimate and never shows zero for none", () => {
    expect(threadUsageCostLabel(0.35)).toBe("≈ $0.35");
    expect(threadUsageCostLabel(0.001)).toBe("≈ < $0.01");
    expect(threadUsageCostLabel(0)).toBe("≈ $0.00");
    expect(threadUsageCostLabel(null)).toBe("Cost not recorded");
  });
});

describe("threadUsageBadgeLabel", () => {
  it("shows the cost when known, else the turn count", () => {
    expect(threadUsageBadgeLabel(rollup())).toBe("≈ $0.35");
    expect(threadUsageBadgeLabel(rollup({ costUsd: null }))).toBe("3 turns");
    expect(threadUsageBadgeLabel(rollup({ costUsd: null, turns: 1 }))).toBe("1 turn");
    expect(threadUsageBadgeAriaLabel(rollup())).toBe("Thread usage: approximately $0.35");
  });
});

describe("threadUsageRows", () => {
  it("lists turns, the token counts that moved, and the models", () => {
    expect(threadUsageRows(rollup())).toEqual([
      { label: "Turns", value: "3" },
      { label: "Input tokens", value: "12k" },
      { label: "Output tokens", value: "980" },
      { label: "Cache creation", value: "2k" },
      { label: "Model", value: "claude-opus-5" },
    ]);
  });

  it("adds the tool calls and the time working when the server counted them", () => {
    const rows = threadUsageRows(rollup({ toolCalls: 17, durationMs: 3_723_000 }));
    expect(rows.slice(0, 3)).toEqual([
      { label: "Turns", value: "3" },
      { label: "Tool calls", value: "17" },
      { label: "Time working", value: "1h 2m 3s" },
    ]);
    expect(threadUsageRows(rollup({ toolCalls: 0 }))[1]).toEqual({
      label: "Tool calls",
      value: "0",
    });
  });

  it("counts subagent turns and pluralizes models", () => {
    const rows = threadUsageRows(
      rollup({ subagentTurns: 2, models: ["claude-opus-5", "claude-haiku-4-5"] }),
    );
    expect(rows[0]).toEqual({ label: "Turns", value: "3 (2 with subagents)" });
    expect(rows.at(-1)).toEqual({ label: "Models", value: "claude-opus-5, claude-haiku-4-5" });
    expect(threadUsageRows(rollup({ models: [] })).some((row) => row.label === "Model")).toBe(
      false,
    );
  });
});

describe("threadUsageSourceLine", () => {
  it("names a transcript-derived rollup and stays quiet for the runtime's", () => {
    expect(threadUsageSourceLine(rollup())).toBeNull();
    expect(threadUsageSourceLine(rollup({ source: "transcript" }))).toBe(
      "Estimated from the transcript",
    );
    expect(threadUsageSourceDetail(rollup())).toBeNull();
    expect(threadUsageSourceDetail(rollup({ source: "transcript" }))).toContain(
      "default Claude home",
    );
  });
});
