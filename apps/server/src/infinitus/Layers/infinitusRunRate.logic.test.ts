import { TurnId, type ThreadTurnUsage } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import {
  foldRunRate,
  RUN_RATE_WINDOW_MS,
  runRateSample,
  withinWindow,
  type RunRateSample,
} from "./infinitusRunRate.logic.ts";

const now = Date.parse("2026-09-13T12:00:00.000Z");

const usage = (overrides: Partial<ThreadTurnUsage> = {}): ThreadTurnUsage => ({
  turnId: TurnId.make("turn-1"),
  model: "claude-opus-5",
  inputTokens: 100,
  outputTokens: 400,
  cachedInputTokens: 1_000,
  cacheCreationTokens: 500,
  reasoningTokens: null,
  complete: true,
  hasSubagents: false,
  costUsd: 0.12,
  completedAt: DateTime.formatIso(DateTime.makeUnsafe(now)),
  ...overrides,
});

const sample = (ageMs: number, outputTokens: number): RunRateSample => ({
  at: now - ageMs,
  outputTokens,
  totalTokens: outputTokens * 2,
});

describe("runRateSample", () => {
  it("counts every token the turn moved, output on its own", () => {
    expect(runRateSample(usage())).toEqual({ at: now, outputTokens: 400, totalTokens: 2_000 });
  });

  it("drops a turn whose provider reported no usage", () => {
    // Zeros marked "not reported" (Cursor, Grok) would read as a turn that
    // burned nothing and drag the rate down.
    expect(runRateSample(usage({ usageUnavailable: true }))).toBeNull();
  });

  it("drops a completion it cannot date", () => {
    expect(runRateSample(usage({ completedAt: "not a date" }))).toBeNull();
  });
});

describe("withinWindow", () => {
  it("keeps what the window still covers and forgets the rest", () => {
    const kept = sample(RUN_RATE_WINDOW_MS - 1_000, 10);
    const gone = sample(RUN_RATE_WINDOW_MS + 1_000, 99);
    expect(withinWindow([gone, kept], now)).toEqual([kept]);
  });

  it("keeps a turn stamped a moment ahead of the reading clock", () => {
    const ahead = sample(-500, 10);
    expect(withinWindow([ahead], now)).toEqual([ahead]);
  });
});

describe("foldRunRate", () => {
  it("sums the window and says how wide it is", () => {
    const rate = foldRunRate([sample(60_000, 300), sample(120_000, 200)], now);
    expect(rate).toEqual({
      windowMinutes: 5,
      turns: 2,
      outputTokens: 500,
      totalTokens: 1_000,
    });
  });

  it("reports no turns rather than a rate of zero when the window is empty", () => {
    const rate = foldRunRate([sample(RUN_RATE_WINDOW_MS + 1, 5_000)], now);
    expect(rate.turns).toBe(0);
    expect(rate.outputTokens).toBe(0);
  });
});
