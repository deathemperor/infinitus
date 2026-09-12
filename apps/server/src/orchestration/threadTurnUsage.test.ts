import { describe, expect, it } from "@effect/vitest";
import { TurnId } from "@t3tools/contracts";

import { turnUsageFromCompletedTurn } from "./threadTurnUsage.ts";

const turnId = TurnId.make("turn-1");
const at = "2026-09-12T00:00:00.000Z";

describe("turnUsageFromCompletedTurn (#834)", () => {
  it("records a complete turn with the adapter's cost and first model", () => {
    expect(
      turnUsageFromCompletedTurn(
        {
          state: "completed",
          tokenUsage: {
            usageScope: "main_agent",
            usageStatus: "complete",
            inputTokens: 900,
            outputTokens: 100,
            cachedInputTokens: 700,
            cacheCreationTokens: 50,
            reasoningTokens: 20,
            hasSubagents: true,
          },
          turnCostUsd: 0.12,
          turnModels: ["claude-opus-4-7", "claude-haiku-4-5"],
        },
        turnId,
        at,
      ),
    ).toEqual({
      turnId,
      model: "claude-opus-4-7",
      inputTokens: 900,
      outputTokens: 100,
      cachedInputTokens: 700,
      cacheCreationTokens: 50,
      reasoningTokens: 20,
      complete: true,
      hasSubagents: true,
      costUsd: 0.12,
      completedAt: at,
    });
  });

  it("marks partial totals and fills what a provider left out", () => {
    const partial = turnUsageFromCompletedTurn(
      {
        state: "completed",
        tokenUsage: {
          usageScope: "main_agent",
          usageStatus: "partial",
          outputTokens: 40,
          hasSubagents: false,
        },
      },
      turnId,
      at,
    );
    expect(partial).toMatchObject({
      complete: false,
      model: null,
      inputTokens: 0,
      outputTokens: 40,
      reasoningTokens: null,
      costUsd: null,
    });
  });

  it("records nothing without usage", () => {
    expect(turnUsageFromCompletedTurn({ state: "failed" }, turnId, at)).toBeUndefined();
    expect(
      turnUsageFromCompletedTurn(
        {
          state: "completed",
          tokenUsage: { usageScope: "main_agent", usageStatus: "unavailable", hasSubagents: false },
        },
        turnId,
        at,
      ),
    ).toBeUndefined();
  });
});
