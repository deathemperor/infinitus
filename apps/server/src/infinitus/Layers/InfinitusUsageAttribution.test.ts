import {
  type InfinitusManifestCommand,
  type InfinitusSnapshot,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import { InfinitusService } from "../Services/Infinitus.ts";
import {
  InfinitusControlClient,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";
import { UsageAttribution } from "../Services/UsageAttribution.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import { InfinitusUsageAttributionLive } from "./InfinitusUsageAttribution.ts";

const command = (name: string, effect: "read" | "write" = "read"): InfinitusManifestCommand => ({
  name,
  args: [],
  options: [],
  effect,
  summary: "",
  replyShape: "",
});

const fleet = {
  key: "claude",
  engineID: "swapd",
  provider: "claude",
  capabilities: ["history"],
  accounts: [
    {
      number: 1,
      alias: "work",
      email: "one@example.invalid",
      active: true,
      isOrganization: false,
      usageStatus: "fresh",
    },
  ],
} as unknown as InfinitusSnapshot["fleets"][number];

const snapshotWith = (commands: ReadonlyArray<InfinitusManifestCommand>): InfinitusSnapshot => ({
  available: true,
  fleets: [fleet],
  sessions: [],
  commands,
});

const notPolled: InfinitusSnapshot = {
  available: false,
  unavailableReason: NOT_POLLED_REASON,
  fleets: [],
  sessions: [],
  commands: [],
};

const history = {
  fleet: "claude",
  history: {
    switches: [
      {
        ts: "2026-08-01T09:00:00Z",
        to: { slot: 1, email: "one@example.invalid" },
        trigger: "manual",
      },
      {
        ts: "2026-08-02T09:00:00Z",
        from: { slot: 1, email: "one@example.invalid" },
        to: { slot: 2, email: "two@example.invalid" },
        trigger: "failover",
      },
    ],
  },
};

const makeHarness = (input: {
  readonly initial?: InfinitusSnapshot;
  readonly reply?: Effect.Effect<unknown, InfinitusUnavailable>;
}) =>
  Effect.gen(function* () {
    const current = yield* Ref.make(input.initial ?? snapshotWith([command("history")]));
    const requests = yield* Ref.make<ReadonlyArray<InfinitusControlRequestInput>>([]);
    const refreshes = yield* Ref.make(0);
    const layer = InfinitusUsageAttributionLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(InfinitusService)({
            snapshot: Ref.get(current),
            refresh: Ref.update(refreshes, (n) => n + 1).pipe(
              Effect.andThen(Ref.set(current, snapshotWith([command("history")]))),
            ),
            changes: () => Stream.empty,
            observed: Stream.empty,
          }),
          Layer.mock(InfinitusControlClient)({
            socketPath: "/tmp/test.sock",
            request: (request) =>
              Ref.update(requests, (list) => [...list, request]).pipe(
                Effect.andThen(input.reply ?? Effect.succeed(history)),
              ),
          }),
        ),
      ),
    );
    const context = yield* Layer.build(layer);
    return {
      resolve: Context.get(context, UsageAttribution).resolve,
      requests: Ref.get(requests),
      refreshes: Ref.get(refreshes),
    };
  });

describe("InfinitusUsageAttributionLive", () => {
  effectIt.effect("reads the history verb once and answers the timeline", () =>
    Effect.gen(function* () {
      const harness = yield* makeHarness({});
      const timeline = yield* harness.resolve;

      expect(yield* harness.requests).toEqual([
        { command: "history", args: ["claude"], options: {} },
      ]);
      expect(timeline?.accountAt(Date.parse("2026-08-01T12:00:00Z"))).toBe("one@example.invalid");
      expect(timeline?.accountAt(Date.parse("2026-08-03T12:00:00Z"))).toBe("two@example.invalid");
      expect(timeline?.describe("one@example.invalid")).toEqual({ label: "work", number: 1 });
      expect(timeline?.describe("two@example.invalid")).toEqual({ label: "two@example.invalid" });
      expect(timeline?.switchesAtMs).toEqual([
        Date.parse("2026-08-01T09:00:00Z"),
        Date.parse("2026-08-02T09:00:00Z"),
      ]);
      expect(timeline?.basis).toBe("swapd history");
    }),
  );

  effectIt.effect("answers nothing when the manifest has no history verb, without a request", () =>
    Effect.gen(function* () {
      const harness = yield* makeHarness({ initial: snapshotWith([command("status")]) });
      expect(yield* harness.resolve).toBeNull();
      expect(yield* harness.requests).toEqual([]);
    }),
  );

  effectIt.effect("asks only a Claude fleet whose engine has the history capability", () =>
    Effect.gen(function* () {
      const noCapability = yield* makeHarness({
        initial: {
          ...snapshotWith([command("history")]),
          fleets: [{ ...fleet, capabilities: [] }],
        },
      });
      expect(yield* noCapability.resolve).toBeNull();
      expect(yield* noCapability.requests).toEqual([]);

      const twoFleets = yield* makeHarness({
        initial: {
          ...snapshotWith([command("history")]),
          fleets: [
            { ...fleet, key: "cswap", capabilities: [] },
            { ...fleet, key: "swapd" },
          ],
        },
      });
      expect(yield* twoFleets.resolve).not.toBeNull();
      expect(yield* twoFleets.requests).toEqual([
        { command: "history", args: ["swapd"], options: {} },
      ]);
    }),
  );

  effectIt.effect("refreshes a never-polled snapshot once before deciding", () =>
    Effect.gen(function* () {
      const harness = yield* makeHarness({ initial: notPolled });
      expect(yield* harness.resolve).not.toBeNull();
      expect(yield* harness.refreshes).toBe(1);
    }),
  );

  effectIt.effect("answers nothing when the app is unreachable or the verb fails", () =>
    Effect.gen(function* () {
      const unreachable = yield* makeHarness({
        initial: { ...notPolled, unavailableReason: "connection refused" },
      });
      expect(yield* unreachable.resolve).toBeNull();

      const failing = yield* makeHarness({
        reply: new InfinitusUnavailable({ path: "/tmp/test.sock", cause: "busy" }),
      });
      expect(yield* failing.resolve).toBeNull();
    }),
  );
});
