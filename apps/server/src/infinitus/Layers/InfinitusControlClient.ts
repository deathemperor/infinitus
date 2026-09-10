import * as NodeNet from "node:net";
import * as NodeOS from "node:os";

import {
  InfinitusCommandFailed,
  InfinitusControlReply,
  InfinitusControlRequest,
  InfinitusProtocolError,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import { HostProcessEnvironment, HostProcessPlatform } from "@t3tools/shared/hostProcess";
import { resolveInfinitusControlSocketPath } from "@t3tools/shared/infinitusControl";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

import {
  InfinitusControlClient,
  InfinitusControlClientConfig,
  type InfinitusControlClientShape,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_REPLY_BYTES = 8 * 1024 * 1024;

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

const makeInfinitusControlClient = Effect.gen(function* () {
  const config = yield* InfinitusControlClientConfig;

  const request = Effect.fn("InfinitusControlClient.request")(function* (
    input: InfinitusControlRequestInput,
  ): Effect.fn.Return<
    unknown,
    InfinitusUnavailable | InfinitusProtocolError | InfinitusCommandFailed
  > {
    const socketPath = config.socketPath;
    if (socketPath === null) {
      return yield* new InfinitusUnavailable({ path: "", cause: "unsupported platform" });
    }

    // `secret` is an optional key: absent, never present-and-undefined.
    const requestLine = yield* encodeRequestLine({
      command: input.command,
      args: input.args ?? [],
      options: input.options ?? {},
      ...(input.secret === undefined ? {} : { secret: input.secret }),
    }).pipe(Effect.orDie);

    const line = yield* readReplyLine({
      socketPath,
      requestLine: `${requestLine}\n`,
      maxReplyBytes: config.maxReplyBytes,
    }).pipe(
      Effect.timeoutOrElse({
        duration: Duration.millis(config.timeoutMs),
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
        command: input.command,
        error: reply.error ?? "unknown error",
        restarting: reply.restarting,
      });
    }

    return reply.result;
  });

  return {
    socketPath: config.socketPath,
    request,
  } satisfies InfinitusControlClientShape;
});

export const InfinitusControlClientLive = Layer.effect(
  InfinitusControlClient,
  makeInfinitusControlClient,
);

export const InfinitusControlClientConfigLive = Layer.effect(
  InfinitusControlClientConfig,
  Effect.gen(function* () {
    const platform = yield* HostProcessPlatform;
    const env = yield* HostProcessEnvironment;
    return {
      socketPath: resolveInfinitusControlSocketPath({
        platform,
        env,
        homeDir: NodeOS.homedir(),
      }),
      timeoutMs: DEFAULT_TIMEOUT_MS,
      maxReplyBytes: DEFAULT_MAX_REPLY_BYTES,
    };
  }),
);
