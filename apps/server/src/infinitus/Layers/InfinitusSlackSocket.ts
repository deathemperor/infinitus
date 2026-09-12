import * as Deferred from "effect/Deferred";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { HttpClient, HttpClientRequest } from "effect/unstable/http";

import { ServerSettingsService } from "../../serverSettings.ts";
import {
  SlackClient,
  SlackPostError,
  type SlackInbound,
  type SlackPost,
} from "../Services/InfinitusSlackClient.ts";
import { parseSocketFrame, reconnectDelaySeconds } from "./infinitusSlackSocket.logic.ts";

/**
 * Slack Socket Mode client (#574, PR 4): fills `SlackClient` with a live
 * connection. While the setting is on and both tokens exist it asks
 * `apps.connections.open` for a socket URL with the app-level token, opens
 * it with Node's global WebSocket, acks every envelope at once and hands the
 * translated events to the reactor; a `disconnect` frame, a close or an
 * error reconnects with backoff (1 s doubling to 60 s, reset on `hello`).
 * A settings change restarts the loop. Posts go to `chat.postMessage` with
 * the bot token. Tokens travel in headers only: never in argv, a log line
 * or a span; the log carries connection state and Slack's error words.
 */

const SLACK_API = "https://slack.com/api";

const OpenReply = Schema.Struct({
  ok: Schema.Boolean,
  url: Schema.optional(Schema.String),
  error: Schema.optional(Schema.String),
});
const PostReply = Schema.Struct({
  ok: Schema.Boolean,
  ts: Schema.optional(Schema.String),
  error: Schema.optional(Schema.String),
});

interface SlackArming {
  readonly enabled: boolean;
  readonly appToken: string;
  readonly botToken: string;
}

export const SlackClientLive = Layer.effect(SlackClient)(
  Effect.gen(function* () {
    const settings = yield* ServerSettingsService;
    const http = yield* HttpClient.HttpClient;
    const inbound = yield* PubSub.unbounded<SlackInbound>();

    const slackCall = <A>(
      method: string,
      token: string,
      body: Record<string, unknown>,
      decode: (reply: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ): Effect.Effect<A, SlackPostError> =>
      HttpClientRequest.post(`${SLACK_API}/${method}`).pipe(
        HttpClientRequest.setHeader("Authorization", `Bearer ${token}`),
        HttpClientRequest.bodyJsonUnsafe(body),
        http.execute,
        Effect.flatMap((response) => response.json),
        Effect.flatMap(decode),
        Effect.mapError((error) => new SlackPostError({ reason: String(error) })),
      );
    const decodeOpen = Schema.decodeUnknownEffect(OpenReply);
    const decodePost = Schema.decodeUnknownEffect(PostReply);

    const post = (input: SlackPost) =>
      Effect.gen(function* () {
        const current = yield* settings.getSettings.pipe(
          Effect.mapError(() => new SlackPostError({ reason: "settings unavailable" })),
        );
        const token = current.infinitusSlack.botToken;
        if (token.length === 0) return yield* new SlackPostError({ reason: "no bot token" });
        const reply = yield* slackCall(
          "chat.postMessage",
          token,
          {
            channel: input.channel,
            ...(input.threadTs === undefined ? {} : { thread_ts: input.threadTs }),
            text: input.text,
            ...(input.blocks === undefined ? {} : { blocks: input.blocks }),
          },
          decodePost,
        );
        if (!reply.ok || reply.ts === undefined) {
          return yield* new SlackPostError({ reason: reply.error ?? "not ok" });
        }
        return { ts: reply.ts };
      });

    /** One socket: resolves when it closes, with whether `hello` arrived. */
    const runSocket = (url: string) =>
      Effect.gen(function* () {
        const closed = yield* Deferred.make<boolean>();
        let greeted = false;
        const socket = new WebSocket(url);
        const finish = () => {
          Deferred.doneUnsafe(closed, Effect.succeed(greeted));
        };
        socket.addEventListener("message", (message) => {
          const frame = parseSocketFrame(String(message.data));
          switch (frame.kind) {
            case "hello":
              greeted = true;
              return;
            case "disconnect":
              socket.close();
              return;
            case "envelope":
              socket.send(frame.ack);
              if (frame.inbound !== null) Effect.runFork(PubSub.publish(inbound, frame.inbound));
              return;
            case "ignored":
              return;
          }
        });
        socket.addEventListener("error", finish, { once: true });
        socket.addEventListener("close", finish, { once: true });
        yield* Effect.addFinalizer(() => Effect.sync(() => socket.close()));
        return yield* Deferred.await(closed);
      }).pipe(Effect.scoped);

    const connectLoop = (appToken: string) =>
      Effect.gen(function* () {
        let attempt = 0;
        while (true) {
          const opened = yield* slackCall("apps.connections.open", appToken, {}, decodeOpen).pipe(
            Effect.option,
          );
          const url = opened._tag === "Some" && opened.value.ok ? opened.value.url : undefined;
          if (url !== undefined) {
            yield* Effect.logInfo("infinitus.slack.socket.connecting", { attempt });
            const greeted = yield* runSocket(url);
            if (greeted) attempt = 0;
            yield* Effect.logInfo("infinitus.slack.socket.closed", { greeted });
          } else {
            yield* Effect.logWarning("infinitus.slack.socket.open-failed", {
              error: opened._tag === "Some" ? (opened.value.error ?? "not ok") : "request failed",
            });
          }
          yield* Effect.sleep(Duration.seconds(reconnectDelaySeconds(attempt)));
          attempt += 1;
        }
      });

    // One loop at a time, restarted on every settings change that matters.
    let running: Fiber.Fiber<void> | undefined;
    let key = "";
    const reconcile = (current: { readonly infinitusSlack: SlackArming }) =>
      Effect.gen(function* () {
        const slack = current.infinitusSlack;
        const armed = slack.enabled && slack.appToken.length > 0 && slack.botToken.length > 0;
        const next = armed ? `${slack.appToken} ${slack.botToken}` : "";
        if (next === key) return;
        key = next;
        if (running !== undefined) {
          yield* Fiber.interrupt(running);
          running = undefined;
        }
        if (!armed) return yield* Effect.logInfo("infinitus.slack.socket.off");
        running = yield* Effect.forkScoped(connectLoop(slack.appToken));
      });

    // Subscribed before the first read, so a token saved while the server boots is not missed.
    yield* Effect.forkScoped(
      Effect.gen(function* () {
        const changes = yield* settings.subscribeChanges;
        yield* settings.getSettings.pipe(Effect.flatMap(reconcile));
        yield* changes.pipe(Stream.runForEach(reconcile));
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.slack.socket.settings", { cause }),
        ),
      ),
    );

    return SlackClient.of({ inbound: Stream.fromPubSub(inbound), post });
  }),
);
