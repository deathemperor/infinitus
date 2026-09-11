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
  type InfinitusOpenTarget,
  launchInfinitus,
  launchInfinitusAtStartup,
  RELAUNCH_REPROBE,
  RELAUNCH_REPROBES,
  STARTUP_GRACE,
} from "./InfinitusCompanion.ts";

const SOCKET = "/tmp/infinitus-companion-test.sock";
/** The helper nested in the desktop bundle (#777), as the live layer resolves it. */
const NESTED = {
  path: "/Applications/Infinitus.app/Contents/Library/LoginItems/Infinitus Menu Bar.app",
  version: "0.5.0",
};

/** A control client whose `status` answers while `available` is true, and
    otherwise fails with `cause` (ENOENT: no socket file; ECONNREFUSED: a file
    nobody listens on). */
const clientLayer = (
  available: Ref.Ref<boolean>,
  socketPath: string | null = SOCKET,
  cause = "ENOENT",
) =>
  Layer.succeed(InfinitusControlClient, {
    socketPath,
    request: (input) =>
      Effect.gen(function* () {
        if (yield* Ref.get(available)) return { version: "0.5.0" };
        return yield* new InfinitusUnavailable({ path: SOCKET, cause });
      }),
  } satisfies InfinitusControlClientShape);

/** `open` that records each run and exits with `exitCode`, printing `stderr`;
    `targets`, when given, records what each run was asked to open. */
const openStub =
  (
    opens: Ref.Ref<number>,
    exitCode: number | InfinitusOpenFailed = 0,
    stderr = "",
    targets?: Ref.Ref<ReadonlyArray<InfinitusOpenTarget>>,
  ) =>
  (target: InfinitusOpenTarget) =>
    Ref.update(opens, (n) => n + 1).pipe(
      Effect.andThen(targets ? Ref.update(targets, (all) => [...all, target]) : Effect.void),
      Effect.andThen(
        typeof exitCode === "number" ? Effect.succeed({ exitCode, stderr }) : Effect.fail(exitCode),
      ),
    );

/** A control client for the nested-helper cases: `status` answers `reply`
    until `quit` is received, after which the socket refuses (the app never
    unlinks it, #637). */
const nestedClientLayer = (reply: Record<string, unknown>, quits: Ref.Ref<number>) =>
  Layer.succeed(InfinitusControlClient, {
    socketPath: SOCKET,
    request: (input) =>
      Effect.gen(function* () {
        if (input.command === "quit") {
          yield* Ref.update(quits, (n) => n + 1);
          return { quitting: true };
        }
        if ((yield* Ref.get(quits)) > 0) {
          return yield* new InfinitusUnavailable({ path: SOCKET, cause: "ECONNREFUSED" });
        }
        return reply;
      }),
  } satisfies InfinitusControlClientShape);

describe("launchInfinitus", () => {
  effectIt.effect("refuses off macOS without touching the socket", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const result = yield* launchInfinitus({
        platform: "linux",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(result).toEqual({ launched: false, reason: "Infinitus runs on macOS only" });
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("refuses when the host has no socket path", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const result = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available, null)));
      expect(result.launched).toBe(false);
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("leaves a running app alone", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(true);
      const result = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(result).toEqual({ launched: false, reason: "Infinitus is already running" });
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("opens the app once when the socket is unreachable", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const result = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)));
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
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(exited).toEqual({ launched: false, reason: "open exited 1" });
      const chatty = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens, 2, "open: something else\nmore\n"),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(chatty).toEqual({ launched: false, reason: "open exited 2: open: something else" });
      const failed = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens, new InfinitusOpenFailed({ cause: new Error("spawn ENOENT") })),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(failed).toEqual({ launched: false, reason: "open failed: spawn ENOENT" });
    }),
  );

  effectIt.effect("reads LaunchServices' unknown bundle id as 'not installed' (#731)", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const result = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(
          opens,
          1,
          "LSCopyApplicationURLsForBundleIdentifier() failed while trying to determine the application with bundle identifier run.infinitus.\n",
        ),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(result).toEqual({
        launched: false,
        installed: false,
        reason: "No Infinitus app is installed on this Mac.",
      });
    }),
  );
});

describe("launchInfinitus with a nested helper (#777)", () => {
  effectIt.effect("opens the nested helper by path, and by bundle id only when that fails", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const targets = yield* Ref.make<ReadonlyArray<InfinitusOpenTarget>>([]);
      const available = yield* Ref.make(false);
      // A fresh DMG install: LaunchServices has not indexed the nested bundle
      // yet, so `open -a <path>` is the one that works.
      const byPath = yield* launchInfinitus({
        platform: "darwin",
        runOpen: openStub(opens, 0, "", targets),
        nested: NESTED,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(byPath).toEqual({ launched: true });
      expect(yield* Ref.get(targets)).toEqual([{ by: "path", path: NESTED.path }]);

      // The path refused (a helper the user moved away): the bundle id is the fallback.
      yield* Ref.set(targets, []);
      let calls = 0;
      const fallback = yield* launchInfinitus({
        platform: "darwin",
        runOpen: (target) =>
          Ref.update(targets, (all) => [...all, target]).pipe(
            Effect.andThen(
              Effect.succeed(
                calls++ === 0
                  ? { exitCode: 1, stderr: "no such file\n" }
                  : { exitCode: 0, stderr: "" },
              ),
            ),
          ),
        nested: NESTED,
      }).pipe(Effect.provide(clientLayer(available)));
      expect(fallback).toEqual({ launched: true });
      expect(yield* Ref.get(targets)).toEqual([
        { by: "path", path: NESTED.path },
        { by: "bundleId" },
      ]);
    }),
  );
});

describe("launchInfinitusAtStartup reconcile (#777)", () => {
  effectIt.effect(
    "quits a stale nested helper, waits for its socket to close, reopens it by path",
    () =>
      Effect.gen(function* () {
        const opens = yield* Ref.make(0);
        const targets = yield* Ref.make<ReadonlyArray<InfinitusOpenTarget>>([]);
        const quits = yield* Ref.make(0);
        const fiber = yield* launchInfinitusAtStartup({
          platform: "darwin",
          runOpen: openStub(opens, 0, "", targets),
          nested: NESTED,
        }).pipe(
          Effect.provide(nestedClientLayer({ version: "0.4.9", bundlePath: NESTED.path }, quits)),
          Effect.forkChild,
        );
        // The old helper answers at once; `quit` goes out, and the reopen waits
        // for the socket to stop answering rather than racing the shutdown.
        yield* TestClock.adjust(Duration.millis(1));
        expect(yield* Ref.get(quits)).toBe(1);
        expect(yield* Ref.get(opens)).toBe(0);
        yield* TestClock.adjust(RELAUNCH_REPROBE);
        expect(yield* Fiber.join(fiber)).toEqual({ launched: true });
        expect(yield* Ref.get(targets)).toEqual([{ by: "path", path: NESTED.path }]);
      }),
  );

  effectIt.effect(
    "leaves a fresh nested helper, a standalone one and a pre-bundlePath one alone",
    () =>
      Effect.gen(function* () {
        const opens = yield* Ref.make(0);
        for (const reply of [
          { version: NESTED.version, bundlePath: NESTED.path },
          // A brew-cask install still running (#7): not ours to quit, whatever its version.
          { version: "0.4.9", bundlePath: "/Applications/Infinitus.app" },
          // A helper that predates `status.bundlePath`: skew is logged, nothing is quit.
          { version: "0.4.9" },
        ]) {
          const quits = yield* Ref.make(0);
          const result = yield* launchInfinitusAtStartup({
            platform: "darwin",
            runOpen: openStub(opens),
            nested: NESTED,
          }).pipe(Effect.provide(nestedClientLayer(reply, quits)));
          expect(result).toBeNull();
          expect(yield* Ref.get(quits)).toBe(0);
        }
        expect(yield* Ref.get(opens)).toBe(0);
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
        nested: null,
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
        nested: null,
      }).pipe(Effect.provide(clientLayer(available)), Effect.forkChild);
      yield* Ref.set(available, true);
      yield* TestClock.adjust(STARTUP_GRACE);
      expect(yield* Fiber.join(fiber)).toBeNull();
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect("waits out a socket file that refuses, then opens it as stale (#637)", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const fiber = yield* launchInfinitusAtStartup({
        platform: "darwin",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available, SOCKET, "ECONNREFUSED")), Effect.forkChild);
      yield* TestClock.adjust(STARTUP_GRACE);
      expect(yield* Ref.get(opens)).toBe(0);
      const window = Duration.times(RELAUNCH_REPROBE, RELAUNCH_REPROBES);
      yield* TestClock.adjust(Duration.subtract(window, Duration.millis(1)));
      expect(yield* Ref.get(opens)).toBe(0);
      yield* TestClock.adjust(Duration.millis(1));
      expect(yield* Fiber.join(fiber)).toEqual({ launched: true });
      expect(yield* Ref.get(opens)).toBe(1);
    }),
  );

  effectIt.effect("does nothing when a refusing socket answers within the window (#637)", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const available = yield* Ref.make(false);
      const fiber = yield* launchInfinitusAtStartup({
        platform: "darwin",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(available, SOCKET, "ECONNREFUSED")), Effect.forkChild);
      // Refused at 3 s and 5 s; the relaunched app is listening by the 7 s probe.
      yield* TestClock.adjust(Duration.sum(STARTUP_GRACE, RELAUNCH_REPROBE));
      expect(yield* Ref.get(opens)).toBe(0);
      yield* Ref.set(available, true);
      yield* TestClock.adjust(RELAUNCH_REPROBE);
      expect(yield* Fiber.join(fiber)).toBeNull();
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );

  effectIt.effect(
    "still opens the app when the relaunch finishes with no socket left (ENOENT)",
    () =>
      Effect.gen(function* () {
        // Refusing during the grace, gone after it: the old instance's file was
        // replaced by nothing — the app is not coming back on its own.
        const opens = yield* Ref.make(0);
        const cause = yield* Ref.make("ECONNREFUSED");
        const layer = Layer.succeed(InfinitusControlClient, {
          socketPath: SOCKET,
          request: () =>
            Effect.gen(function* () {
              return yield* new InfinitusUnavailable({
                path: SOCKET,
                cause: yield* Ref.get(cause),
              });
            }),
        } satisfies InfinitusControlClientShape);
        const fiber = yield* launchInfinitusAtStartup({
          platform: "darwin",
          runOpen: openStub(opens),
          nested: null,
        }).pipe(Effect.provide(layer), Effect.forkChild);
        yield* Ref.set(cause, "ENOENT");
        yield* TestClock.adjust(STARTUP_GRACE);
        expect(yield* Fiber.join(fiber)).toEqual({ launched: true });
        expect(yield* Ref.get(opens)).toBe(1);
      }),
  );

  effectIt.effect("does nothing when the app is already up, and never off macOS", () =>
    Effect.gen(function* () {
      const opens = yield* Ref.make(0);
      const up = yield* launchInfinitusAtStartup({
        platform: "darwin",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(yield* Ref.make(true))));
      const linux = yield* launchInfinitusAtStartup({
        platform: "linux",
        runOpen: openStub(opens),
        nested: null,
      }).pipe(Effect.provide(clientLayer(yield* Ref.make(false))));
      expect(up).toBeNull();
      expect(linux).toBeNull();
      expect(yield* Ref.get(opens)).toBe(0);
    }),
  );
});
