import { describe, expect, it } from "@effect/vitest";
import { ThreadId, TurnId } from "@t3tools/contracts";

import { TurnTelemetryTracker, turnUsageFromCompletedTurn } from "./threadTurnUsage.ts";

const threadId = ThreadId.make("thread-1");
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

  it("carries the tool calls and wall time the tracker counted, else neither", () => {
    const payload = {
      state: "completed" as const,
      tokenUsage: {
        usageScope: "main_agent" as const,
        usageStatus: "partial" as const,
        outputTokens: 1,
        hasSubagents: false,
      },
    };
    expect(
      turnUsageFromCompletedTurn(payload, turnId, at, { toolCalls: 3, durationMs: 90_000 }),
    ).toMatchObject({ toolCalls: 3, durationMs: 90_000 });
    const untracked = turnUsageFromCompletedTurn(payload, turnId, at);
    expect(untracked).not.toHaveProperty("toolCalls");
    expect(untracked).not.toHaveProperty("durationMs");
  });

  it("records a turn without usage as a marker row when the ingestion counted something", () => {
    // Cursor and Grok send no tokenUsage at all.
    expect(
      turnUsageFromCompletedTurn({ state: "completed", turnModels: ["grok-4"] }, turnId, at, {
        toolCalls: 5,
        durationMs: 42_000,
      }),
    ).toEqual({
      turnId,
      model: "grok-4",
      inputTokens: 0,
      outputTokens: 0,
      cachedInputTokens: 0,
      cacheCreationTokens: 0,
      reasoningTokens: null,
      complete: false,
      hasSubagents: false,
      costUsd: null,
      completedAt: at,
      toolCalls: 5,
      durationMs: 42_000,
      usageUnavailable: true,
    });
    // An adapter answering `unavailable` is the same row.
    expect(
      turnUsageFromCompletedTurn(
        {
          state: "completed",
          tokenUsage: { usageScope: "main_agent", usageStatus: "unavailable", hasSubagents: true },
        },
        turnId,
        at,
        { toolCalls: 0, durationMs: 1_000 },
      ),
    ).toMatchObject({ usageUnavailable: true, hasSubagents: true, toolCalls: 0 });
    // A turn that reported carries no marker.
    expect(
      turnUsageFromCompletedTurn(
        {
          state: "completed",
          tokenUsage: { usageScope: "main_agent", usageStatus: "partial", hasSubagents: false },
        },
        turnId,
        at,
        { toolCalls: 1, durationMs: 1_000 },
      ),
    ).not.toHaveProperty("usageUnavailable");
  });

  it("records nothing without usage or a counted start", () => {
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

describe("TurnTelemetryTracker (#834)", () => {
  const later = "2026-09-12T00:01:30.000Z";

  it("counts distinct tool items from the first start to the completion", () => {
    const tracker = new TurnTelemetryTracker();
    tracker.started(threadId, turnId, at);
    tracker.toolSeen(threadId, turnId, "item-1");
    tracker.toolSeen(threadId, turnId, "item-1");
    tracker.toolSeen(threadId, turnId, "item-2");
    // A reconnect announces the turn again; the first clock stays.
    tracker.started(threadId, turnId, "2026-09-12T00:01:00.000Z");
    expect(tracker.completed(threadId, turnId, later)).toEqual({
      toolCalls: 2,
      durationMs: 90_000,
    });
    // Read once: the turn is forgotten.
    expect(tracker.completed(threadId, turnId, later)).toBeUndefined();
  });

  it("answers nothing for a turn whose start it did not see, an aborted one, or an exited session's", () => {
    const tracker = new TurnTelemetryTracker();
    tracker.toolSeen(threadId, turnId, "item-1");
    expect(tracker.completed(threadId, turnId, later)).toBeUndefined();

    tracker.started(threadId, turnId, at);
    tracker.aborted(threadId, turnId);
    expect(tracker.completed(threadId, turnId, later)).toBeUndefined();

    const other = TurnId.make("turn-2");
    tracker.started(threadId, other, at);
    tracker.started(ThreadId.make("thread-2"), other, at);
    tracker.threadEnded(threadId);
    expect(tracker.completed(threadId, other, later)).toBeUndefined();
    expect(tracker.completed(ThreadId.make("thread-2"), other, later)).toEqual({
      toolCalls: 0,
      durationMs: 90_000,
    });
  });

  it("never records a negative duration", () => {
    const tracker = new TurnTelemetryTracker();
    tracker.started(threadId, turnId, later);
    expect(tracker.completed(threadId, turnId, at)?.durationMs).toBe(0);
  });
});
