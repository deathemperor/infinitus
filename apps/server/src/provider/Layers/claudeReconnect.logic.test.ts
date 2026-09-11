import type { Options as ClaudeQueryOptions, SDKResultMessage } from "@anthropic-ai/claude-agent-sdk";
import { assert, describe, it } from "@effect/vitest";

import {
  isTransportErrorMessage,
  isTransportResult,
  RECONNECT_BACKOFF_MILLIS,
  RECONNECT_MAX_ATTEMPTS,
  reconnectQueryOptions,
  reconnectReason,
} from "./claudeReconnect.logic.ts";

function result(overrides: Record<string, unknown>): SDKResultMessage {
  return {
    type: "result",
    subtype: "success",
    duration_ms: 1,
    duration_api_ms: 1,
    is_error: false,
    num_turns: 1,
    result: "",
    session_id: "session-1",
    total_cost_usd: 0,
    usage: {},
    modelUsage: {},
    permission_denials: [],
    uuid: "uuid-1",
    ...overrides,
  } as unknown as SDKResultMessage;
}

describe("claudeReconnect.logic (#832)", () => {
  it("classifies socket-level messages as transport, not model or tool failures", () => {
    for (const text of [
      "read ECONNRESET",
      "getaddrinfo ENOTFOUND api.anthropic.com",
      "fetch failed",
      "socket hang up",
      "connect ETIMEDOUT 1.2.3.4:443",
    ]) {
      assert.isTrue(isTransportErrorMessage(text), text);
    }
    for (const text of [
      "Claude Code process exited with code 1",
      "Invalid API key",
      "tool_use input was not valid JSON",
      "",
    ]) {
      assert.isFalse(isTransportErrorMessage(text), text);
    }
  });

  it("treats repeated API errors and the 529 overload result as transport unless the turn knows better", () => {
    assert.isTrue(
      isTransportResult(
        result({ subtype: "error_during_execution", terminal_reason: "api_error", errors: [] }),
        undefined,
      ),
    );
    assert.isTrue(isTransportResult(result({ api_error_status: 529 }), undefined));
    assert.isFalse(
      isTransportResult(
        result({ subtype: "error_during_execution", terminal_reason: "api_error", errors: [] }),
        "Claude usage limit reached.",
      ),
    );
    assert.isFalse(
      isTransportResult(
        result({
          subtype: "error_during_execution",
          terminal_reason: "malformed_tool_use_exhausted",
          errors: [],
        }),
        undefined,
      ),
    );
    assert.isFalse(isTransportResult(result({}), undefined));
  });

  it("bounds the attempts by the backoff table and names each one", () => {
    assert.equal(RECONNECT_MAX_ATTEMPTS, RECONNECT_BACKOFF_MILLIS.length);
    assert.deepEqual([...RECONNECT_BACKOFF_MILLIS], [5_000, 15_000, 60_000, 180_000, 600_000]);
    assert.equal(reconnectReason(1), "reconnecting:1/5");
    assert.equal(reconnectReason(5), "reconnecting:5/5");
  });

  it("reopens on the reported session id, never a fresh or forked one", () => {
    const options = {
      cwd: "/repo",
      model: "claude-fable-5-1",
      sessionId: "generated-id",
      forkSession: true,
      resumeSessionAt: "uuid-9",
      includePartialMessages: true,
    } as unknown as ClaudeQueryOptions;
    assert.deepEqual(reconnectQueryOptions(options, "reported-id"), {
      cwd: "/repo",
      model: "claude-fable-5-1",
      includePartialMessages: true,
      resume: "reported-id",
    } as unknown as ClaudeQueryOptions);
  });
});
