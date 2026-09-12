import { describe, expect, it } from "@effect/vitest";
import { TurnId, type ThreadTurnUsage } from "@t3tools/contracts";

import { addTurnUsage, foldTurnUsage } from "./threadUsage.ts";

const turn = (id: string, overrides: Partial<ThreadTurnUsage> = {}): ThreadTurnUsage => ({
  turnId: TurnId.make(id),
  model: "claude-opus-4-7",
  inputTokens: 1000,
  outputTokens: 200,
  cachedInputTokens: 800,
  cacheCreationTokens: 100,
  reasoningTokens: 50,
  complete: true,
  hasSubagents: false,
  costUsd: 0.25,
  completedAt: "2026-09-12T00:00:00.000Z",
  ...overrides,
});

describe("thread usage rollup (#834)", () => {
  it("starts a runtime rollup from the first turn and sums the next", () => {
    const first = addTurnUsage(undefined, turn("t1"));
    expect(first).toEqual({
      source: "runtime",
      turns: 1,
      inputTokens: 1000,
      outputTokens: 200,
      cachedInputTokens: 800,
      cacheCreationTokens: 100,
      reasoningTokens: 50,
      subagentTurns: 0,
      costUsd: 0.25,
      models: ["claude-opus-4-7"],
      lastTurnAt: "2026-09-12T00:00:00.000Z",
    });
    const second = addTurnUsage(
      first,
      turn("t2", {
        model: "claude-sonnet-5",
        hasSubagents: true,
        reasoningTokens: null,
        completedAt: "2026-09-12T00:10:00.000Z",
      }),
    );
    expect(second.turns).toBe(2);
    expect(second.inputTokens).toBe(2000);
    expect(second.reasoningTokens).toBe(50);
    expect(second.subagentTurns).toBe(1);
    expect(second.costUsd).toBe(0.5);
    expect(second.models).toEqual(["claude-opus-4-7", "claude-sonnet-5"]);
    expect(second.lastTurnAt).toBe("2026-09-12T00:10:00.000Z");
  });

  it("keeps cost null until a turn carries one, and a repeated model once", () => {
    const unpriced = addTurnUsage(undefined, turn("t1", { costUsd: null }));
    expect(unpriced.costUsd).toBeNull();
    const priced = addTurnUsage(unpriced, turn("t2", { costUsd: 0.1 }));
    expect(priced.costUsd).toBe(0.1);
    expect(addTurnUsage(priced, turn("t3", { costUsd: null })).costUsd).toBe(0.1);
    expect(priced.models).toEqual(["claude-opus-4-7"]);
    expect(addTurnUsage(priced, turn("t4", { model: null })).models).toEqual(["claude-opus-4-7"]);
  });

  it("keeps a transcript rollup's source and an older lastTurnAt never wins", () => {
    const transcript = { ...addTurnUsage(undefined, turn("t0")), source: "transcript" as const };
    const next = addTurnUsage(transcript, turn("t1", { completedAt: "2026-09-11T00:00:00.000Z" }));
    expect(next.source).toBe("transcript");
    expect(next.lastTurnAt).toBe("2026-09-12T00:00:00.000Z");
  });

  it("folds a list, and none is absence", () => {
    expect(foldTurnUsage([])).toBeUndefined();
    expect(foldTurnUsage([turn("t1"), turn("t2")])?.turns).toBe(2);
  });
});
