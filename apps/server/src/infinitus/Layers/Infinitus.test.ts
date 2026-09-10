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
import { describe, expect } from "vite-plus/test";

import {
  InfinitusControlClient,
  type InfinitusControlClientShape,
} from "../Services/InfinitusControlClient.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusLive } from "./Infinitus.ts";

const FAST = Duration.seconds(5);
const SLOW = Duration.seconds(30);
const PROBE = Duration.seconds(15);
const STUB_SOCKET = "/tmp/infinitus-stub.sock";

const manifestCommand = (name: string, effect: "read" | "write" | "restart") => ({
  name,
  args: [],
  options: [],
  effect,
  summary: `${name} for the test`,
  replyShape: "{}",
});

const fleet = (key: string) => ({
  key,
  engineID: "cswap",
  provider: "claude",
  capabilities: ["switch"],
  accounts: [],
});

const status = {
  version: "0.4.3",
  sha: "abc1234",
  socket: STUB_SOCKET,
  badge: "none",
  playground: false,
  signInRunning: false,
  engines: { cswap: { enabled: true, registered: true } },
};

/** What every command answers with unless a test rewrites it. */
const defaultResults = (): Record<string, unknown> => ({
  status,
  manifest: {
    schemaVersion: 1,
    commands: [
      manifestCommand("status", "read"),
      manifestCommand("fleets", "read"),
      manifestCommand("sessions", "read"),
      manifestCommand("forecast", "read"),
      manifestCommand("switch", "write"),
      manifestCommand("prefs", "read"),
    ],
  },
  fleets: [fleet("cswap/claude")],
  sessions: [],
  forecast: { forecast: null },
  prefs: { sections: [{ slug: "display", name: "Display" }], prefs: [] },
  switch: { fleet: "cswap/claude" },
});

interface ControlStubShape {
  readonly request: InfinitusControlClientShape["request"];
  /** Every command the service asked for, in order. */
  readonly calls: Effect.Effect<ReadonlyArray<string>>;
  /** The same, with the options each carried (the lease body rides `--body`). */
  readonly requests: Effect.Effect<
    ReadonlyArray<{ readonly command: string; readonly options: Readonly<Record<string, string>> }>
  >;
  readonly resetCalls: Effect.Effect<void>;
  readonly setResult: (command: string, result: unknown) => Effect.Effect<void>;
  /** A non-null cause makes every command answer `InfinitusUnavailable`. */
  readonly setUnavailable: (cause: string | null) => Effect.Effect<void>;
}

class ControlStub extends Context.Service<ControlStub, ControlStubShape>()(
  "t3/infinitus/Layers/Infinitus.test/ControlStub",
) {}

const ControlStubLive = Layer.effect(
  ControlStub,
  Effect.gen(function* () {
    const results = yield* Ref.make<Record<string, unknown>>(defaultResults());
    const unavailable = yield* Ref.make<string | null>(null);
    const calls = yield* Ref.make<ReadonlyArray<string>>([]);
    const requests = yield* Ref.make<
      ReadonlyArray<{
        readonly command: string;
        readonly options: Readonly<Record<string, string>>;
      }>
    >([]);

    const request: InfinitusControlClientShape["request"] = (input) =>
      Effect.gen(function* () {
        yield* Ref.update(calls, (previous) => [...previous, input.command]);
        yield* Ref.update(requests, (previous) => [
          ...previous,
          { command: input.command, options: input.options ?? {} },
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
      requests: Ref.get(requests),
      resetCalls: Effect.all([Ref.set(calls, []), Ref.set(requests, [])]).pipe(Effect.asVoid),
      setResult: (command, result) =>
        Ref.update(results, (previous) => ({ ...previous, [command]: result })),
      setUnavailable: (cause) => Ref.set(unavailable, cause),
    } satisfies ControlStubShape;
  }),
);

const StubClientLive = Layer.effect(
  InfinitusControlClient,
  Effect.gen(function* () {
    const stub = yield* ControlStub;
    return { socketPath: STUB_SOCKET, request: stub.request } satisfies InfinitusControlClientShape;
  }),
);

const TestLayer = InfinitusLive.pipe(
  Layer.provide(StubClientLive),
  Layer.provideMerge(ControlStubLive),
);

/**
 * The same stub with one scheduler turn in front of every reply, which is what
 * the real socket does. The first subscriber's poll then cannot finish inline,
 * so the subscription lands before any snapshot exists — the window in which
 * the pre-poll placeholder used to reach clients (#561).
 */
const AsyncStubClientLive = Layer.effect(
  InfinitusControlClient,
  Effect.gen(function* () {
    const stub = yield* ControlStub;
    return {
      socketPath: STUB_SOCKET,
      request: (input) => Effect.yieldNow.pipe(Effect.flatMap(() => stub.request(input))),
    } satisfies InfinitusControlClientShape;
  }),
);

const AsyncTestLayer = InfinitusLive.pipe(
  Layer.provide(AsyncStubClientLive),
  Layer.provideMerge(ControlStubLive),
);

/** The reason the one-shot getter answers with before the first cycle. No
    subscriber may ever see it. */
const NOT_POLLED_REASON = "the socket has not been polled yet";

/**
 * Subscribes and waits for the first emission. Taking from a queue rather than
 * adjusting a clock is what makes these tests deterministic: the take cannot
 * complete until the subscriber fiber has run and the poller has published.
 */
const subscribe = Effect.fn("subscribe")(function* (infinitus: InfinitusService["Service"]) {
  const queue = yield* Queue.unbounded<InfinitusSnapshot>();
  const fiber = yield* Effect.forkChild(
    Stream.runForEach(infinitus.changes, (snapshot) => Queue.offer(queue, snapshot)),
  );
  const first = yield* Queue.take(queue);
  return { queue, fiber, first } as const;
});

describe("InfinitusService", () => {
  effectIt.effect("touches the socket for nobody", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;

      yield* TestClock.adjust(Duration.minutes(5));

      expect(yield* stub.calls).toEqual([]);
      const snapshot = yield* infinitus.snapshot;
      expect(snapshot.available).toBe(false);
      expect(snapshot.fleets).toEqual([]);
      expect(snapshot.commands).toEqual([]);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("polls the moment the first subscriber arrives", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;

      const { fiber, first } = yield* subscribe(infinitus);

      expect(first.available).toBe(true);
      expect(first.status?.version).toBe("0.4.3");
      expect(first.fleets.map((entry) => entry.key)).toEqual(["cswap/claude"]);
      const calls = yield* stub.calls;
      expect(calls).toContain("status");
      expect(calls).toContain("manifest");
      expect(calls).toContain("fleets");
      expect(calls).toContain("sessions");
      // The first cycle is also the first slow one, so the catalogue rides along.
      expect(first.prefs?.sections[0]?.slug).toBe("display");

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("emits a changed fleets reply and swallows an identical one", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const { queue, fiber } = yield* subscribe(infinitus);

      yield* stub.setResult("fleets", [fleet("cswap/codex")]);
      yield* TestClock.adjust(FAST);
      const changed = yield* Queue.take(queue);
      expect(changed.fleets.map((entry) => entry.key)).toEqual(["cswap/codex"]);

      // Same reply on the next tick: nothing may reach the queue, so the take
      // below has to skip it and land on the tick after.
      yield* TestClock.adjust(FAST);
      yield* stub.setResult("fleets", [fleet("cswap/gemini")]);
      yield* TestClock.adjust(FAST);
      const next = yield* Queue.take(queue);
      expect(next.fleets.map((entry) => entry.key)).toEqual(["cswap/gemini"]);

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("stops polling when the last subscriber leaves", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const { fiber } = yield* subscribe(infinitus);

      yield* Fiber.interrupt(fiber);
      yield* stub.resetCalls;
      yield* TestClock.adjust(Duration.minutes(5));

      expect(yield* stub.calls).toEqual([]);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("keeps polling while a second subscriber stays", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const first = yield* subscribe(infinitus);
      const second = yield* subscribe(infinitus);

      // One of two leaving must not stop the loop the other is watching.
      yield* Fiber.interrupt(first.fiber);
      yield* stub.setResult("fleets", [fleet("cswap/codex")]);
      yield* TestClock.adjust(FAST);
      const seen = yield* Queue.take(second.queue);
      expect(seen.fleets.map((entry) => entry.key)).toEqual(["cswap/codex"]);

      yield* Fiber.interrupt(second.fiber);
      yield* stub.resetCalls;
      yield* TestClock.adjust(Duration.minutes(5));
      expect(yield* stub.calls).toEqual([]);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("reports the app going away and re-reads the manifest when it returns", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const { queue, fiber } = yield* subscribe(infinitus);

      yield* stub.setUnavailable("ENOENT");
      yield* TestClock.adjust(FAST);
      const down = yield* Queue.take(queue);
      expect(down.available).toBe(false);
      expect(down.unavailableReason).toBe("ENOENT");
      expect(down.fleets).toEqual([]);
      expect(down.commands).toEqual([]);
      expect(yield* infinitus.snapshot).toEqual(down);

      // Only `status` is tried while it is down, and on the probe's beat.
      yield* stub.resetCalls;
      yield* TestClock.adjust(PROBE);
      expect(yield* stub.calls).toEqual(["status"]);

      yield* stub.setUnavailable(null);
      yield* stub.resetCalls;
      yield* TestClock.adjust(PROBE);
      const up = yield* Queue.take(queue);
      expect(up.available).toBe(true);
      expect(yield* stub.calls).toContain("manifest");

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("refuses a command the manifest does not list", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const { fiber } = yield* subscribe(infinitus);

      yield* stub.resetCalls;
      const failure = yield* infinitus
        .command({ command: "selfDestruct", args: [], options: {} })
        .pipe(
          Effect.matchEffect({
            onFailure: (error) => Effect.succeed(error),
            onSuccess: (value) => Effect.die(new Error(`expected a refusal, got ${String(value)}`)),
          }),
        );

      expect(failure._tag).toBe("InfinitusCommandFailed");
      expect(failure).toMatchObject({ command: "selfDestruct", error: "unknown command" });
      expect(yield* stub.calls).toEqual([]);

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("runs a listed command and refreshes the fast set behind it", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const { queue, fiber } = yield* subscribe(infinitus);

      yield* stub.resetCalls;
      yield* stub.setResult("fleets", [fleet("cswap/codex")]);
      const result = yield* infinitus.command({
        command: "switch",
        args: ["cswap/claude", "2"],
        options: { yes: "true" },
      });

      expect(result).toEqual({ fleet: "cswap/claude" });
      // The refresh runs detached; the emission it publishes is the proof.
      const refreshed = yield* Queue.take(queue);
      expect(refreshed.fleets.map((entry) => entry.key)).toEqual(["cswap/codex"]);
      const calls = yield* stub.calls;
      expect(calls[0]).toBe("switch");
      expect(calls).toContain("fleets");
      expect(calls).toContain("sessions");

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("keeps the snapshot available when one reply fails the schema", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;

      yield* stub.setResult("fleets", [{ key: 7, engineID: "cswap" }]);
      const { fiber, first } = yield* subscribe(infinitus);

      expect(first.available).toBe(true);
      expect(first.fleets).toEqual([]);
      expect(first.status?.version).toBe("0.4.3");
      expect(first.commands.length).toBeGreaterThan(0);

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("re-reads the slow set only on its own beat", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const { queue, fiber } = yield* subscribe(infinitus);

      yield* stub.resetCalls;
      yield* stub.setResult("fleets", [fleet("cswap/codex")]);
      yield* TestClock.adjust(FAST);
      yield* Queue.take(queue);
      expect(yield* stub.calls).not.toContain("forecast");

      yield* stub.setResult("fleets", [fleet("cswap/gemini")]);
      yield* TestClock.adjust(SLOW);
      yield* Queue.take(queue);
      expect(yield* stub.calls).toContain("forecast");
      expect(yield* stub.calls).toContain("prefs");

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("skips prefs on a build whose manifest does not list it", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;

      yield* stub.setResult("manifest", {
        schemaVersion: 1,
        commands: [manifestCommand("status", "read")],
      });
      const { fiber, first } = yield* subscribe(infinitus);

      expect(first.prefs).toBeUndefined();
      expect(yield* stub.calls).not.toContain("prefs");

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("hands the first subscriber a polled snapshot, never the placeholder", () =>
    Effect.gen(function* () {
      const infinitus = yield* InfinitusService;

      const { fiber, first } = yield* subscribe(infinitus);

      expect(first.unavailableReason).not.toBe(NOT_POLLED_REASON);
      expect(first.available).toBe(true);
      expect(first.fleets.map((entry) => entry.key)).toEqual(["cswap/claude"]);

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(AsyncTestLayer)),
  );

  effectIt.effect("still reports an app that is not there once the first probe fails", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;

      yield* stub.setUnavailable("ENOENT");
      const { fiber, first } = yield* subscribe(infinitus);

      expect(first.available).toBe(false);
      expect(first.unavailableReason).toBe("ENOENT");
      expect(first.fleets).toEqual([]);

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(AsyncTestLayer)),
  );
});

describe("the lease", () => {
  const manifestWithLease = () => {
    const manifest = defaultResults().manifest as { commands: ReadonlyArray<unknown> };
    return {
      ...manifest,
      commands: [...manifest.commands, manifestCommand("client-activity", "write")],
    };
  };
  const leaseBodies = (stub: ControlStub["Service"]) =>
    stub.requests.pipe(
      Effect.map((requests) =>
        requests
          .filter((request) => request.command === "client-activity")
          .map(
            (request) =>
              JSON.parse(request.options.body ?? "{}") as {
                ttlMs: number;
                scopes: unknown;
                clientId: string;
              },
          ),
      ),
    );

  effectIt.effect("holds sessions, fleets and stats every 25 s while somebody subscribes", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      yield* stub.setResult("manifest", manifestWithLease());
      yield* stub.setResult("client-activity", { clientId: "t3-server-x" });
      const infinitus = yield* InfinitusService;
      const { fiber } = yield* subscribe(infinitus);

      let bodies = yield* leaseBodies(stub);
      expect(bodies).toHaveLength(1);
      expect(bodies[0]?.ttlMs).toBe(45_000);
      expect(bodies[0]?.scopes).toEqual([
        { type: "sessions" },
        { type: "fleets" },
        { type: "stats" },
      ]);
      expect(bodies[0]?.clientId).toMatch(/^t3-server-/);

      // 5 s ticks: t = 5, 10, 15, 20 carry no lease, t = 25 does, t = 50 again.
      yield* TestClock.adjust(Duration.seconds(20));
      expect(yield* leaseBodies(stub)).toHaveLength(1);
      yield* TestClock.adjust(FAST);
      expect(yield* leaseBodies(stub)).toHaveLength(2);
      yield* TestClock.adjust(Duration.seconds(25));
      bodies = yield* leaseBodies(stub);
      expect(bodies).toHaveLength(3);
      expect(bodies.every((body) => body.ttlMs === 45_000)).toBe(true);

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect(
    "releases the lease when the last subscriber leaves, and leases again for the next",
    () =>
      Effect.gen(function* () {
        const stub = yield* ControlStub;
        yield* stub.setResult("manifest", manifestWithLease());
        yield* stub.setResult("client-activity", { clientId: "t3-server-x" });
        const infinitus = yield* InfinitusService;
        const { fiber } = yield* subscribe(infinitus);
        expect(yield* leaseBodies(stub)).toHaveLength(1);

        yield* Fiber.interrupt(fiber);
        // The release is detached from the unsubscribe; one scheduler turn lands it.
        yield* TestClock.adjust(Duration.millis(1));
        const afterRelease = yield* leaseBodies(stub);
        expect(afterRelease).toHaveLength(2);
        expect(afterRelease[1]?.ttlMs).toBe(0);

        yield* TestClock.adjust(Duration.minutes(5));
        expect(yield* leaseBodies(stub)).toHaveLength(2);

        const second = yield* subscribe(infinitus);
        const again = yield* leaseBodies(stub);
        expect(again).toHaveLength(3);
        expect(again[2]?.ttlMs).toBe(45_000);
        yield* Fiber.interrupt(second.fiber);
      }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("sends nothing to a build whose manifest lacks the verb", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      const infinitus = yield* InfinitusService;
      const { fiber } = yield* subscribe(infinitus);
      yield* TestClock.adjust(Duration.minutes(2));
      expect((yield* stub.calls).filter((call) => call === "client-activity")).toEqual([]);
      yield* Fiber.interrupt(fiber);
      yield* TestClock.adjust(Duration.millis(1));
      expect((yield* stub.calls).filter((call) => call === "client-activity")).toEqual([]);
    }).pipe(Effect.provide(TestLayer)),
  );

  effectIt.effect("keeps publishing snapshots when the app refuses the lease", () =>
    Effect.gen(function* () {
      const stub = yield* ControlStub;
      // Listed in the manifest, but the stub has no scripted reply: every lease
      // fails as an unknown command.
      yield* stub.setResult("manifest", manifestWithLease());
      const infinitus = yield* InfinitusService;
      const { queue, fiber, first } = yield* subscribe(infinitus);
      expect(first.available).toBe(true);
      expect((yield* stub.calls).filter((call) => call === "client-activity")).toHaveLength(1);

      yield* stub.setResult("fleets", [fleet("cswap/codex")]);
      yield* TestClock.adjust(FAST);
      const next = yield* Queue.take(queue);
      expect(next.available).toBe(true);
      expect(next.fleets.map((entry) => entry.key)).toEqual(["cswap/codex"]);

      yield* Fiber.interrupt(fiber);
    }).pipe(Effect.provide(TestLayer)),
  );
});
