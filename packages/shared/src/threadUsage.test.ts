import { describe, expect, it } from "@effect/vitest";
import {
  NodeId,
  ProviderInstanceId,
  ProviderThreadId,
  ProviderTurnId,
  RunAttemptId,
  RunId,
  ThreadId,
  type OrchestrationV2ProviderTurn,
  type OrchestrationV2Run,
  type OrchestrationV2RunAttempt,
  type OrchestrationV2ProviderThread,
  type OrchestrationV2AppThread,
} from "@infinitus/contracts";
import * as DateTime from "effect/DateTime";

import {
  addTurnUsage,
  foldTurnUsage,
  promptCacheNextChangeMs,
  promptCacheRemainingLabel,
  promptCacheState,
  promptCacheWriterAlive,
  threadUsageFromProjection,
  threadUsageReported,
  turnUsageFromProviderTurn,
  type ThreadTurnUsage,
} from "./threadUsage.ts";

const turn = (id: string, overrides: Partial<ThreadTurnUsage> = {}): ThreadTurnUsage => ({
  turnId: id,
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

    const mixed = addTurnUsage(onlyUnreported, turn("t3"));
    expect(mixed).toMatchObject({ turns: 3, unreportedTurns: 2, inputTokens: 1000 });
    expect(threadUsageReported(mixed)).toBe(true);

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

const at = (iso: string) => DateTime.makeUnsafe(iso);

const providerTurn = (
  id: string,
  overrides: Partial<OrchestrationV2ProviderTurn> = {},
): OrchestrationV2ProviderTurn => ({
  id: ProviderTurnId.make(id),
  providerThreadId: ProviderThreadId.make("provider-thread-root"),
  nodeId: NodeId.make("node-root"),
  runAttemptId: null,
  nativeTurnRef: null,
  ordinal: 1,
  status: "completed",
  startedAt: at("2026-09-12T00:00:00.000Z"),
  completedAt: at("2026-09-12T00:01:30.000Z"),
  turnTokenUsage: {
    usageScope: "main_agent",
    usageStatus: "complete",
    hasSubagents: false,
    inputTokens: 1000,
    outputTokens: 200,
    cachedInputTokens: 800,
    cacheCreationTokens: 100,
    cacheTtlSeconds: 3600,
  },
  turnCostUsd: 0.25,
  turnModels: ["claude-opus-4-7"],
  toolCalls: 3,
  ...overrides,
});

describe("turnUsageFromProviderTurn (v2)", () => {
  it("reads a completed turn's tokens, cost, models, tool calls and wall time", () => {
    expect(turnUsageFromProviderTurn(providerTurn("p1"))).toEqual({
      turnId: "p1",
      model: "claude-opus-4-7",
      inputTokens: 1000,
      outputTokens: 200,
      cachedInputTokens: 800,
      cacheCreationTokens: 100,
      reasoningTokens: null,
      complete: true,
      hasSubagents: false,
      costUsd: 0.25,
      completedAt: "2026-09-12T00:01:30.000Z",
      toolCalls: 3,
      durationMs: 90_000,
      cacheTtlSeconds: 3600,
    });
  });

  it("names the run's model for a provider whose adapter names none", () => {
    const codex = turnUsageFromProviderTurn(
      providerTurn("p2", { turnModels: undefined, turnCostUsd: undefined }),
      { modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" } },
    );
    expect(codex?.model).toBe("gpt-5.4");
    expect(codex?.costUsd).toBeNull();
  });

  it("keeps a completed turn whose provider reported no usage, as unreported", () => {
    const grok = turnUsageFromProviderTurn(
      providerTurn("p3", { turnTokenUsage: undefined, turnModels: undefined, toolCalls: 7 }),
    );
    expect(grok).toMatchObject({ usageUnavailable: true, inputTokens: 0, toolCalls: 7 });
    // An interrupted turn without usage, or a running one, is not a turn to count.
    expect(
      turnUsageFromProviderTurn(
        providerTurn("p4", { status: "interrupted", turnTokenUsage: undefined }),
      ),
    ).toBeUndefined();
    expect(
      turnUsageFromProviderTurn(providerTurn("p5", { status: "running", completedAt: null })),
    ).toBeUndefined();
    // Interrupted with partial usage is still what the turn burned.
    expect(
      turnUsageFromProviderTurn(
        providerTurn("p6", {
          status: "interrupted",
          turnTokenUsage: {
            usageScope: "main_agent",
            usageStatus: "partial",
            hasSubagents: false,
            outputTokens: 5,
          },
        }),
      ),
    ).toMatchObject({ complete: false, outputTokens: 5, inputTokens: 0 });
  });
});

describe("threadUsageFromProjection (v2)", () => {
  const threadId = ThreadId.make("thread-usage");
  const rootProviderThread = {
    id: ProviderThreadId.make("provider-thread-root"),
    appThreadId: threadId,
    ownerNodeId: null,
  } as OrchestrationV2ProviderThread;
  const subagentProviderThread = {
    id: ProviderThreadId.make("provider-thread-sub"),
    appThreadId: threadId,
    ownerNodeId: NodeId.make("node-sub"),
  } as OrchestrationV2ProviderThread;
  const run = (id: string, status: OrchestrationV2Run["status"]) =>
    ({
      id: RunId.make(id),
      status,
      modelSelection: { instanceId: ProviderInstanceId.make("claude"), model: "opus" },
    }) as OrchestrationV2Run;
  const attempt = (id: string, runId: string) =>
    ({ id: RunAttemptId.make(id), runId: RunId.make(runId) }) as OrchestrationV2RunAttempt;
  const thread = (baseline?: OrchestrationV2AppThread["usageBaseline"]) =>
    ({ id: threadId, ...(baseline === undefined ? {} : { usageBaseline: baseline }) }) as OrchestrationV2AppThread;

  it("folds the root provider threads' terminal turns, oldest first, and skips subagents", () => {
    const usage = threadUsageFromProjection({
      thread: thread(),
      runs: [run("run-1", "completed"), run("run-2", "completed")],
      attempts: [attempt("attempt-1", "run-1"), attempt("attempt-2", "run-2")],
      providerThreads: [rootProviderThread, subagentProviderThread],
      providerTurns: [
        providerTurn("p2", {
          runAttemptId: RunAttemptId.make("attempt-2"),
          startedAt: at("2026-09-12T01:00:00.000Z"),
          completedAt: at("2026-09-12T01:00:10.000Z"),
          turnTokenUsage: undefined,
          turnModels: undefined,
          turnCostUsd: undefined,
        }),
        providerTurn("p1", { runAttemptId: RunAttemptId.make("attempt-1") }),
        providerTurn("sub", {
          providerThreadId: subagentProviderThread.id,
          nodeId: NodeId.make("node-sub-root"),
        }),
        providerTurn("live", { status: "running", completedAt: null }),
      ],
    });
    expect(usage).toMatchObject({
      source: "runtime",
      turns: 2,
      unreportedTurns: 1,
      inputTokens: 1000,
      costUsd: 0.25,
      models: ["claude-opus-4-7"],
      toolCalls: 6,
      durationMs: 100_000,
      lastTurnAt: "2026-09-12T01:00:10.000Z",
    });
    // The latest turn (a Codex one here) said nothing about the cache.
    expect(usage).not.toHaveProperty("cacheExpiresAt");
  });

  it("leaves out a rolled-back run's turns and folds onto the thread's baseline", () => {
    const baseline = {
      ...addTurnUsage(undefined, turn("v1", { costUsd: 1 })),
      source: "transcript" as const,
    };
    const usage = threadUsageFromProjection({
      thread: thread(baseline),
      runs: [run("run-1", "rolled_back"), run("run-2", "completed")],
      attempts: [attempt("attempt-1", "run-1"), attempt("attempt-2", "run-2")],
      providerThreads: [rootProviderThread],
      providerTurns: [
        providerTurn("p1", { runAttemptId: RunAttemptId.make("attempt-1") }),
        providerTurn("p2", {
          runAttemptId: RunAttemptId.make("attempt-2"),
          completedAt: at("2026-09-12T02:00:00.000Z"),
        }),
      ],
    });
    expect(usage).toMatchObject({ source: "transcript", turns: 2, costUsd: 1.25 });
    expect(usage?.cacheExpiresAt).toBe("2026-09-12T03:00:00.000Z");
    // Nothing recorded and no baseline is absence, never zero.
    expect(
      threadUsageFromProjection({
        thread: thread(),
        runs: [],
        attempts: [],
        providerThreads: [rootProviderThread],
        providerTurns: [],
      }),
    ).toBeUndefined();
  });
});

describe("prompt cache state", () => {
  const lastTurnAt = "2026-09-23T10:00:00.000Z";
  const hour = { lastTurnAt, cacheExpiresAt: "2026-09-23T11:00:00.000Z" };
  const fiveMinutes = { lastTurnAt, cacheExpiresAt: "2026-09-23T10:05:00.000Z" };
  const ms = (iso: string) => Date.parse(iso);

  it("is warm, then expiring in the last fifth of the TTL (at most 5 minutes), then cold", () => {
    expect(promptCacheState(hour, ms("2026-09-23T10:30:00.000Z"), true)?.kind).toBe("warm");
    expect(promptCacheState(hour, ms("2026-09-23T10:55:00.000Z"), true)?.kind).toBe("expiring");
    expect(promptCacheState(hour, ms("2026-09-23T11:00:00.000Z"), true)?.kind).toBe("cold");
    expect(promptCacheState(fiveMinutes, ms("2026-09-23T10:03:59.000Z"), true)?.kind).toBe("warm");
    expect(promptCacheState(fiveMinutes, ms("2026-09-23T10:04:00.000Z"), true)?.kind).toBe(
      "expiring",
    );
  });

  it("reads cold inside the TTL once the session that wrote the cache has ended", () => {
    expect(promptCacheState(hour, ms("2026-09-23T10:30:00.000Z"), false)).toEqual({
      kind: "cold",
      reason: "restart",
    });
    expect(promptCacheState(hour, ms("2026-09-23T11:00:00.000Z"), false)).toEqual({
      kind: "cold",
      reason: "expired",
    });
  });

  it("trusts only a ready session untouched since the last turn to hold the cache", () => {
    const session = (status: "ready" | "stopped" | "error", updatedAt: string) => ({
      status,
      updatedAt: at(updatedAt),
    });
    expect(promptCacheWriterAlive(session("ready", lastTurnAt), lastTurnAt)).toBe(true);
    expect(promptCacheWriterAlive(session("stopped", lastTurnAt), lastTurnAt)).toBe(false);
    expect(promptCacheWriterAlive(session("ready", "2026-09-23T10:12:00.000Z"), lastTurnAt)).toBe(
      false,
    );
    expect(promptCacheWriterAlive(null, lastTurnAt)).toBe(false);
  });

  it("says nothing for a thread whose last turn reported no TTL", () => {
    expect(promptCacheState({ lastTurnAt }, ms(lastTurnAt), true)).toBeNull();
  });

  it("rounds the minutes left down, so the label never overstates", () => {
    expect(promptCacheRemainingLabel(60 * 60_000)).toBe("1h");
    expect(promptCacheRemainingLabel(42 * 60_000 + 59_000)).toBe("42m");
    expect(promptCacheRemainingLabel(59_000)).toBe("<1m");
  });

  it("wakes just past each minute of the expiry's grid, and stops once cold", () => {
    const labelAfterWake = (nowIso: string) => {
      const nowMs = ms(nowIso);
      const wakeMs = nowMs + (promptCacheNextChangeMs(fiveMinutes.cacheExpiresAt, nowMs) ?? 0);
      const state = promptCacheState(fiveMinutes, wakeMs, true);
      return state?.kind === "cold" ? "cold" : promptCacheRemainingLabel(state?.remainingMs ?? 0);
    };
    expect(labelAfterWake("2026-09-23T10:00:20.000Z")).toBe("3m");
    expect(labelAfterWake("2026-09-23T10:01:00.000Z")).toBe("3m");
    expect(labelAfterWake("2026-09-23T10:03:30.000Z")).toBe("<1m");
    expect(labelAfterWake("2026-09-23T10:04:30.000Z")).toBe("cold");
    expect(promptCacheNextChangeMs(hour.cacheExpiresAt, ms("2026-09-23T11:00:00.000Z"))).toBeNull();
  });
});
