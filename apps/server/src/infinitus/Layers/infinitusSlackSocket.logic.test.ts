import { describe, expect, it } from "vite-plus/test";

import {
  parseSocketFrame,
  reconnectDelaySeconds,
  unescapeSlackText,
} from "./infinitusSlackSocket.logic.ts";

const envelope = (type: string, payload: unknown, id = "e1") =>
  JSON.stringify({ type, envelope_id: id, payload });

describe("Socket Mode frames (#574)", () => {
  it("acks every envelope and turns a mention, a threaded reply and a button into inbound events", () => {
    const mention = parseSocketFrame(
      envelope("events_api", {
        event: {
          type: "app_mention",
          user: "U1",
          channel: "C1",
          ts: "1.1",
          text: "<@UB> site do &lt;it&gt;",
        },
      }),
    );
    expect(mention).toEqual({
      kind: "envelope",
      ack: '{"envelope_id":"e1"}',
      inbound: {
        kind: "mention",
        envelopeId: "e1",
        channel: "C1",
        threadTs: "1.1",
        ts: "1.1",
        userId: "U1",
        text: "<@UB> site do <it>",
      },
    });
    const reply = parseSocketFrame(
      envelope(
        "events_api",
        {
          event: {
            type: "message",
            user: "U1",
            channel: "C1",
            ts: "1.2",
            thread_ts: "1.1",
            text: "more",
          },
        },
        "e2",
      ),
    );
    expect(reply).toMatchObject({
      inbound: { kind: "reply", threadTs: "1.1", ts: "1.2", text: "more" },
    });
    const action = parseSocketFrame(
      envelope(
        "interactive",
        {
          type: "block_actions",
          user: { id: "U1" },
          channel: { id: "C1" },
          message: { ts: "1.3", thread_ts: "1.1" },
          actions: [{ action_id: "infinitus:approval:t:r", value: "accept" }],
        },
        "e3",
      ),
    );
    expect(action).toMatchObject({
      inbound: {
        kind: "action",
        threadTs: "1.1",
        actionId: "infinitus:approval:t:r",
        value: "accept",
      },
    });
  });

  it("drops bot messages, top-level messages and edits, but still acks them", () => {
    const bot = parseSocketFrame(
      envelope("events_api", {
        event: {
          type: "message",
          bot_id: "B1",
          user: "U1",
          channel: "C1",
          ts: "1",
          thread_ts: "1.1",
          text: "x",
        },
      }),
    );
    expect(bot).toMatchObject({ kind: "envelope", inbound: null });
    const top = parseSocketFrame(
      envelope("events_api", {
        event: { type: "message", user: "U1", channel: "C1", ts: "1", text: "x" },
      }),
    );
    expect(top).toMatchObject({ inbound: null });
    const edit = parseSocketFrame(
      envelope("events_api", {
        event: {
          type: "message",
          subtype: "message_changed",
          user: "U1",
          channel: "C1",
          ts: "1",
          thread_ts: "1.1",
        },
      }),
    );
    expect(edit).toMatchObject({ inbound: null });
  });

  it("recognises hello, disconnect and garbage", () => {
    expect(parseSocketFrame('{"type":"hello"}')).toEqual({ kind: "hello" });
    expect(parseSocketFrame('{"type":"disconnect","reason":"refresh_requested"}')).toEqual({
      kind: "disconnect",
      reason: "refresh_requested",
    });
    expect(parseSocketFrame("not json")).toEqual({ kind: "ignored" });
    expect(unescapeSlackText("see <https://x.y/pr/1|PR 1> &amp; <https://a.b>")).toBe(
      "see PR 1 & https://a.b",
    );
  });

  it("backs off to a minute and no further", () => {
    expect([0, 1, 2, 3, 6, 9].map(reconnectDelaySeconds)).toEqual([1, 2, 4, 8, 60, 60]);
  });
});
