import { ThreadId, type ThreadUsageRollup } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import type { SessionUsage } from "../usage/UsageService.ts";
import {
  baselineForCandidate,
  isLegacyCandidate,
  transcriptUsageRollup,
  wantsTranscript,
  type ThreadUsageBackfillCandidate,
} from "./threadUsageBackfill.logic.ts";

const BOOT_AT = "2026-09-12T12:00:00.000Z";

const candidate = (
  overrides: Partial<ThreadUsageBackfillCandidate> = {},
): ThreadUsageBackfillCandidate => ({
  threadId: ThreadId.make("thread-legacy"),
  v1Usage: null,
  claudeSessionId: "session-legacy",
  turns: 4,
  lastTurnAt: "2026-09-01T00:00:00.000Z",
  recordedUsage: false,
  ...overrides,
});

const session: SessionUsage = {
  totals: {
    uncachedInputTokens: 10,
    cachedInputTokens: 90,
    cacheCreationTokens: 5,
    outputTokens: 20,
    reasoningTokens: 0,
  },
  costUsd: 0.05,
  models: ["claude-opus-4-7"],
  lastAt: "2026-09-01T00:00:00.000Z",
};
const sessions = new Map([["session-legacy", session]]);

const v1Usage: ThreadUsageRollup = {
  source: "runtime",
  turns: 2,
  inputTokens: 1000,
  outputTokens: 50,
  cachedInputTokens: 800,
  cacheCreationTokens: 100,
  reasoningTokens: 0,
  subagentTurns: 1,
  costUsd: 0.4,
  models: ["claude-opus-4-7"],
  lastTurnAt: "2026-09-01T00:00:00.000Z",
  toolCalls: 7,
  durationMs: 65_000,
};

describe("thread usage backfill (#834, v2)", () => {
  it("is legacy only while every run predates boot", () => {
    expect(isLegacyCandidate({ lastTurnAt: null }, BOOT_AT)).toBe(true);
    expect(isLegacyCandidate({ lastTurnAt: "2026-09-01T00:00:00.000Z" }, BOOT_AT)).toBe(true);
    expect(isLegacyCandidate({ lastTurnAt: "2026-09-12T12:00:01.000Z" }, BOOT_AT)).toBe(false);
  });

  it("reads the transcript only for a legacy Claude thread with no rollup and no recorded usage", () => {
    expect(wantsTranscript(candidate(), BOOT_AT)).toBe(true);
    expect(wantsTranscript(candidate({ v1Usage }), BOOT_AT)).toBe(false);
    expect(wantsTranscript(candidate({ claudeSessionId: null }), BOOT_AT)).toBe(false);
    expect(wantsTranscript(candidate({ recordedUsage: true }), BOOT_AT)).toBe(false);
    expect(wantsTranscript(candidate({ lastTurnAt: "2026-09-13T00:00:00.000Z" }), BOOT_AT)).toBe(
      false,
    );
  });

  it("turns a transcript total into a thread-level rollup with the orchestrator's turn count", () => {
    expect(transcriptUsageRollup(session, 4)).toEqual({
      source: "transcript",
      turns: 4,
      inputTokens: 105,
      outputTokens: 20,
      cachedInputTokens: 90,
      cacheCreationTokens: 5,
      reasoningTokens: 0,
      subagentTurns: 0,
      costUsd: 0.05,
      models: ["claude-opus-4-7"],
      lastTurnAt: "2026-09-01T00:00:00.000Z",
    });
  });

  it("prefers the v1 rollup the import left, else the transcript, else nothing", () => {
    // The v1 rollup is exact and keeps its own source, even past boot.
    expect(
      baselineForCandidate(
        candidate({ v1Usage, lastTurnAt: "2026-09-13T00:00:00.000Z" }),
        sessions,
        BOOT_AT,
      ),
    ).toBe(v1Usage);
    expect(baselineForCandidate(candidate(), sessions, BOOT_AT)).toMatchObject({
      source: "transcript",
      turns: 4,
    });
    // No transcript read for the session: nothing to backfill.
    expect(baselineForCandidate(candidate(), new Map(), BOOT_AT)).toBeUndefined();
    // A turn this server recorded would be counted twice.
    expect(
      baselineForCandidate(candidate({ recordedUsage: true }), sessions, BOOT_AT),
    ).toBeUndefined();
    expect(
      baselineForCandidate(
        candidate({ lastTurnAt: "2026-09-13T00:00:00.000Z" }),
        sessions,
        BOOT_AT,
      ),
    ).toBeUndefined();
  });
});
