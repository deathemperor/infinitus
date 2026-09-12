import * as Schema from "effect/Schema";

import type { SlackInbound } from "../Services/InfinitusSlackClient.ts";

/**
 * Slack Socket Mode (#574, PR 4): the pure half. An envelope arrives as one
 * JSON text frame, is acknowledged by its id at once, and becomes at most
 * one `SlackInbound`: an `app_mention` event (a new task, or a reply when
 * it sits in a bound thread), a threaded user `message`, or a
 * `block_actions` button press. Everything else is dropped.
 */

const Envelope = Schema.Struct({
  type: Schema.String,
  envelope_id: Schema.optional(Schema.String),
  reason: Schema.optional(Schema.String),
  payload: Schema.optional(Schema.Unknown),
});

const EventsPayload = Schema.Struct({
  event: Schema.Struct({
    type: Schema.String,
    subtype: Schema.optional(Schema.String),
    bot_id: Schema.optional(Schema.String),
    user: Schema.optional(Schema.String),
    channel: Schema.optional(Schema.String),
    text: Schema.optional(Schema.String),
    ts: Schema.optional(Schema.String),
    thread_ts: Schema.optional(Schema.String),
  }),
});

const BlockActionsPayload = Schema.Struct({
  type: Schema.String,
  user: Schema.Struct({ id: Schema.String }),
  channel: Schema.optional(Schema.Struct({ id: Schema.String })),
  message: Schema.optional(
    Schema.Struct({ ts: Schema.String, thread_ts: Schema.optional(Schema.String) }),
  ),
  actions: Schema.Array(
    Schema.Struct({ action_id: Schema.String, value: Schema.optional(Schema.String) }),
  ),
});

const decodeEnvelope = Schema.decodeUnknownOption(Schema.fromJsonString(Envelope));
const decodeEvents = Schema.decodeUnknownOption(EventsPayload);
const decodeActions = Schema.decodeUnknownOption(BlockActionsPayload);
const encodeAck = Schema.encodeSync(
  Schema.fromJsonString(Schema.Struct({ envelope_id: Schema.String })),
);

export type SocketFrame =
  | { readonly kind: "hello" }
  | { readonly kind: "disconnect"; readonly reason: string }
  | { readonly kind: "envelope"; readonly ack: string; readonly inbound: SlackInbound | null }
  | { readonly kind: "ignored" };

/** Slack's `&`, `<`, `>` escapes and `<url|label>` links back to plain text. */
export function unescapeSlackText(text: string): string {
  return text
    .replace(/<(https?:\/\/[^|>]+)\|([^>]*)>/g, "$2")
    .replace(/<(https?:\/\/[^>]+)>/g, "$1")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

export function parseSocketFrame(raw: string): SocketFrame {
  const envelope = decodeEnvelope(raw);
  if (envelope._tag === "None") return { kind: "ignored" };
  const frame = envelope.value;
  if (frame.type === "hello") return { kind: "hello" };
  if (frame.type === "disconnect") return { kind: "disconnect", reason: frame.reason ?? "" };
  if (frame.envelope_id === undefined) return { kind: "ignored" };
  const envelopeId = frame.envelope_id;
  const ack = encodeAck({ envelope_id: envelopeId });
  const dropped: SocketFrame = { kind: "envelope", ack, inbound: null };
  if (frame.type === "events_api") {
    const payload = decodeEvents(frame.payload);
    if (payload._tag === "None") return dropped;
    const event = payload.value.event;
    if (!event.user || !event.channel || !event.ts || event.bot_id !== undefined) return dropped;
    const text = unescapeSlackText(event.text ?? "");
    if (event.type === "app_mention") {
      return {
        kind: "envelope",
        ack,
        inbound: {
          kind: "mention",
          envelopeId,
          channel: event.channel,
          threadTs: event.thread_ts ?? event.ts,
          userId: event.user,
          text,
        },
      };
    }
    if (event.type === "message" && event.subtype === undefined && event.thread_ts !== undefined) {
      return {
        kind: "envelope",
        ack,
        inbound: {
          kind: "reply",
          envelopeId,
          channel: event.channel,
          threadTs: event.thread_ts,
          userId: event.user,
          text,
        },
      };
    }
    return dropped;
  }
  if (frame.type === "interactive") {
    const payload = decodeActions(frame.payload);
    if (payload._tag === "None" || payload.value.type !== "block_actions") return dropped;
    const { channel, message, user, actions } = payload.value;
    const action = actions[0];
    if (channel === undefined || message === undefined || action === undefined) return dropped;
    return {
      kind: "envelope",
      ack,
      inbound: {
        kind: "action",
        envelopeId,
        channel: channel.id,
        threadTs: message.thread_ts ?? message.ts,
        userId: user.id,
        actionId: action.action_id,
        value: action.value ?? "",
      },
    };
  }
  return dropped;
}

/** Reconnect delays in seconds: 1, 2, 4 ... capped at 60; `hello` resets the count. */
export function reconnectDelaySeconds(attempt: number): number {
  return Math.min(60, 2 ** Math.max(0, Math.min(attempt, 6)));
}

/** What the reactor posts to the threads it was driving when the server shuts down cleanly. */
export const OFFLINE_TEXT = "Infinitus went offline.";
