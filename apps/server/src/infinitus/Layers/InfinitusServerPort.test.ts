import {
  InfinitusCommandFailed,
  InfinitusUnavailable,
  type InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect, it } from "vite-plus/test";

import {
  InfinitusControlClient,
  type InfinitusControlClientShape,
} from "../Services/InfinitusControlClient.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusLive } from "./Infinitus.ts";
import {
  keepServerPortPublished,
  publishServerPort,
  serverPortWithheldReason,
} from "./InfinitusServerPort.ts";

const STUB_SOCKET = "/tmp/infinitus-stub.sock";
const FAST = Duration.seconds(5);
const PROBE = Duration.seconds(15);

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

/** Enough for the poll's fast cycle to call the app available. */
const pollResults = (): Record<string, unknown> => ({
  status: {
    version: "0.4.3",
    sha: "abc1234",
    socket: STUB_SOCKET,
    badge: "none",
    playground: false,
    signInRunning: false,
    engines: {},
  },
  manifest: manifestWith("status", "fleets", "sessions", "prefs"),
  fleets: [],
  sessions: [],
  prefs: { sections: [], prefs: [] },
});

interface Call {
  readonly command: string;
  readonly args: ReadonlyArray<string>;
}

interface ControlStubShape {
  readonly request: InfinitusControlClientShape["request"];
  readonly calls: Effect.Effect<ReadonlyArray<Call>>;
  readonly setResult: (command: string, result: unknown) => Effect.Effect<void>;
  readonly removeResult: (command: string) => Effect.Effect<void>;
  /** A non-null cause makes every command answer `InfinitusUnavailable`. */
  readonly setUnavailable: (cause: string | null) => Effect.Effect<void>;
}

class ControlStub extends Context.Service<ControlStub, ControlStubShape>()(
  "t3/infinitus/Layers/InfinitusServerPort.test/ControlStub",
) {}

const ControlStubLive = Layer.effect(
  ControlStub,
  Effect.gen(function* () {
    const results = yield* Ref.make<Record<string, unknown>>(pollResults());
    const unavailable = yield* Ref.make<string | null>(null);
    const calls = yield* Ref.make<ReadonlyArray<Call>>([]);
    const request: InfinitusControlClientShape["request"] = (input) =>
      Effect.gen(function* () {
        yield* Ref.update(calls, (previous) => [
          ...previous,
          { command: input.command, args: input.args ?? [] },
        ]);
        const cause = yield* Ref.get(unavailable);
        if (cause !== null) {
          return yield* new InfinitusUnavailable({ path: STUB_SOCKET, cause });
        }
        const scripted = yield* Ref.get(results);
        if (!Object.hasOwn(scripted, input.command)) {
          return yield* new InfinitusCommandFailed({
            command: input.command,
            error: "unknown command",
            restarting: false,
          });
        }
        return scripted[input.command];
      });
    return {
      request,
      calls: Ref.get(calls),
      setResult: (command, result) =>
        Ref.update(results, (previous) => ({ ...previous, [command]: result })),
      removeResult: (command) => Ref.update(results, ({ [command]: _dropped, ...rest }) => rest),
      setUnavailable: (cause) => Ref.set(unavailable, cause),
    } satisfies ControlStubShape;
  }),
);

const stubClientLayer = (socketPath: string | null) =>
  Layer.effect(
    InfinitusControlClient,
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      return { socketPath, request: stub.request } satisfies InfinitusControlClientShape;
    }),
  );

const testLayer = (socketPath: string | null = STUB_SOCKET) =>
  InfinitusLive.pipe(
    Layer.provideMerge(stubClientLayer(socketPath)),
    Layer.provideMerge(ControlStubLive),
  );

/** The `prefs set fork_server_port …` writes, in order. */
const portWrites = (calls: ReadonlyArray<Call>) =>
  calls
    .filter((call) => call.command === "prefs" && call.args[0] === "set")
    .map((call) => call.args);

/** Subscribes (which is what makes the service poll) and hands back the queue. */
const watch = Effect.fn("watch")(function* () {
  const infinitus = yield* InfinitusService;
  const queue = yield* Queue.unbounded<InfinitusSnapshot>();
  const fiber = yield* Effect.forkChild(
    Stream.runForEach(infinitus.changes(), (snapshot) => Queue.offer(queue, snapshot)),
  );
  return { queue, fiber } as const;
});

/** Lets the republish fiber, which runs behind the snapshot, get its turn. */
const settle = Effect.repeat(Effect.yieldNow, { times: 20 });

describe("serverPortWithheldReason", () => {
  it("withholds the pref from a dev-runner or worktree server and publishes for the installed one", () => {
    const installed = { devUrl: undefined, baseDir: "/Users/me/.t3", worktreeT3Home: undefined };
    expect(serverPortWithheldReason(installed)).toBeUndefined();
    expect(
      serverPortWithheldReason({ ...installed, devUrl: new URL("http://localhost:3000") }),
    ).toMatch(/dev-runner/);
    expect(
      serverPortWithheldReason({
        devUrl: undefined,
        baseDir: "/Users/me/wt/.t3",
        worktreeT3Home: "/Users/me/wt/.t3",
      }),
    ).toMatch(/worktree-local/);
    // A worktree checkout run against the shared home is not a worktree server.
    expect(
      serverPortWithheldReason({
        devUrl: undefined,
        baseDir: "/Users/me/.t3",
        worktreeT3Home: "/Users/me/wt/.t3",
      }),
    ).toBeUndefined();
  });
});

describe("publishServerPort", () => {
  effectIt.effect("sets fork_server_port when the manifest lists prefs", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const heard = yield* publishServerPort(3774);
      expect(heard).toBe(true);
      expect(yield* stub.calls).toEqual([
        { command: "manifest", args: [] },
        { command: "prefs", args: ["set", "fork_server_port", "3774"] },
      ]);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("leaves an app without a pref catalog alone", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      yield* stub.setResult("manifest", manifestWith("status"));
      expect(yield* publishServerPort(3774)).toBe(true);
      expect(yield* stub.calls).toEqual([{ command: "manifest", args: [] }]);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("does not fail when Infinitus is not running, and says it was not heard", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      yield* stub.setUnavailable("ENOENT");
      expect(yield* publishServerPort(3774)).toBe(false);
      expect(yield* stub.calls).toEqual([{ command: "manifest", args: [] }]);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("does not fail when the app refuses the write", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      yield* stub.removeResult("prefs");
      expect(yield* publishServerPort(3774)).toBe(true);
      expect((yield* stub.calls).map((call) => call.command)).toEqual(["manifest", "prefs"]);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("does not fail on an undecodable manifest", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      yield* stub.setResult("manifest", { commands: "nope" });
      expect(yield* publishServerPort(3774)).toBe(true);
      expect(yield* stub.calls).toEqual([{ command: "manifest", args: [] }]);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("asks nothing when no socket is configured", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      expect(yield* publishServerPort(3774)).toBe(false);
      expect(yield* stub.calls).toEqual([]);
    }).pipe(Effect.provide(testLayer(null))),
  );
});

describe("keepServerPortPublished", () => {
  effectIt.effect("publishes at startup and never polls on its own", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const keeper = yield* Effect.forkChild(keepServerPortPublished(3774));

      yield* TestClock.adjust(Duration.minutes(5));

      expect(portWrites(yield* stub.calls)).toEqual([["set", "fork_server_port", "3774"]]);
      expect((yield* stub.calls).map((call) => call.command)).toEqual(["manifest", "prefs"]);

      yield* Fiber.interrupt(keeper);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("republishes once when a watched app goes away and comes back", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const keeper = yield* Effect.forkChild(keepServerPortPublished(3774));
      yield* settle;
      const { queue, fiber } = yield* watch();

      // The first polled snapshot shows the app the startup publish reached:
      // not a return, so no second write.
      const first = yield* Queue.take(queue);
      expect(first.available).toBe(true);
      yield* settle;
      expect(portWrites(yield* stub.calls)).toHaveLength(1);

      yield* stub.setUnavailable("ENOENT");
      yield* TestClock.adjust(FAST);
      const gone = yield* Queue.take(queue);
      expect(gone.available).toBe(false);

      yield* stub.setUnavailable(null);
      yield* TestClock.adjust(PROBE);
      const back = yield* Queue.take(queue);
      expect(back.available).toBe(true);
      yield* settle;
      expect(portWrites(yield* stub.calls)).toEqual([
        ["set", "fork_server_port", "3774"],
        ["set", "fork_server_port", "3774"],
      ]);

      yield* Fiber.interrupt(fiber);
      yield* Fiber.interrupt(keeper);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("lands the port on the first sighting of an app that was away at startup", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      yield* stub.setUnavailable("ENOENT");
      const keeper = yield* Effect.forkChild(keepServerPortPublished(3774));
      yield* settle;
      expect(portWrites(yield* stub.calls)).toEqual([]);

      const { queue, fiber } = yield* watch();
      const first = yield* Queue.take(queue);
      expect(first.available).toBe(false);

      yield* stub.setUnavailable(null);
      yield* TestClock.adjust(PROBE);
      const back = yield* Queue.take(queue);
      expect(back.available).toBe(true);
      yield* settle;
      expect(portWrites(yield* stub.calls)).toEqual([["set", "fork_server_port", "3774"]]);

      yield* Fiber.interrupt(fiber);
      yield* Fiber.interrupt(keeper);
    }).pipe(Effect.provide(testLayer())),
  );

  effectIt.effect("does nothing at all without a socket", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const keeper = yield* Effect.forkChild(keepServerPortPublished(3774));
      yield* TestClock.adjust(Duration.minutes(5));
      expect(yield* stub.calls).toEqual([]);
      yield* Fiber.interrupt(keeper);
    }).pipe(Effect.provide(testLayer(null))),
  );
});
