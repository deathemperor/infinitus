import { TurnId, type ThreadTurnUsage } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import {
  EMPTY_LIVE_TOKEN_RATE,
  foldLiveTokenRate,
  liveTokenRateSince,
} from "./liveTokenRate.logic.ts";

const NOW = "2026-09-14T12:00:00.000Z";
const nowMs = Date.parse(NOW);
const at = { nowMs };

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
    completedAt: NOW,
    ...over,
  }) as ThreadTurnUsage;

describe("liveTokenRateSince", () => {
  it("is the window's width behind the given instant", () => {
    const now = DateTime.makeUnsafe(NOW);

    expect(liveTokenRateSince(now)).toBe("2026-09-14T11:55:00.000Z");
    // The width the fold divides by is the width the read asked for.
    expect(foldLiveTokenRate([], at).windowMinutes).toBe(5);
    expect(EMPTY_LIVE_TOKEN_RATE.windowMinutes).toBe(5);
  });
});

describe("foldLiveTokenRate", () => {
  it("divides the window's tokens by its minutes", () => {
    const rate = foldLiveTokenRate(
      [
        turn({ inputTokens: 1_000, outputTokens: 500 }),
        turn({ turnId: TurnId.make("turn-2"), inputTokens: 3_000, outputTokens: 1_000 }),
      ],
      at,
    );

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
    expect(foldLiveTokenRate([reported, unavailable], at)).toEqual(
      foldLiveTokenRate([reported], at),
    );
  });

  it("answers no turns when the window holds nothing that reported", () => {
    expect(foldLiveTokenRate([], at)).toEqual(EMPTY_LIVE_TOKEN_RATE);
    // A window of nothing but unreported turns is just as unknown.
    expect(foldLiveTokenRate([turn({ usageUnavailable: true })], at).turns).toBe(0);
  });

  it("counts only the part of a long turn that ran inside the window (#1127)", () => {
    // Thirty minutes of work finishing now: a sixth of it is in the window, so
    // a sixth of its tokens are. Counting it whole read ~6x the true rate.
    const rate = foldLiveTokenRate(
      [turn({ inputTokens: 0, outputTokens: 30_000, durationMs: 30 * 60_000 })],
      at,
    );

    expect(rate.turns).toBe(1);
    expect(rate.outputPerMinute).toBeCloseTo(1_000, 6);
    // Unclipped this would have been 30_000 / 5 = 6_000.
  });

  it("counts a turn that fits inside the window whole", () => {
    const rate = foldLiveTokenRate([turn({ outputTokens: 2_000, durationMs: 60_000 })], at);

    expect(rate.outputPerMinute).toBeCloseTo(400, 6);
  });

  it("drops a turn whose whole span ended before the window", () => {
    // The read asks for rows completed inside the window, but a row that
    // slipped in — a clock skew, a wider read — must not count.
    const rate = foldLiveTokenRate(
      [turn({ completedAt: "2026-09-14T11:50:00.000Z", outputTokens: 5_000, durationMs: 60_000 })],
      at,
    );

    expect(rate).toEqual(EMPTY_LIVE_TOKEN_RATE);
  });

  it("counts a turn with no measured duration whole, at its completion", () => {
    // A turn this server never saw start has nothing to spread over; dropping
    // it would understate a server whose turns predate wall-time counting.
    const rate = foldLiveTokenRate([turn({ outputTokens: 500 })], at);

    expect(rate.turns).toBe(1);
    expect(rate.outputPerMinute).toBe(100);
  });

  it("spreads input and output by the same share", () => {
    const rate = foldLiveTokenRate(
      [turn({ inputTokens: 10_000, outputTokens: 10_000, durationMs: 10 * 60_000 })],
      at,
    );

    // Half the ten minutes is inside the five-minute window.
    expect(rate.outputPerMinute).toBeCloseTo(1_000, 6);
    expect(rate.totalPerMinute).toBeCloseTo(2_000, 6);
  });
});
