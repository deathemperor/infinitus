import type { ThreadUsageRollup } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { threadUsageNotes, threadUsageRows } from "./threadUsage.logic";

const ROLLUP: ThreadUsageRollup = {
  source: "runtime",
  turns: 3,
  inputTokens: 1_234_567,
  outputTokens: 8_900,
  cachedInputTokens: 1_000_000,
  cacheCreationTokens: 20_000,
  reasoningTokens: 400,
  subagentTurns: 0,
  costUsd: 1.2345,
  models: ["claude-opus-5", "claude-sonnet-5"],
  lastTurnAt: "2026-09-12T14:37:00.000Z",
};

describe("thread usage sheet (#834)", () => {
  it("marks every estimate with ≈ and lists each token share on its own row", () => {
    const rows = threadUsageRows(ROLLUP);
    expect(rows.map((row) => [row.label, row.value])).toEqual([
      ["Turns", "3"],
      ["Input tokens", "≈ 1.23M"],
      ["Output tokens", "≈ 8.90K"],
      ["Cached input", "≈ 1M"],
      ["Cache creation", "≈ 20K"],
      ["Reasoning", "≈ 400"],
      ["Models", "claude-opus-5, claude-sonnet-5"],
      ["Cost", "≈ $1.23"],
      ["Last turn", expect.stringContaining("Sep 12")],
    ]);
  });

  it("shows tool calls and the time working only when the server counted them (#927)", () => {
    const rows = threadUsageRows({ ...ROLLUP, toolCalls: 12, durationMs: 754_000 });
    expect(rows.slice(0, 3).map((row) => [row.label, row.value])).toEqual([
      ["Turns", "3"],
      ["Tool calls", "12"],
      ["Duration", "12m 34s"],
    ]);
    expect(threadUsageRows(ROLLUP).map((row) => row.label)).not.toContain("Tool calls");
  });

  it("hides zero shares and an unnamed model, and says when no cost was recorded", () => {
    const rows = threadUsageRows({
      ...ROLLUP,
      costUsd: null,
      models: ["codex-5"],
      cachedInputTokens: 0,
      cacheCreationTokens: 0,
      reasoningTokens: 0,
      subagentTurns: 1,
    });
    expect(rows.map((row) => row.label)).toEqual([
      "Turns",
      "Input tokens",
      "Output tokens",
      "Model",
      "Cost",
      "Last turn",
    ]);
    expect(rows[0]?.value).toBe("3 (1 ran subagents)");
    expect(rows[4]?.value).toBe("Cost not recorded");
    expect(threadUsageRows({ ...ROLLUP, models: [] }).some((row) => row.label === "Models")).toBe(
      false,
    );
  });

  it("always says the numbers are estimates, and names the transcript and subagent caveats", () => {
    expect(threadUsageNotes(ROLLUP)).toEqual(["Estimates from the provider, not billing."]);
    expect(threadUsageNotes({ ...ROLLUP, source: "transcript", subagentTurns: 1 })).toEqual([
      "Estimates from the provider, not billing.",
      "Estimated from the transcript.",
      "Subagent tokens are not counted.",
    ]);
  });
});
