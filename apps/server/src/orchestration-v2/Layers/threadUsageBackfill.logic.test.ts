import { describe, expect, it } from "vite-plus/test";

import { isLegacyCandidate, transcriptUsageRollup } from "./threadUsageBackfill.logic.ts";

describe("transcript backfill logic (#834)", () => {
  it("only a candidate whose turns all predate boot is legacy", () => {
    const bootAt = "2026-09-12T10:00:00.000Z";
    expect(isLegacyCandidate({ lastTurnAt: null }, bootAt)).toBe(true);
    expect(isLegacyCandidate({ lastTurnAt: "2026-09-11T23:59:59.000Z" }, bootAt)).toBe(true);
    expect(isLegacyCandidate({ lastTurnAt: "2026-09-12T10:00:01.000Z" }, bootAt)).toBe(false);
  });

  it("turns the session total into a transcript rollup, input tokens including the cache", () => {
    expect(
      transcriptUsageRollup(
        {
          totals: {
            uncachedInputTokens: 100,
            cachedInputTokens: 900,
            cacheCreationTokens: 50,
            outputTokens: 40,
            reasoningTokens: 0,
          },
          costUsd: 0.12,
          models: ["claude-opus-4-7", "claude-sonnet-5"],
          lastAt: "2026-09-12T09:00:00.000Z",
        },
        3,
      ),
    ).toEqual({
      source: "transcript",
      turns: 3,
      inputTokens: 1050,
      outputTokens: 40,
      cachedInputTokens: 900,
      cacheCreationTokens: 50,
      reasoningTokens: 0,
      subagentTurns: 0,
      costUsd: 0.12,
      models: ["claude-opus-4-7", "claude-sonnet-5"],
      lastTurnAt: "2026-09-12T09:00:00.000Z",
    });
  });
});
