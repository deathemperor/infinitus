import { describe, expect, it } from "@effect/vitest";
import { TurnId, type ThreadTurnUsage } from "@infinitus/contracts";

import {
  addTurnUsage,
  foldTurnUsage,
  promptCacheNextChangeMs,
  promptCacheRemainingLabel,
  promptCacheState,
  threadUsageReported,
} from "./threadUsage.ts";

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

  it("dates the cache expiry from the latest turn's TTL, and drops it when that turn has none", () => {
    const warm = addTurnUsage(undefined, turn("t1", { cacheTtlSeconds: 3600 }));
    expect(warm.cacheExpiresAt).toBe("2026-09-12T01:00:00.000Z");
    const later = addTurnUsage(
      warm,
      turn("t2", { cacheTtlSeconds: 300, completedAt: "2026-09-12T00:30:00.000Z" }),
    );
    expect(later.cacheExpiresAt).toBe("2026-09-12T00:35:00.000Z");
    // A refold that meets an older turn after the latest keeps the latest's expiry.
    const older = addTurnUsage(
      later,
      turn("t0", { cacheTtlSeconds: 3600, completedAt: "2026-09-11T00:00:00.000Z" }),
    );
    expect(older.cacheExpiresAt).toBe("2026-09-12T00:35:00.000Z");
    // A latest turn that says nothing about the cache (a Codex turn) clears it.
    const silent = addTurnUsage(later, turn("t3", { completedAt: "2026-09-12T00:31:00.000Z" }));
    expect(silent).not.toHaveProperty("cacheExpiresAt");
  });

  it("sums tool calls and time only from the turns that carried them", () => {
    const plain = addTurnUsage(undefined, turn("t1"));
    expect(plain).not.toHaveProperty("toolCalls");
    expect(plain).not.toHaveProperty("durationMs");
    const counted = addTurnUsage(plain, turn("t2", { toolCalls: 4, durationMs: 60_000 }));
    expect(counted).toMatchObject({ toolCalls: 4, durationMs: 60_000 });
    const more = addTurnUsage(counted, turn("t3", { toolCalls: 1, durationMs: 5_000 }));
    expect(more).toMatchObject({ toolCalls: 5, durationMs: 65_000 });
    // A turn the server did not time leaves the sums as they were.
    expect(addTurnUsage(more, turn("t4"))).toMatchObject({ toolCalls: 5, durationMs: 65_000 });
  });

  it("counts the turns whose provider reported no usage, and knows when none did", () => {
    const unreported = (id: string, toolCalls: number): ThreadTurnUsage => ({
      ...turn(id, { toolCalls, durationMs: 10_000, model: null, costUsd: null }),
      inputTokens: 0,
      outputTokens: 0,
      cachedInputTokens: 0,
      cacheCreationTokens: 0,
      reasoningTokens: null,
      complete: false,
      usageUnavailable: true,
    });
    const reported = addTurnUsage(undefined, turn("t1"));
    expect(reported).not.toHaveProperty("unreportedTurns");
    expect(threadUsageReported(reported)).toBe(true);

    const onlyUnreported = addTurnUsage(
      addTurnUsage(undefined, unreported("u1", 3)),
      unreported("u2", 2),
    );
    expect(onlyUnreported).toMatchObject({
      turns: 2,
      unreportedTurns: 2,
      inputTokens: 0,
      costUsd: null,
      models: [],
      toolCalls: 5,
      durationMs: 20_000,
    });
    expect(threadUsageReported(onlyUnreported)).toBe(false);

    // One turn that reported makes the figures mean something.
    const mixed = addTurnUsage(onlyUnreported, turn("t3"));
    expect(mixed).toMatchObject({ turns: 3, unreportedTurns: 2, inputTokens: 1000 });
    expect(threadUsageReported(mixed)).toBe(true);

    // A transcript estimate's tokens are the transcript's, whatever ran since.
    const transcript = foldTurnUsage([unreported("u3", 1)], {
      ...reported,
      source: "transcript",
    });
    expect(transcript).toMatchObject({ unreportedTurns: 1 });
    expect(threadUsageReported(transcript!)).toBe(true);
  });

  it("folds a list, and none is absence", () => {
    expect(foldTurnUsage([])).toBeUndefined();
    expect(foldTurnUsage([turn("t1"), turn("t2")])?.turns).toBe(2);
  });

  it("folds onto a transcript baseline, which no rows leaves as it is", () => {
    const base = {
      ...addTurnUsage(undefined, turn("t0", { costUsd: 1 })),
      source: "transcript" as const,
    };
    expect(foldTurnUsage([], base)).toEqual(base);
    const folded = foldTurnUsage([turn("t1"), turn("t2", { costUsd: null })], base);
    expect(folded?.source).toBe("transcript");
    expect(folded?.turns).toBe(3);
    expect(folded?.inputTokens).toBe(3000);
    expect(folded?.costUsd).toBe(1.25);
  });
});

describe("prompt cache state", () => {
  const lastTurnAt = "2026-09-23T10:00:00.000Z";
  const hour = { lastTurnAt, cacheExpiresAt: "2026-09-23T11:00:00.000Z" };
  const fiveMinutes = { lastTurnAt, cacheExpiresAt: "2026-09-23T10:05:00.000Z" };
  const at = (iso: string) => Date.parse(iso);

  it("is warm, then expiring in the last fifth of the TTL (at most 5 minutes), then cold", () => {
    expect(promptCacheState(hour, at("2026-09-23T10:30:00.000Z"))?.kind).toBe("warm");
    expect(promptCacheState(hour, at("2026-09-23T10:55:00.000Z"))?.kind).toBe("expiring");
    expect(promptCacheState(hour, at("2026-09-23T11:00:00.000Z"))?.kind).toBe("cold");
    expect(promptCacheState(fiveMinutes, at("2026-09-23T10:03:59.000Z"))?.kind).toBe("warm");
    expect(promptCacheState(fiveMinutes, at("2026-09-23T10:04:00.000Z"))?.kind).toBe("expiring");
  });

  it("says nothing for a thread whose last turn reported no TTL", () => {
    expect(promptCacheState({ lastTurnAt }, at(lastTurnAt))).toBeNull();
  });

  it("rounds the minutes left down, so the label never overstates", () => {
    expect(promptCacheRemainingLabel(60 * 60_000)).toBe("1h");
    expect(promptCacheRemainingLabel(42 * 60_000 + 59_000)).toBe("42m");
    expect(promptCacheRemainingLabel(59_000)).toBe("<1m");
  });

  it("wakes just past each minute of the expiry's grid, where the label drops, and stops once cold", () => {
    const labelAfterWake = (nowIso: string) => {
      const nowMs = at(nowIso);
      const wakeMs = nowMs + (promptCacheNextChangeMs(fiveMinutes.cacheExpiresAt, nowMs) ?? 0);
      const state = promptCacheState(fiveMinutes, wakeMs);
      return state?.kind === "cold" ? "cold" : promptCacheRemainingLabel(state?.remainingMs ?? 0);
    };
    expect(labelAfterWake("2026-09-23T10:00:20.000Z")).toBe("3m");
    expect(labelAfterWake("2026-09-23T10:01:00.000Z")).toBe("3m");
    expect(labelAfterWake("2026-09-23T10:03:30.000Z")).toBe("<1m");
    expect(labelAfterWake("2026-09-23T10:04:30.000Z")).toBe("cold");
    expect(promptCacheNextChangeMs(hour.cacheExpiresAt, at("2026-09-23T11:00:00.000Z"))).toBeNull();
  });
});
