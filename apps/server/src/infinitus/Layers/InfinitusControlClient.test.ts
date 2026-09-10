import * as NodeCrypto from "node:crypto";
import * as NodeNet from "node:net";
import * as NodeOS from "node:os";
import * as NodeUtil from "node:util";

import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { describe, expect } from "vite-plus/test";

import {
  InfinitusControlClient,
  InfinitusControlClientConfig,
  type InfinitusControlClientConfigShape,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";
import { HostProcessEnvironment, HostProcessPlatform } from "@t3tools/shared/hostProcess";

import {
  InfinitusControlClientConfigLive,
  InfinitusControlClientLive,
} from "./InfinitusControlClient.ts";

interface ControlServerHandle {
  readonly socketPath: string;
  /** One entry per request line the server read, in arrival order. */
  readonly requestLines: ReadonlyArray<string>;
  readonly connectionCount: () => number;
  readonly close: () => Promise<void>;
}

// Unix socket paths cap at ~104 bytes, so keep the name short.
const tempSocketPath = () => `${NodeOS.tmpdir()}/inf-${NodeCrypto.randomUUID().slice(0, 8)}.sock`;

/**
 * A stand-in for the native app: one JSON line in, one scripted line out, then
 * the connection closes. `respond` returning null leaves the request hanging,
 * which is how the timeout case gets a server that accepts and never answers.
 */
async function startControlServer(
  respond: (line: string) => string | null,
): Promise<ControlServerHandle> {
  const socketPath = tempSocketPath();
  const requestLines: Array<string> = [];
  const sockets = new Set<NodeNet.Socket>();
  let connectionCount = 0;

  const server = NodeNet.createServer((socket) => {
    connectionCount += 1;
    sockets.add(socket);
    socket.setEncoding("utf8");
    socket.on("error", () => {});
    let buffer = "";
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline === -1) return;
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      requestLines.push(line);
      const reply = respond(line);
      if (reply === null) return;
      socket.end(`${reply}\n`);
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      resolve();
    });
  });

  return {
    socketPath,
    requestLines,
    connectionCount: () => connectionCount,
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => {
        server.close(() => {
          resolve();
        });
      });
    },
  };
}

/** A server that lives for the test's scope. */
const controlServer = (respond: (line: string) => string | null) =>
  Effect.acquireRelease(
    Effect.promise(() => startControlServer(respond)),
    (server) => Effect.promise(() => server.close()),
  );

/** The raw shape of a line the fake server read, for equality assertions. */
const parseWireLine = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Unknown));

const replyLine = (reply: Record<string, unknown>) =>
  JSON.stringify({ schemaVersion: 1, ...reply });

const makeConfig = (
  overrides: Partial<InfinitusControlClientConfigShape> & { readonly socketPath: string | null },
): InfinitusControlClientConfigShape => ({
  timeoutMs: 2_000,
  maxReplyBytes: 1024 * 1024,
  ...overrides,
});

const request = (config: InfinitusControlClientConfigShape, input: InfinitusControlRequestInput) =>
  Effect.gen(function* () {
    const client = yield* InfinitusControlClient;
    return yield* client.request(input);
  }).pipe(
    Effect.provide(
      InfinitusControlClientLive.pipe(
        Layer.provide(Layer.succeed(InfinitusControlClientConfig, config)),
      ),
    ),
  );

/** Runs a request expected to fail, succeeding with the typed error. */
const requestFailure = (
  config: InfinitusControlClientConfigShape,
  input: InfinitusControlRequestInput,
) =>
  request(config, input).pipe(
    Effect.matchEffect({
      onFailure: (error) => Effect.succeed(error),
      onSuccess: (value) => Effect.die(new Error(`expected a failure, got ${String(value)}`)),
    }),
  );

describe("InfinitusControlClient", () => {
  effectIt.effect("sends the command as one JSON line and returns the reply result", () =>
    Effect.gen(function* () {
      const server = yield* controlServer(() =>
        replyLine({ ok: true, result: { version: "1.2.3", badge: "ok" } }),
      );

      const result = yield* request(makeConfig({ socketPath: server.socketPath }), {
        command: "status",
        args: ["claude", "2"],
        options: { fleet: "claude" },
      });

      expect(result).toEqual({ version: "1.2.3", badge: "ok" });
      expect(parseWireLine(server.requestLines[0]!)).toEqual({
        command: "status",
        args: ["claude", "2"],
        options: { fleet: "claude" },
      });
    }),
  );

  effectIt.effect("uses a fresh connection for every request", () =>
    Effect.gen(function* () {
      const server = yield* controlServer(() => replyLine({ ok: true }));
      const config = makeConfig({ socketPath: server.socketPath });

      expect(yield* request(config, { command: "status" })).toBeUndefined();
      expect(yield* request(config, { command: "fleets" })).toBeUndefined();

      expect(server.connectionCount()).toBe(2);
      expect(server.requestLines).toHaveLength(2);
      expect(parseWireLine(server.requestLines[1]!)).toEqual({
        command: "fleets",
        args: [],
        options: {},
      });
    }),
  );

  effectIt.effect(
    "turns a failed reply into InfinitusCommandFailed and defaults restarting to false",
    () =>
      Effect.gen(function* () {
        const server = yield* controlServer(() => replyLine({ ok: false, error: "no such fleet" }));

        const error = yield* requestFailure(makeConfig({ socketPath: server.socketPath }), {
          command: "swap",
        });

        expect(error).toMatchObject({
          _tag: "InfinitusCommandFailed",
          command: "swap",
          error: "no such fleet",
          restarting: false,
        });
      }),
  );

  effectIt.effect("carries the restarting flag of a failed reply", () =>
    Effect.gen(function* () {
      const server = yield* controlServer(() =>
        replyLine({ ok: false, error: "the app is relaunching", restarting: true }),
      );

      const error = yield* requestFailure(makeConfig({ socketPath: server.socketPath }), {
        command: "restart",
      });

      expect(error).toMatchObject({ _tag: "InfinitusCommandFailed", restarting: true });
    }),
  );

  effectIt.effect("rejects a reply line that is not JSON", () =>
    Effect.gen(function* () {
      const server = yield* controlServer(() => "not a json line");

      const error = yield* requestFailure(makeConfig({ socketPath: server.socketPath }), {
        command: "status",
      });

      expect(error).toMatchObject({
        _tag: "InfinitusProtocolError",
        detail: "reply line is not valid JSON",
      });
    }),
  );

  effectIt.effect("rejects a reply that does not match the reply schema", () =>
    Effect.gen(function* () {
      const server = yield* controlServer(() => JSON.stringify({ schemaVersion: "one", ok: true }));

      const error = yield* requestFailure(makeConfig({ socketPath: server.socketPath }), {
        command: "status",
      });

      expect(error).toMatchObject({ _tag: "InfinitusProtocolError" });
    }),
  );

  effectIt.effect("rejects a reply larger than the cap", () =>
    Effect.gen(function* () {
      const server = yield* controlServer(() => replyLine({ ok: true, result: "x".repeat(4096) }));

      const error = yield* requestFailure(
        makeConfig({ socketPath: server.socketPath, maxReplyBytes: 64 }),
        { command: "fleets" },
      );

      expect(error).toMatchObject({
        _tag: "InfinitusProtocolError",
        detail: "reply exceeded 64 bytes",
      });
    }),
  );

  effectIt.effect("reports an unreachable socket with its path", () =>
    Effect.gen(function* () {
      const socketPath = tempSocketPath();

      const error = yield* requestFailure(makeConfig({ socketPath }), { command: "status" });

      expect(error).toMatchObject({
        _tag: "InfinitusUnavailable",
        path: socketPath,
        cause: "ENOENT",
      });
    }),
  );

  // The one case that needs a real timer: nothing observable happens until the
  // injected 50 ms deadline fires, so `it.live` runs it on the real clock.
  effectIt.live("gives up on a server that accepts but never replies", () =>
    Effect.gen(function* () {
      const server = yield* controlServer(() => null);

      const error = yield* requestFailure(
        makeConfig({ socketPath: server.socketPath, timeoutMs: 50 }),
        { command: "status" },
      );

      expect(error).toMatchObject({
        _tag: "InfinitusUnavailable",
        path: server.socketPath,
        cause: "timeout",
      });
      expect(server.requestLines).toHaveLength(1);
    }),
  );

  effectIt.effect("writes the secret to the wire and keeps it out of the error", () =>
    Effect.gen(function* () {
      const secret = "sk-proxy-super-secret-value";
      const server = yield* controlServer(() =>
        replyLine({ ok: false, error: "the key was rejected" }),
      );

      const error = yield* requestFailure(makeConfig({ socketPath: server.socketPath }), {
        command: "cliproxy-key",
        secret,
      });

      expect(parseWireLine(server.requestLines[0]!)).toEqual({
        command: "cliproxy-key",
        args: [],
        options: {},
        secret,
      });
      expect(error).toMatchObject({ _tag: "InfinitusCommandFailed" });
      expect(NodeUtil.inspect(error, { depth: 10 })).not.toContain(secret);
      expect(String(error)).not.toContain(secret);
      expect(String((error as { readonly stack?: string }).stack ?? "")).not.toContain(secret);
    }),
  );

  effectIt.effect("reports an unsupported platform without touching the network", () =>
    Effect.gen(function* () {
      const error = yield* requestFailure(makeConfig({ socketPath: null }), {
        command: "status",
      });

      expect(error).toMatchObject({
        _tag: "InfinitusUnavailable",
        path: "",
        cause: "unsupported platform",
      });
    }),
  );

  effectIt.effect(
    "the live config honours INFINITUS_CONTROL_SOCKET over the platform default",
    () =>
      Effect.gen(function* () {
        const config = yield* InfinitusControlClientConfig;
        expect(config.socketPath).toBe("/tmp/infinitus-test.sock");
        expect(config.timeoutMs).toBe(10_000);
        expect(config.maxReplyBytes).toBe(8 * 1024 * 1024);
      }).pipe(
        Effect.provide(InfinitusControlClientConfigLive),
        Effect.provideService(HostProcessPlatform, "darwin"),
        Effect.provideService(HostProcessEnvironment, {
          INFINITUS_CONTROL_SOCKET: "/tmp/infinitus-test.sock",
        }),
      ),
  );
});
