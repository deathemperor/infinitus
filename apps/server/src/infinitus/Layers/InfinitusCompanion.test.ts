import { InfinitusUnavailable } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import {
  InfinitusControlClient,
  type InfinitusControlClientShape,
} from "../Services/InfinitusControlClient.ts";
import {
  InfinitusOpenFailed,
  launchInfinitus,
  launchInfinitusAtStartup,
  STARTUP_GRACE,
} from "./InfinitusCompanion.ts";

const SOCKET = "/tmp/infinitus-companion-test.sock";

/** A control client whose `status` answers while `available` is true. */
const clientLayer = (available: Ref.Ref<boolean>, socketPath: string | null = SOCKET) =>
  Layer.succeed(InfinitusControlClient, {
    socketPath,
    request: (input) =>
      Effect.gen(function* () {
        if (yield* Ref.get(available)) return { version: "0.5.0" };
        return yield* new InfinitusUnavailable({ path: SOCKET, cause: "ENOENT" });
      }),
  } satisfies InfinitusControlClientShape);

/** `open` that records each run and exits with `exitCode`. */
const openStub = (opens: Ref.Ref<number>, exitCode: number | InfinitusOpenFailed = 0) =>
  Ref.update(opens, (n) => n + 1).pipe(
    Effect.andThen(typeof exitCode === "number" ? Effect.succeed(exitCode) : Effect.fail(exitCode)),
  );

describe("launchInfinitus", () => {
  effectIt.effect("refuses off macOS without touching the socket", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const result = yield* launchInfinitus({ platform: "linux", runOpen: openStub(opens) }).pipe(
        Effect.provide(clientLayer(available)),
      );
      expect(result).toEqual({ launched: false, reason: "Infinitus runs on macOS only" });
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("refuses when the host has no socket path", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const result = yield* launchInfinitus({ platform: "darwin", runOpen: openStub(opens) }).pipe(
        Effect.provide(clientLayer(available, null)),
      );
      expect(result.launched).toBe(false);
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("leaves a running app alone", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(true);
      const result = yield* launchInfinitus({ platform: "darwin", runOpen: openStub(opens) }).pipe(
        Effect.provide(clientLayer(available)),
      );
      expect(result).toEqual({ launched: false, reason: "Infinitus is already running" });
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("opens the app once when the socket is unreachable", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const result = yield* launchInfinitus({ platform: "darwin", runOpen: openStub(opens) }).pipe(
        Effect.provide(clientLayer(available)),
      );
      expect(result).toEqual({ launched: true });
      expect(yield* Ref.get(opens)).toBe(1);
    }),
  );

  effectIt.effect("reports a failing open as a reason, never an error", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const exited = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens, 1),
      }).pipe(Effect.provide(clientLayer(available)));
      expect(exited).toEqual({ launched: false, reason: "open exited 1" });
      const failed = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens, new InfinitusOpenFailed({ cause: new Error("spawn ENOENT") })),
      }).pipe(Effect.provide(clientLayer(available)));
      expect(failed).toEqual({ launched: false, reason: "open failed: spawn ENOENT" });
    }),
  );
});

describe("launchInfinitusAtStartup", () => {
  effectIt.effect("opens the app once when the socket stays quiet past the grace", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const fiber = yield* launchInfinitusAtStartup({
        platform: "darwin",
        runOpen: openStub(opens),
      }).pipe(Effect.provide(clientLayer(available)), Effect.forkChild);
      yield* TestClock.adjust(Duration.subtract(STARTUP_GRACE, Duration.millis(1)));
      expect(yield* Ref.get(opens)).toBe(0);
      yield* TestClock.adjust(Duration.millis(1));
      expect(yield* Fiber.join(fiber)).toEqual({ launched: true });
      expect(yield* Ref.get(opens)).toBe(1);
    }),
  );

  effectIt.effect("does nothing when the app answers within the grace", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const fiber = yield* launchInfinitusAtStartup({
        platform: "darwin",
        runOpen: openStub(opens),
      }).pipe(Effect.provide(clientLayer(available)), Effect.forkChild);
      yield* Ref.set(available, true);
      yield* TestClock.adjust(STARTUP_GRACE);
      expect(yield* Fiber.join(fiber)).toBeNull();
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("does nothing when the app is already up, and never off macOS", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const up = yield* launchInfinitusAtStartup({
        platform: "darwin",
        runOpen: openStub(opens),
      }).pipe(Effect.provide(clientLayer(yield* Ref.make(true))));
      const linux = yield* launchInfinitusAtStartup({
        platform: "linux",
        runOpen: openStub(opens),
      }).pipe(Effect.provide(clientLayer(yield* Ref.make(false))));
      expect(up).toBeNull();
      expect(linux).toBeNull();
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );
});
