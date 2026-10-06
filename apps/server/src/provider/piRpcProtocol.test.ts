import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";

import {
  decodePiRpcRecord,
  piCanonicalItemType,
  piMessageText,
  serializePiRpcCommand,
  splitPiRpcLines,
} from "./piRpcProtocol.ts";

describe("splitPiRpcLines", () => {
  it("splits on LF and carries the trailing partial record", () => {
    const first = splitPiRpcLines("", '{"a":1}\n{"b":2}\n{"c":');
    expect(first.lines).toEqual(['{"a":1}', '{"b":2}']);
    expect(first.carry).toBe('{"c":');

    const second = splitPiRpcLines(first.carry, "3}\n");
    expect(second.lines).toEqual(['{"c":3}']);
    expect(second.carry).toBe("");
  });

  it("keeps U+2028 and U+2029 inside a record", () => {
    // Pi's rpc.md names this as the reason not to use Node `readline`: both are
    // legal inside a JSON string, and splitting on them cuts a record in half.
    const payload = JSON.stringify({ text: "before\u2028middle\u2029after" });
    const { lines, carry } = splitPiRpcLines("", `${payload}\n`);
    expect(lines).toEqual([payload]);
    expect(carry).toBe("");
    expect(JSON.parse(lines[0]!).text).toBe("before\u2028middle\u2029after");
  });

  it("treats a lone CR as payload and strips only the CR of a CRLF pair", () => {
    const { lines } = splitPiRpcLines("", '{"a":"x\ry"}\r\n');
    expect(lines).toEqual(['{"a":"x\ry"}']);
  });

  it("drops empty records rather than emitting blank lines", () => {
    expect(splitPiRpcLines("", "\n\n").lines).toEqual([]);
  });
});

describe("serializePiRpcCommand", () => {
  it("emits exactly one LF-terminated record", () => {
    expect(serializePiRpcCommand({ type: "abort" })).toBe('{"type":"abort"}\n');
  });
});

describe("decodePiRpcRecord", () => {
  it("decodes a command acknowledgement", () => {
    const decoded = decodePiRpcRecord({
      id: "r1",
      type: "response",
      command: "prompt",
      success: true,
    });
    expect(Option.isSome(decoded)).toBe(true);
    expect(Option.getOrThrow(decoded)).toMatchObject({ type: "response", success: true });
  });

  it("decodes a failed acknowledgement with its error prose", () => {
    const decoded = Option.getOrThrow(
      decodePiRpcRecord({
        type: "response",
        command: "prompt",
        success: false,
        error: "Model not found: invalid/model",
      }),
    );
    expect(decoded).toMatchObject({ success: false, error: "Model not found: invalid/model" });
  });

  it("keeps thinking and text deltas distinguishable", () => {
    const thinking = Option.getOrThrow(
      decodePiRpcRecord({
        type: "message_update",
        assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "hmm" },
      }),
    );
    const text = Option.getOrThrow(
      decodePiRpcRecord({
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", contentIndex: 1, delta: "answer" },
      }),
    );
    expect(thinking).toMatchObject({ assistantMessageEvent: { type: "thinking_delta" } });
    expect(text).toMatchObject({ assistantMessageEvent: { type: "text_delta" } });
  });

  it("decodes an unrecognized event rather than failing the stream", () => {
    // Pi is pre-1.0 and adds events between releases; an unknown one must not
    // take down the reader that is also carrying the turn's completion.
    const decoded = decodePiRpcRecord({ type: "some_future_event", detail: 1 });
    expect(Option.isSome(decoded)).toBe(true);
  });

  it("decodes a tool execution pair", () => {
    const start = Option.getOrThrow(
      decodePiRpcRecord({
        type: "tool_execution_start",
        toolCallId: "call_1",
        toolName: "write",
        args: { path: "a.txt" },
      }),
    );
    const end = Option.getOrThrow(
      decodePiRpcRecord({
        type: "tool_execution_end",
        toolCallId: "call_1",
        toolName: "write",
        result: { content: [{ type: "text", text: "ok" }] },
        isError: false,
      }),
    );
    expect(start).toMatchObject({ toolCallId: "call_1", toolName: "write" });
    expect(end).toMatchObject({ toolCallId: "call_1", isError: false });
  });
});

describe("piMessageText", () => {
  it("reads text blocks and ignores thinking and tool calls", () => {
    expect(
      piMessageText({
        role: "assistant",
        content: [
          { type: "thinking", thinking: "private" },
          { type: "text", text: "visible" },
          { type: "toolCall", id: "c1", name: "write" },
        ],
      }),
    ).toBe("visible");
  });

  it("returns empty for a message with no content array", () => {
    expect(piMessageText({ role: "assistant" })).toBe("");
  });
});

describe("piCanonicalItemType", () => {
  it("maps Pi's built-in tools onto canonical item types", () => {
    expect(piCanonicalItemType("bash")).toBe("command_execution");
    expect(piCanonicalItemType("powershell")).toBe("command_execution");
    expect(piCanonicalItemType("write")).toBe("file_change");
    expect(piCanonicalItemType("edit")).toBe("file_change");
    expect(piCanonicalItemType("read")).toBe("dynamic_tool_call");
  });

  it("falls back to the generic bucket for an extension tool", () => {
    expect(piCanonicalItemType("some_extension_tool")).toBe("dynamic_tool_call");
  });
});

it("keeps the separator fixtures written as escapes, not raw characters", async () => {
  // U+2028/U+2029 are invisible: pasted raw into a fixture they survive a run
  // but not always an editor, a formatter or a review. The escapes above
  // produce the identical runtime string, so this asserts the SOURCE spelling.
  const NodeFSP = await import("node:fs/promises");
  const NodeURL = await import("node:url");
  const sources = await Promise.all(
    ["./piRpcProtocol.test.ts", "./PiAdapter.test.ts", "../../../scripts/pi-rpc-mock-agent.ts"].map(
      (relative) =>
        NodeFSP.readFile(NodeURL.fileURLToPath(new URL(relative, import.meta.url)), "utf8"),
    ),
  );
  for (const source of sources) {
    expect(source).not.toMatch(/[\u2028\u2029]/u);
  }
});
