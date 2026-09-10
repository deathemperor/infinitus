import { InfinitusCommandFailed, InfinitusUnavailable } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import { describe, expect } from "vite-plus/test";

import {
  InfinitusControlClient,
  type InfinitusControlClientShape,
} from "../Services/InfinitusControlClient.ts";
import { publishServerPort } from "./InfinitusServerPort.ts";

const STUB_SOCKET = "/tmp/infinitus-stub.sock";

const manifestCommand = (name: string) => ({
  name,
  args: [],
  options: [],
  effect: "read",
  summary: `${name} for the test`,
  replyShape: "{}",
});

const manifestWith = (...commands: ReadonlyArray<string>) => ({
  schemaVersion: 1,
  commands: commands.map(manifestCommand),
});

interface Call {
  readonly command: string;
  readonly args: ReadonlyArray<string>;
}

/** A client whose replies are scripted per command; `calls` records what was asked. */
const stubClient = (
  results: Record<string, Effect.Effect<unknown, InfinitusUnavailable | InfinitusCommandFailed>>,
  socketPath: string | null = STUB_SOCKET,
) =>
  Effect.gen(function* () {
    const calls = yield* Ref.make<ReadonlyArray<Call>>([]);
    const request: InfinitusControlClientShape["request"] = (input) =>
      Ref.update(calls, (previous) => [
        ...previous,
        { command: input.command, args: input.args ?? [] },
      ]).pipe(
        Effect.andThen(
          results[input.command] ??
            new InfinitusCommandFailed({
              command: input.command,
              error: "unknown command",
              restarting: false,
            }),
        ),
      );
    return {
      layer: Layer.succeed(InfinitusControlClient, { socketPath, request }),
      calls: Ref.get(calls),
    };
  });

describe("publishServerPort", () => {
  effectIt.effect("sets fork_server_port when the manifest lists prefs", () =>
    Effect.gen(function* () {
      const stub = yield* stubClient({
        manifest: Effect.succeed(manifestWith("status", "prefs")),
        prefs: Effect.succeed({ set: { key: "fork_server_port" } }),
      });
      yield* publishServerPort(3774).pipe(Effect.provide(stub.layer));
      expect(yield* stub.calls).toEqual([
        { command: "manifest", args: [] },
        { command: "prefs", args: ["set", "fork_server_port", "3774"] },
      ]);
    }),
  );

  effectIt.effect("leaves an app without a pref catalog alone", () =>
    Effect.gen(function* () {
      const stub = yield* stubClient({ manifest: Effect.succeed(manifestWith("status")) });
      yield* publishServerPort(3774).pipe(Effect.provide(stub.layer));
      expect(yield* stub.calls).toEqual([{ command: "manifest", args: [] }]);
    }),
  );

  effectIt.effect("does not fail when Infinitus is not running", () =>
    Effect.gen(function* () {
      const stub = yield* stubClient({
        manifest: new InfinitusUnavailable({ path: STUB_SOCKET, cause: "ENOENT" }),
      });
      yield* publishServerPort(3774).pipe(Effect.provide(stub.layer));
      expect(yield* stub.calls).toEqual([{ command: "manifest", args: [] }]);
    }),
  );

  effectIt.effect("does not fail when the app refuses the write", () =>
    Effect.gen(function* () {
      const stub = yield* stubClient({
        manifest: Effect.succeed(manifestWith("prefs")),
        prefs: new InfinitusCommandFailed({
          command: "prefs",
          error: "fork_server_port: no such pref",
          restarting: false,
        }),
      });
      yield* publishServerPort(3774).pipe(Effect.provide(stub.layer));
      expect((yield* stub.calls).map((call) => call.command)).toEqual(["manifest", "prefs"]);
    }),
  );

  effectIt.effect("does not fail on an undecodable manifest", () =>
    Effect.gen(function* () {
      const stub = yield* stubClient({ manifest: Effect.succeed({ commands: "nope" }) });
      yield* publishServerPort(3774).pipe(Effect.provide(stub.layer));
      expect(yield* stub.calls).toEqual([{ command: "manifest", args: [] }]);
    }),
  );

  effectIt.effect("asks nothing when no socket is configured", () =>
    Effect.gen(function* () {
      const stub = yield* stubClient({ manifest: Effect.succeed(manifestWith("prefs")) }, null);
      yield* publishServerPort(3774).pipe(Effect.provide(stub.layer));
      expect(yield* stub.calls).toEqual([]);
    }),
  );
});
