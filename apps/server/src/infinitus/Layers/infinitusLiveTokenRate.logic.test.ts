import { ThreadId, TurnId, type ThreadTurnUsage } from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import { liveTokenRate, LIVE_RATE_WINDOW_MINUTES } from "./infinitusLiveTokenRate.logic.ts";
import type { ProjectionTurnUsage } from "../../persistence/ProjectionTurnUsage.ts";

const nowMs = Date.parse("2026-09-14T12:00:00.000Z");
const isoAt = (ms: number): string => DateTime.formatIso(DateTime.makeUnsafe(ms));
const agoIso = (minutes: number): string => isoAt(nowMs - minutes * 60_000);

const row = (
  threadId: string,
  turnId: string,
  completedAt: string,
  outputTokens: number,
  overrides: Partial<ThreadTurnUsage> = {},
): ProjectionTurnUsage => ({
  threadId: ThreadId.make(threadId),
  turnUsage: {
    turnId: TurnId.make(turnId),
    model: "claude-opus-4-7",
    inputTokens: 1000,
    outputTokens,
    cachedInputTokens: 900,
    cacheCreationTokens: 10,
    reasoningTokens: 5,
    complete: true,
    hasSubagents: false,
    costUsd: null,
    completedAt,
    ...overrides,
  },
});

describe("liveTokenRate (#1127)", () => {
  it("divides the window's output tokens by its minutes, counting threads and turns", () => {
    const rate = liveTokenRate({
      nowMs,
      rows: [
        row("thread-a", "turn-1", agoIso(4), 3000),
        row("thread-a", "turn-2", agoIso(2), 1500),
        row("thread-b", "turn-3", agoIso(1), 3000),
      ],
    });

    expect(rate).toEqual({
      windowMinutes: LIVE_RATE_WINDOW_MINUTES,
      outputTokens: 7500,
      perMinute: 1500,
      turns: 3,
      threads: 2,
      accounts: [],
    });
  });

  it("is null when no turn completed in the window, so the page shows nothing", () => {
    expect(liveTokenRate({ nowMs, rows: [] })).toBeNull();
    // Older than the window, and a mark the server cannot read.
    expect(
      liveTokenRate({
        nowMs,
        rows: [row("thread-a", "turn-1", agoIso(6), 9000), row("thread-a", "turn-2", "soon", 9000)],
      }),
    ).toBeNull();
  });

  it("counts a turn the provider reported no usage for, at zero tokens", () => {
    const rate = liveTokenRate({
      nowMs,
      rows: [row("thread-a", "turn-1", agoIso(1), 0, { usageUnavailable: true, complete: false })],
    });

    expect(rate?.turns).toBe(1);
    expect(rate?.outputTokens).toBe(0);
    expect(rate?.perMinute).toBe(0);
  });

  it("drops a turn stamped in the future rather than counting it at an unknown instant", () => {
    const future = isoAt(nowMs + 60_000);
    expect(liveTokenRate({ nowMs, rows: [row("thread-a", "turn-1", future, 5000)] })).toBeNull();
  });

  it("splits by the account the swap log names, busiest first, and skips unattributed turns", () => {
    const accounts = {
      accountAt: (timestampMs: number) =>
        timestampMs >= nowMs - 3 * 60_000 ? "ada@example.com" : null,
      describe: (email: string) => ({ label: email === "ada@example.com" ? "ada" : email }),
    };
    const rate = liveTokenRate({
      nowMs,
      accounts,
      rows: [
        // Before the only switch the log knows: counted in the total, in no account.
        row("thread-a", "turn-1", agoIso(4), 2500),
        row("thread-a", "turn-2", agoIso(2), 4000),
        row("thread-b", "turn-3", agoIso(1), 1000),
      ],
    });

    expect(rate?.outputTokens).toBe(7500);
    expect(rate?.accounts).toEqual([{ label: "ada", outputTokens: 5000, perMinute: 1000 }]);
  });

  it("honours a window the caller sizes itself", () => {
    const rate = liveTokenRate({
      nowMs,
      windowMinutes: 1,
      rows: [row("thread-a", "turn-1", agoIso(3), 6000), row("thread-a", "turn-2", agoIso(0), 600)],
    });

    expect(rate).toMatchObject({ windowMinutes: 1, outputTokens: 600, perMinute: 600, turns: 1 });
  });
});
