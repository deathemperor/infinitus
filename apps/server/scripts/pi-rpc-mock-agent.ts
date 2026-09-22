#!/usr/bin/env node
// @effect-diagnostics nodeBuiltinImport:off preferSchemaOverJson:off globalTimers:off - a plain Node script standing in for the `pi` binary; it runs outside any Effect runtime.
/**
 * Mock `pi --mode rpc` agent.
 *
 * Pi's RPC protocol is not ACP, so `acp-mock-agent.ts` cannot stand in for it.
 *
 * This mock reproduces the real binary's shape as observed live, not an
 * idealized version of it — the single most expensive bug on the Oh My Pi
 * branch came from a fake that encoded a different assumption than the CLI,
 * so the suite stayed green while the live path was broken. In particular:
 *
 *   - `message_update` is DELTA-ONLY. No cumulative `message`, no `partial`.
 *   - thinking and text are separate streams on separate `contentIndex`
 *     values, and a real run carries far more thinking than text.
 *   - `message_start`/`message_end` are echoed for the USER message and for
 *     tool results, not only for assistant output.
 *   - a tool-using prompt emits TWO `turn_start`/`turn_end` pairs.
 *   - `agent_end` precedes `agent_settled`; only the latter means Pi stopped.
 *   - `abort` is acknowledged only after the turn has wound down, and a
 *     prompt sent before `agent_settled` is refused as already processing.
 */
import * as NodeFS from "node:fs";

const argvLogPath = process.env.T3_PI_ARGV_LOG_PATH;
const emitToolCall = process.env.T3_PI_EMIT_TOOL_CALL === "1";
const emitThinking = process.env.T3_PI_EMIT_THINKING === "1";
const failPrompt = process.env.T3_PI_FAIL_PROMPT === "1";
const exitOnPrompt = process.env.T3_PI_EXIT_ON_PROMPT === "1";
const hangPrompt = process.env.T3_PI_HANG_PROMPT === "1";
/** Ends the assistant message with `stopReason: "error"`, the way a model
 * API failure does; `agent_settled` still follows. */
const errorStop = process.env.T3_PI_ERROR_STOP === "1";
const stderrMessage = process.env.T3_PI_STDERR_MESSAGE;
const responseText = process.env.T3_PI_RESPONSE_TEXT ?? "DONE";
/** Emits a payload containing U+2028, which a non-LF-only reader corrupts. */
const emitSeparatorText = process.env.T3_PI_EMIT_SEPARATOR_TEXT === "1";
/** Emits one more assistant delta AFTER `agent_settled`, the way a real
 * session does when an extension speaks once the turn has already closed. */
const emitTrailingText = process.env.T3_PI_EMIT_TRAILING_TEXT === "1";

if (argvLogPath) {
  NodeFS.appendFileSync(argvLogPath, `${process.argv.slice(2).join("\t")}\n`);
}
if (stderrMessage) {
  process.stderr.write(`${stderrMessage}\n`);
}

const write = (value: unknown) => {
  process.stdout.write(`${JSON.stringify(value)}\n`);
};

const usage = {
  input: 10,
  output: 2,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 12,
  cost: { total: 0 },
};

const userMessage = (text: string) => ({
  role: "user",
  content: [{ type: "text", text }],
  timestamp: 1_700_000_000_000,
});

const assistantHeader = () => ({
  role: "assistant",
  content: [],
  api: "openai-completions",
  provider: "mock",
  model: "mock/model-1",
  usage,
  stopReason: "pending",
});

let aborted = false;
let running = false;

const emitAssistantText = (text: string) => {
  write({ type: "message_start", message: assistantHeader() });
  if (emitThinking) {
    // Real runs are reasoning-dominated; the ratio is the point of the fixture.
    write({
      type: "message_update",
      usage,
      assistantMessageEvent: { type: "thinking_start", contentIndex: 0 },
    });
    for (const piece of ["Considering ", "the ", "request"]) {
      write({
        type: "message_update",
        usage,
        assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: piece },
      });
    }
    write({
      type: "message_update",
      usage,
      assistantMessageEvent: {
        type: "thinking_end",
        contentIndex: 0,
        content: "Considering the request",
      },
    });
  }
  const contentIndex = emitThinking ? 1 : 0;
  write({
    type: "message_update",
    usage,
    assistantMessageEvent: { type: "text_start", contentIndex },
  });
  write({
    type: "message_update",
    usage,
    assistantMessageEvent: { type: "text_delta", contentIndex, delta: text },
  });
  write({
    type: "message_update",
    usage,
    assistantMessageEvent: { type: "text_end", contentIndex, content: text },
  });
  write({
    type: "message_end",
    message: {
      ...assistantHeader(),
      content: [{ type: "text", text }],
      stopReason: aborted ? "aborted" : errorStop ? "error" : "stop",
      ...(errorStop && !aborted ? { errorMessage: "401 invalid api key" } : {}),
    },
  });
};

const runPrompt = (message: string, imageCount: number) => {
  running = true;
  aborted = false;
  write({ type: "agent_start" });
  write({ type: "turn_start" });
  write({ type: "message_start", message: userMessage(message) });
  write({ type: "message_end", message: userMessage(message) });

  if (emitToolCall) {
    const toolCallId = "call_mock_1";
    write({ type: "message_start", message: assistantHeader() });
    write({
      type: "message_update",
      usage,
      assistantMessageEvent: {
        type: "toolcall_start",
        contentIndex: 0,
        id: toolCallId,
        toolName: "write",
      },
    });
    write({
      type: "message_end",
      message: {
        ...assistantHeader(),
        content: [
          { type: "toolCall", id: toolCallId, name: "write", arguments: { path: "a.txt" } },
        ],
        stopReason: "toolUse",
      },
    });
    write({
      type: "tool_execution_start",
      toolCallId,
      toolName: "write",
      args: { path: "a.txt", content: "mock" },
    });
    write({
      type: "tool_execution_end",
      toolCallId,
      toolName: "write",
      result: { content: [{ type: "text", text: "Successfully wrote to a.txt" }] },
      isError: false,
    });
    write({
      type: "message_start",
      message: { role: "toolResult", toolCallId, toolName: "write", isError: false },
    });
    write({
      type: "message_end",
      message: { role: "toolResult", toolCallId, toolName: "write", isError: false },
    });
    // The real binary closes the tool turn and opens a second one for the reply.
    write({ type: "turn_end" });
    write({ type: "turn_start" });
  }

  emitAssistantText(
    emitSeparatorText
      ? `${responseText}\u2028tail`
      : imageCount > 0
        ? `IMAGES:${imageCount}`
        : responseText,
  );
  write({ type: "turn_end" });
  write({ type: "agent_end", willRetry: false });
  write({ type: "agent_settled" });
  running = false;
  if (emitTrailingText) {
    setTimeout(() => {
      write({
        type: "message_update",
        usage,
        assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "TRAILING" },
      });
    }, 20);
  }
};

let buffer = "";
process.stdin.on("data", (chunk: Buffer) => {
  buffer += chunk.toString("utf8");
  let index = buffer.indexOf("\n");
  while (index !== -1) {
    const line = buffer.slice(0, index).replace(/\r$/, "");
    buffer = buffer.slice(index + 1);
    if (line.trim().length > 0) handleLine(line);
    index = buffer.indexOf("\n");
  }
});

function handleLine(line: string) {
  let command: { id?: string; type?: string; message?: string; images?: Array<unknown> };
  try {
    command = JSON.parse(line);
  } catch (error) {
    write({
      type: "response",
      command: "parse",
      success: false,
      error: `Failed to parse command: ${String(error)}`,
    });
    return;
  }

  switch (command.type) {
    case "prompt": {
      if (failPrompt) {
        write({
          id: command.id,
          type: "response",
          command: "prompt",
          success: false,
          error: 'Model "mock/model-1" not found.',
        });
        return;
      }
      if (exitOnPrompt) {
        process.exit(3);
      }
      if (running) {
        write({
          id: command.id,
          type: "response",
          command: "prompt",
          success: false,
          error: "Agent is already processing.",
        });
        return;
      }
      write({ id: command.id, type: "response", command: "prompt", success: true });
      // Only the first prompt hangs, so a test can prompt again after aborting it.
      if (hangPrompt && !aborted) {
        running = true;
        return;
      }
      runPrompt(command.message ?? "", command.images?.length ?? 0);
      return;
    }
    case "abort": {
      aborted = true;
      if (running) {
        // Streaming stops at once, but Pi stays busy until `agent_settled`
        // and acknowledges `abort` only after it, so the response comes last.
        emitAssistantText("");
        setTimeout(() => {
          write({ type: "turn_end" });
          write({ type: "agent_end", willRetry: false });
          write({ type: "agent_settled" });
          running = false;
          write({ id: command.id, type: "response", command: "abort", success: true });
        }, 150);
        return;
      }
      write({ id: command.id, type: "response", command: "abort", success: true });
      return;
    }
    case "compact": {
      write({ type: "compaction_start", reason: "manual" });
      write({ type: "compaction_end", reason: "manual", aborted: false });
      write({ id: command.id, type: "response", command: "compact", success: true });
      return;
    }
    default: {
      write({
        id: command.id,
        type: "response",
        command: command.type ?? "unknown",
        success: false,
        error: `Unknown command: ${command.type}`,
      });
    }
  }
}

process.stdin.resume();
