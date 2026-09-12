import { describe, expect, it } from "@effect/vitest";

import { claudeTurnUsageDelta } from "./claudeTurnUsage.logic.ts";

const model = (inputTokens: number, outputTokens: number, costUSD: number) => ({
  inputTokens,
  outputTokens,
  cacheReadInputTokens: 0,
  cacheCreationInputTokens: 0,
  costUSD,
});

describe("claudeTurnUsageDelta (#834)", () => {
  it("takes the first result whole and differences the next", () => {
    const first = claudeTurnUsageDelta(undefined, {
      total_cost_usd: 0.3,
      modelUsage: { "claude-opus-4-7": model(100, 50, 0.3) },
    });
    expect(first.turnCostUsd).toBe(0.3);
    expect(first.turnModels).toEqual(["claude-opus-4-7"]);
    const second = claudeTurnUsageDelta(first.totals, {
      total_cost_usd: 0.5,
      modelUsage: {
        "claude-opus-4-7": model(100, 50, 0.3),
        "claude-haiku-4-5": model(1000, 10, 0.2),
      },
    });
    expect(second.turnCostUsd).toBeCloseTo(0.2, 10);
    expect(second.turnModels).toEqual(["claude-haiku-4-5"]);
  });

  it("orders the turn's models by tokens moved", () => {
    const previous = claudeTurnUsageDelta(undefined, {
      total_cost_usd: 1,
      modelUsage: { a: model(10, 10, 0.5), b: model(10, 10, 0.5) },
    }).totals;
    const next = claudeTurnUsageDelta(previous, {
      total_cost_usd: 2,
      modelUsage: { a: model(20, 10, 0.7), b: model(100, 10, 1.3) },
    });
    expect(next.turnModels).toEqual(["b", "a"]);
    expect(next.turnCostUsd).toBe(1);
  });

  it("treats a total that went down as a session that started over", () => {
    const previous = claudeTurnUsageDelta(undefined, {
      total_cost_usd: 2,
      modelUsage: { a: model(500, 500, 2) },
    }).totals;
    const fresh = claudeTurnUsageDelta(previous, {
      total_cost_usd: 0.4,
      modelUsage: { a: model(50, 20, 0.4) },
    });
    expect(fresh.turnCostUsd).toBe(0.4);
    expect(fresh.turnModels).toEqual(["a"]);
    // A model the previous totals knew that is gone now is a restart too.
    const renamed = claudeTurnUsageDelta(previous, {
      total_cost_usd: 3,
      modelUsage: { b: model(10, 10, 3) },
    });
    expect(renamed.turnCostUsd).toBe(3);
  });

  it("keeps the previous totals when a result carries no cost", () => {
    const previous = claudeTurnUsageDelta(undefined, { total_cost_usd: 1, modelUsage: {} }).totals;
    const none = claudeTurnUsageDelta(previous, undefined);
    expect(none.totals).toBe(previous);
    expect(none.turnCostUsd).toBeUndefined();
    expect(none.turnModels).toBeUndefined();
    const noModels = claudeTurnUsageDelta(previous, { total_cost_usd: 1.5 });
    expect(noModels.turnCostUsd).toBe(0.5);
    expect(noModels.turnModels).toBeUndefined();
  });
});
