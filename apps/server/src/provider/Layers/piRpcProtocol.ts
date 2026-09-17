/**
 * Pi RPC wire protocol — framing and the event/response shapes the adapter
 * reads.
 *
 * Pi speaks its own JSONL RPC over stdio (`pi --mode rpc`), not ACP. Commands
 * go in on stdin one JSON object per line; responses and events come back on
 * stdout the same way.
 *
 * @module provider/Layers/piRpcProtocol
 */
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Splits a JSONL stream on LF alone.
 *
 * Pi's `rpc.md` calls this out as a protocol requirement rather than a
 * preference: U+2028 and U+2029 are legal inside JSON strings, so a reader
 * that treats them as terminators (Node's `readline` does) splits a record in
 * half and corrupts it. A trailing CR is stripped, but a lone CR is *not* a
 * terminator — only LF is.
 *
 * Returns the completed lines plus whatever trailing partial record is still
 * waiting for its LF, which the caller feeds back in as `carry` next time.
 */
export function splitPiRpcLines(
  carry: string,
  chunk: string,
): { readonly lines: ReadonlyArray<string>; readonly carry: string } {
  let buffer = carry + chunk;
  const lines: Array<string> = [];
  let newlineIndex = buffer.indexOf("\n");
  while (newlineIndex !== -1) {
    const line = buffer.slice(0, newlineIndex);
    buffer = buffer.slice(newlineIndex + 1);
    // A CR immediately before the LF is framing, not payload.
    const trimmed = line.endsWith("\r") ? line.slice(0, -1) : line;
    if (trimmed.length > 0) lines.push(trimmed);
    newlineIndex = buffer.indexOf("\n");
  }
  return { lines, carry: buffer };
}

/** Serializes one command as a strict JSONL record. */
export function serializePiRpcCommand(command: unknown): string {
  return `${JSON.stringify(command)}\n`;
}

const PiUsage = Schema.Struct({
  input: Schema.optional(Schema.Number),
  output: Schema.optional(Schema.Number),
  cacheRead: Schema.optional(Schema.Number),
  cacheWrite: Schema.optional(Schema.Number),
  reasoning: Schema.optional(Schema.Number),
  totalTokens: Schema.optional(Schema.Number),
  cost: Schema.optional(
    Schema.Struct({
      total: Schema.optional(Schema.Number),
    }),
  ),
});
export type PiUsage = typeof PiUsage.Type;

/**
 * Pi's own message shape, kept deliberately loose: only the fields the adapter
 * reads are named, because Pi is pre-1.0 and adds content block kinds between
 * releases. An unknown block must not fail the decode and drop the message.
 */
const PiMessage = Schema.Struct({
  role: Schema.String,
  content: Schema.optional(Schema.Unknown),
  api: Schema.optional(Schema.String),
  provider: Schema.optional(Schema.String),
  model: Schema.optional(Schema.String),
  usage: Schema.optional(PiUsage),
  stopReason: Schema.optional(Schema.String),
  errorMessage: Schema.optional(Schema.String),
  toolCallId: Schema.optional(Schema.String),
  toolName: Schema.optional(Schema.String),
  isError: Schema.optional(Schema.Boolean),
});
export type PiMessage = typeof PiMessage.Type;

/**
 * The delta kinds that ride inside `message_update`.
 *
 * Thinking and text are SEPARATE streams on their own `contentIndex` values,
 * and a reader that accumulates any `delta` it sees glues the model's private
 * reasoning onto its answer. Route on this `type`, never on `contentIndex`.
 */
const PiAssistantMessageEvent = Schema.Struct({
  type: Schema.String,
  contentIndex: Schema.optional(Schema.Number),
  delta: Schema.optional(Schema.String),
  content: Schema.optional(Schema.String),
  id: Schema.optional(Schema.String),
  toolName: Schema.optional(Schema.String),
  toolCall: Schema.optional(Schema.Unknown),
});
export type PiAssistantMessageEvent = typeof PiAssistantMessageEvent.Type;

const PiToolResult = Schema.Struct({
  content: Schema.optional(Schema.Unknown),
  details: Schema.optional(Schema.Unknown),
});

/**
 * The records the adapter reads by name.
 *
 * `response` is the command acknowledgement and always arrives before the
 * events its command triggers. Everything else is an event.
 */
const PiKnownRecord = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("response"),
    id: Schema.optional(Schema.String),
    command: Schema.String,
    success: Schema.Boolean,
    error: Schema.optional(Schema.String),
    data: Schema.optional(Schema.Unknown),
  }),
  Schema.Struct({
    type: Schema.Literal("message_update"),
    usage: Schema.optional(PiUsage),
    assistantMessageEvent: PiAssistantMessageEvent,
  }),
  Schema.Struct({
    type: Schema.Literals(["message_start", "message_end"]),
    message: PiMessage,
  }),
  Schema.Struct({
    type: Schema.Literal("turn_end"),
    message: Schema.optional(PiMessage),
  }),
  Schema.Struct({
    type: Schema.Literal("agent_end"),
    willRetry: Schema.optional(Schema.Boolean),
  }),
  Schema.Struct({
    type: Schema.Literal("tool_execution_start"),
    toolCallId: Schema.String,
    toolName: Schema.String,
    args: Schema.optional(Schema.Unknown),
  }),
  Schema.Struct({
    type: Schema.Literal("tool_execution_update"),
    toolCallId: Schema.String,
    toolName: Schema.String,
    args: Schema.optional(Schema.Unknown),
    partialResult: Schema.optional(Schema.Unknown),
  }),
  Schema.Struct({
    type: Schema.Literal("tool_execution_end"),
    toolCallId: Schema.String,
    toolName: Schema.String,
    result: Schema.optional(PiToolResult),
    isError: Schema.optional(Schema.Boolean),
  }),
  Schema.Struct({
    type: Schema.Literals(["compaction_start", "compaction_end"]),
    reason: Schema.optional(Schema.String),
    aborted: Schema.optional(Schema.Boolean),
    errorMessage: Schema.optional(Schema.String),
  }),
  Schema.Struct({
    type: Schema.Literal("auto_retry_start"),
    attempt: Schema.optional(Schema.Number),
    maxAttempts: Schema.optional(Schema.Number),
    errorMessage: Schema.optional(Schema.String),
  }),
  Schema.Struct({
    type: Schema.Literal("extension_error"),
    error: Schema.optional(Schema.String),
  }),
  // Lifecycle events that carry nothing the adapter reads beyond their name.
  Schema.Struct({
    type: Schema.Literals(["agent_start", "agent_settled", "turn_start"]),
  }),
]);
export type PiKnownRecord = typeof PiKnownRecord.Type;

/**
 * A record whose `type` this build does not know.
 *
 * Pi is pre-1.0 and adds events between releases, so an unknown one must
 * decode rather than fail the stream — dropping the line would take the
 * turn's own completion event with it. The name is deliberately NOT `type`:
 * an arm typed `{ type: string }` overlaps every literal arm and silently
 * defeats discriminated narrowing on the union, so the compiler stops
 * catching a misread field.
 */
export interface PiUnrecognizedRecord {
  readonly unrecognizedType: string;
}

export type PiRpcRecord = PiKnownRecord | PiUnrecognizedRecord;

const decodeKnownRecord = Schema.decodeUnknownOption(PiKnownRecord);
const decodeUnrecognizedRecord = Schema.decodeUnknownOption(Schema.Struct({ type: Schema.String }));

/** Decodes one record, falling back to {@link PiUnrecognizedRecord}. */
export function decodePiRpcRecord(value: unknown): Option.Option<PiRpcRecord> {
  const known = decodeKnownRecord(value);
  if (Option.isSome(known)) return known;
  return Option.map(decodeUnrecognizedRecord(value), (record): PiRpcRecord => ({
    unrecognizedType: record.type,
  }));
}

/**
 * Text content of a Pi message, ignoring thinking and tool-call blocks.
 */
export function piMessageText(message: PiMessage): string {
  if (!Array.isArray(message.content)) return "";
  let text = "";
  for (const block of message.content) {
    if (
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string"
    ) {
      text += (block as { text: string }).text;
    }
  }
  return text;
}

/**
 * Maps a Pi tool name onto the canonical item type the UI renders.
 *
 * Pi's built-in set is fixed (`packages/coding-agent/src/core/tools`); an
 * extension-provided tool falls through to the generic bucket.
 */
export function piCanonicalItemType(
  toolName: string,
): "command_execution" | "file_change" | "dynamic_tool_call" {
  switch (toolName) {
    case "bash":
    case "powershell":
      return "command_execution";
    case "edit":
    case "write":
      return "file_change";
    default:
      return "dynamic_tool_call";
  }
}
