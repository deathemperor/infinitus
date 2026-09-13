import { TurnId, type ThreadTurnUsage } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import { foldLiveTokenRate, liveTokenRateSince } from "./liveTokenRate.logic.ts";

const turn = (over: Partial<ThreadTurnUsage> = {}): ThreadTurnUsage =>
  ({
    turnId: TurnId.make("turn-1"),
    model: "claude-opus-5",
    inputTokens: 0,
    outputTokens: 0,
    cachedInputTokens: 0,
    cacheCreationTokens: 0,
    reasoningTokens: null,
    complete: true,
    hasSubagents: false,
    costUsd: null,
    completedAt: "2026-09-14T12:00:00.000Z",
    ...over,
  }) as ThreadTurnUsage;

describe("liveTokenRateSince", () => {
  it("is the window's width behind the given instant", () => {
    const now = DateTime.makeUnsafe("2026-09-14T12:00:00.000Z");

    expect(liveTokenRateSince(now)).toBe("2026-09-14T11:55:00.000Z");
    // The width the fold divides by is the width the read asked for.
    expect(foldLiveTokenRate([]).windowMinutes).toBe(5);
  });
});

describe("foldLiveTokenRate", () => {
  it("divides the window's tokens by its minutes", () => {
    const rate = foldLiveTokenRate([
      turn({ inputTokens: 1_000, outputTokens: 500 }),
      turn({ turnId: TurnId.make("turn-2"), inputTokens: 3_000, outputTokens: 1_000 }),
    ]);

    expect(rate).toEqual({
      windowMinutes: 5,
      turns: 2,
      outputPerMinute: 300,
      totalPerMinute: 1_100,
    });
  });

  it("skips a turn whose provider reported no usage, rather than averaging in a zero", () => {
    const reported = turn({ inputTokens: 1_000, outputTokens: 500 });
    const unavailable = turn({ turnId: TurnId.make("turn-2"), usageUnavailable: true });

    // The unreported turn moves neither the rate nor the count it is read with.
    expect(foldLiveTokenRate([reported, unavailable])).toEqual(foldLiveTokenRate([reported]));
  });

  it("answers no turns when the window holds nothing that reported", () => {
    expect(foldLiveTokenRate([])).toEqual({
      windowMinutes: 5,
      turns: 0,
      outputPerMinute: 0,
      totalPerMinute: 0,
    });
    // A window of nothing but unreported turns is just as unknown.
    expect(foldLiveTokenRate([turn({ usageUnavailable: true })]).turns).toBe(0);
  });
});
