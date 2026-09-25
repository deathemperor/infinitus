import { describe, it, expect } from "vite-plus/test";
import {
  activityCollector,
  emptyTranscriptActivity,
  summarizeStatsSession,
} from "./statsTranscripts.ts";
import { initialCodexScanState, parseCodexLine } from "../usage/usageTranscripts.ts";
import { createOverrideRateTable } from "../usage/usagePricing.ts";
import { parseStatsLog, statsRepositoryIdentity } from "./statsRepositories.ts";

const at = "2026-09-22T10:00:00Z";
const rates = createOverrideRateTable({
  "gpt-test": {
    inputCostPerMillionTokens: 2,
    outputCostPerMillionTokens: 10,
    cacheReadCostPerMillionTokens: 0.5,
  },
});
describe("Stats transcript activity", () => {
  it("counts a Codex turn once and prices cache/reasoning without double counting", () => {
    const observer = activityCollector(emptyTranscriptActivity());
    const state = initialCodexScanState();
    const lines = [
      { type: "session_meta", payload: { id: "s1", cwd: "/repo" } },
      { type: "turn_context", payload: { model: "gpt-test", effort: "high" } },
      { type: "event_msg", payload: { type: "user_message", message: "write tests" } },
      {
        type: "response_item",
        payload: {
          type: "function_call",
          name: "exec_command",
          call_id: "tool1",
          arguments: '{"cmd":"vp test"}',
        },
      },
      {
        type: "event_msg",
        payload: {
          type: "token_count",
          info: {
            last_token_usage: {
              input_tokens: 1000,
              cached_input_tokens: 600,
              output_tokens: 200,
              reasoning_output_tokens: 100,
            },
          },
        },
      },
      { type: "event_msg", payload: { type: "task_complete" } },
      { type: "event_msg", payload: { type: "task_complete" } },
    ].map((row) => JSON.stringify({ ...row, timestamp: at }));
    const records = lines.flatMap((line) => {
      const r = parseCodexLine(line, state);
      observer.line(line, "codex", state);
      return r ? [r] : [];
    });
    const result = summarizeStatsSession({
      id: "codex:s1",
      sourceId: "host",
      updatedAt: 1,
      activity: observer.finish(),
      records,
      provider: "codex",
      timeZone: "UTC",
      sinceDay: "2026-09-01",
      untilDay: "2026-09-30",
      rates,
      overrides: new Map(),
    });
    expect(result.days[0]?.day).toMatchObject({
      humanMessages: 1,
      turns: 1,
      inputTokens: 400,
      cacheReadTokens: 600,
      outputTokens: 200,
      toolCalls: { exec_command: 1 },
      byEffort: { high: { n: 1 } },
      activities: { tests: { n: 1 } },
    });
    expect(result.days[0]?.day.usd).toBeCloseTo(0.0031);
    expect(result.days[0]?.day.cacheSavingsUSD).toBeCloseTo(0.0009);
  });
  it("does not count subagent prompts as human activity and exposes unpriced usage", () => {
    const observer = activityCollector(emptyTranscriptActivity(true));
    observer.line(
      JSON.stringify({ type: "user", timestamp: at, message: { content: "do the work" } }),
      "claude",
      initialCodexScanState(),
    );
    const result = summarizeStatsSession({
      id: "child",
      sourceId: "host",
      updatedAt: 1,
      activity: observer.finish(),
      records: [
        {
          provider: "claude",
          timestampMs: Date.parse(at),
          model: "unknown",
          sessionId: "child",
          dedupeKey: null,
          reportedCostUsd: null,
          totals: {
            uncachedInputTokens: 100,
            cachedInputTokens: 0,
            cacheCreationTokens: 0,
            outputTokens: 20,
            reasoningTokens: 0,
          },
        },
      ],
      provider: "claude",
      timeZone: "UTC",
      sinceDay: "2026-09-01",
      untilDay: "2026-09-30",
      rates,
      overrides: new Map(),
    });
    expect(result.days[0]?.day.humanMessages ?? 0).toBe(0);
    expect(result.days[0]?.day.sessions ?? []).toHaveLength(0);
    expect(result.days[0]?.day.unpricedRecords).toBe(1);
  });
  it("parses repository counts and normalizes SSH/HTTPS clone identities", () => {
    const log =
      "\x1eabc\x1f2026-09-22T10:00:00Z\x1fme@example.com\x1fRevert feature\x1fClaude\n2\t3\ta.ts\n-\t-\tphoto.png\n";
    expect(parseStatsLog(log)).toEqual([
      {
        id: "abc",
        at: Date.parse(at),
        added: 2,
        removed: 3,
        files: 2,
        coAuthored: true,
        revert: true,
      },
    ]);
    expect(statsRepositoryIdentity("git@github.com:me/repo.git", "local")).toBe(
      statsRepositoryIdentity("https://github.com/me/repo.git", "local"),
    );
  });
});
