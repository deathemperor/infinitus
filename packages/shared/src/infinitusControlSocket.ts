/**
 * The Infinitus control-socket wire client: newline-delimited JSON, one
 * request per connection, the first reply line is the answer. Shared by the
 * server's `InfinitusControlClient` layer and the desktop shell's quit-with-app
 * hook, so there is exactly one implementation of the protocol on this side.
 */
import * as NodeNet from "node:net";

import {
  InfinitusCommandFailed,
  InfinitusControlReply,
  InfinitusControlRequest,
  InfinitusProtocolError,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

export const INFINITUS_CONTROL_DEFAULT_TIMEOUT_MS = 10_000;
export const INFINITUS_CONTROL_DEFAULT_MAX_REPLY_BYTES = 8 * 1024 * 1024;

/**
 * One call of one control command. `args` and `options` default to empty;
 * `secret` carries stdin-read material (a proxy key, a bot token) that goes on
 * the wire and never into a log, span or error.
 */
export interface InfinitusControlRequestInput {
  readonly command: string;
  readonly args?: ReadonlyArray<string>;
  readonly options?: Readonly<Record<string, string>>;
  readonly secret?: string;
}

export type InfinitusControlError =
  | InfinitusUnavailable
  | InfinitusProtocolError
  | InfinitusCommandFailed;

const encodeRequestLine = Schema.encodeEffect(Schema.fromJsonString(InfinitusControlRequest));
const decodeReplyJson = Schema.decodeUnknownEffect(Schema.fromJsonString(Schema.Unknown));
const decodeReply = Schema.decodeUnknownEffect(InfinitusControlReply);

/**
 * Opens one connection, writes one request line, and resolves with the first
 * reply line. The socket is destroyed on every path, interruption included, so
 * a timeout upstream leaves nothing behind.
 */
const readReplyLine = (input: {
  readonly socketPath: string;
  readonly requestLine: string;
  readonly maxReplyBytes: number;
}) =>
  Effect.callback<string, InfinitusUnavailable | InfinitusProtocolError>((resume) => {
    const socket = NodeNet.createConnection(input.socketPath);
    socket.setEncoding("utf8");
    let buffer = "";
    let bytes = 0;
    let settled = false;

    const finish = (
      effect: Effect.Effect<string, InfinitusUnavailable | InfinitusProtocolError>,
    ) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resume(effect);
    };

    socket.once("connect", () => {
      socket.write(input.requestLine);
    });

    socket.on("data", (chunk: string) => {
      buffer += chunk;
      bytes += Buffer.byteLength(chunk, "utf8");
      if (bytes > input.maxReplyBytes) {
        finish(
          Effect.fail(
            new InfinitusProtocolError({
              detail: `reply exceeded ${input.maxReplyBytes} bytes`,
            }),
          ),
        );
        return;
      }
      const newline = buffer.indexOf("\n");
      if (newline === -1) return;
      finish(Effect.succeed(buffer.slice(0, newline)));
    });

    // ENOENT, ECONNREFUSED, EACCES: the socket is not there, or not ours.
    socket.on("error", (error: NodeJS.ErrnoException) => {
      finish(
        Effect.fail(
          new InfinitusUnavailable({
            path: input.socketPath,
            cause: error.code ?? error.message,
          }),
        ),
      );
    });

    // A hang-up with no line is not an answer, so it is unavailability rather
    // than a protocol error. `settled` keeps the connect error's code ahead of
    // the close that follows it.
    socket.once("close", () => {
      finish(
        Effect.fail(
          new InfinitusUnavailable({ path: input.socketPath, cause: "closed before a reply" }),
        ),
      );
    });

    return Effect.sync(() => {
      settled = true;
      socket.destroy();
    });
  });

/**
 * Runs one command over a fresh connection and resolves to the reply's
 * `result`, which is `undefined` for commands that answer with no payload.
 */
export const requestInfinitusControl = Effect.fn("requestInfinitusControl")(function* (input: {
  readonly socketPath: string;
  readonly request: InfinitusControlRequestInput;
  readonly timeoutMs?: number;
  readonly maxReplyBytes?: number;
}): Effect.fn.Return<unknown, InfinitusControlError> {
  const { socketPath, request } = input;
  const timeoutMs = input.timeoutMs ?? INFINITUS_CONTROL_DEFAULT_TIMEOUT_MS;
  const maxReplyBytes = input.maxReplyBytes ?? INFINITUS_CONTROL_DEFAULT_MAX_REPLY_BYTES;

  // `secret` is an optional key: absent, never present-and-undefined.
  const requestLine = yield* encodeRequestLine({
    command: request.command,
    args: request.args ?? [],
    options: request.options ?? {},
    ...(request.secret === undefined ? {} : { secret: request.secret }),
  }).pipe(Effect.orDie);

  const line = yield* readReplyLine({
    socketPath,
    requestLine: `${requestLine}\n`,
    maxReplyBytes,
  }).pipe(
    Effect.timeoutOrElse({
      duration: Duration.millis(timeoutMs),
      orElse: () => Effect.fail(new InfinitusUnavailable({ path: socketPath, cause: "timeout" })),
    }),
  );

  const parsed = yield* decodeReplyJson(line).pipe(
    Effect.mapError(() => new InfinitusProtocolError({ detail: "reply line is not valid JSON" })),
  );

  const reply = yield* decodeReply(parsed).pipe(
    Effect.mapError(
      (error) =>
        new InfinitusProtocolError({
          detail: `reply did not match InfinitusControlReply: ${error.message}`,
        }),
    ),
  );

  if (!reply.ok) {
    return yield* new InfinitusCommandFailed({
      command: request.command,
      error: reply.error ?? "unknown error",
      restarting: reply.restarting,
    });
  }

  return reply.result;
});
