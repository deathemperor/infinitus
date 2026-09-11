import {
  type OrchestrationCommand,
  type OrchestrationEvent,
  type OrchestrationThreadShell,
  ProviderDriverKind,
  ProviderInstanceId,
  ThreadId,
  TurnId,
} from "@t3tools/contracts";
import type {
  InfinitusFleet,
  InfinitusHeldThread,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as Deferred from "effect/Deferred";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as PubSub from "effect/PubSub";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { TurnStartGate } from "../../orchestration/Services/TurnStartGate.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusSessionHold } from "../Services/InfinitusSessionHold.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import { InfinitusSessionHoldLayers } from "./InfinitusSessionHold.ts";
import { HOLD_MARKER_KIND, RELEASE_MARKER_KIND } from "./infinitusSessionHold.logic.ts";

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");
const claudeInstance = ProviderInstanceId.make("claude-1");
const codexInstance = ProviderInstanceId.make("codex-1");

const fleet = (overrides: Partial<InfinitusFleet> = {}): InfinitusFleet => ({
  key: "swapd/claude",
  engineID: "swapd",
  provider: "claude",
  capabilities: [],
  accounts: [
    { number: 1, email: "one@example.com", active: true, isOrganization: false, usageStatus: "ok" },
  ],
  ...overrides,
});

const snapshotWith = (fleets: ReadonlyArray<InfinitusFleet>): InfinitusSnapshot => ({
  available: true,
  fleets,
  sessions: [],
  commands: [],
});

const low = snapshotWith([fleet({ headroom: { state: "low", window: "5h", pct: 84 } })]);
const abundant = snapshotWith([fleet({ headroom: { state: "abundant" } })]);
const silent = snapshotWith([fleet()]);
const offline: InfinitusSnapshot = {
  available: false,
  unavailableReason: "connection refused",
  fleets: [],
  sessions: [],
  commands: [],
};
/** What `snapshot` answers before the first poll on a server nobody watches. */
const notPolled: InfinitusSnapshot = {
  available: false,
  unavailableReason: NOT_POLLED_REASON,
  fleets: [],
  sessions: [],
  commands: [],
};

const shellFor = (
  threadId: ThreadId,
  overrides: Partial<OrchestrationThreadShell> = {},
): OrchestrationThreadShell =>
  ({
    id: threadId,
    archivedAt: null,
    pinnedAt: null,
    modelSelection: { instanceId: claudeInstance, model: "claude-opus-5" },
    session: null,
    ...overrides,
  }) as unknown as OrchestrationThreadShell;

const domainEvent = (type: OrchestrationEvent["type"], threadId: ThreadId): OrchestrationEvent =>
  ({ type, aggregateKind: "thread", aggregateId: threadId, payload: { threadId } }) as never;

const testCrypto = Crypto.make({
  randomBytes: (size) => new Uint8Array(size).fill(1),
  digest: (_algorithm, data) => Effect.succeed(data),
});

const makeHarness = Effect.gen(function* () {
  const snapshots = yield* Queue.unbounded<InfinitusSnapshot>();
  const current = yield* Ref.make<InfinitusSnapshot>(low);
  const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
  const shells = yield* Ref.make<ReadonlyMap<ThreadId, OrchestrationThreadShell>>(
    new Map([
      [one, shellFor(one)],
      [two, shellFor(two)],
    ]),
  );
  const ran = yield* Ref.make<ReadonlyArray<string>>([]);
  const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);
  const watchers = yield* Ref.make(0);
  const refreshes = yield* Ref.make(0);
  /** Set, a snapshot read parks here: the decision is "still being read". */
  const snapshotGate = yield* Ref.make<Deferred.Deferred<void> | null>(null);
  const snapshotReads = yield* Ref.make(0);

  const layer = InfinitusSessionHoldLayers.pipe(
    Layer.provide(
      Layer.mergeAll(
        Layer.mock(ProviderService)({
          getInstanceInfo: (instanceId) =>
            Effect.succeed({
              instanceId,
              driverKind: ProviderDriverKind.make(
                instanceId === codexInstance
                  ? "codex"
                  : instanceId === claudeInstance
                    ? "claudeAgent"
                    : "opencode",
              ),
              displayName: undefined,
              enabled: true,
              continuationIdentity: { driverKind: "claudeAgent", continuationKey: "k" },
            } as never),
        }),
        Layer.mock(OrchestrationEngineService)({
          dispatch: (command) =>
            Ref.update(dispatched, (previous) => [...previous, command]).pipe(
              Effect.as({ sequence: 1 }),
            ),
          get streamDomainEvents() {
            return Stream.fromPubSub(domainEvents);
          },
        }),
        Layer.mock(ProjectionSnapshotQuery)({
          getThreadShellById: (threadId) =>
            Ref.get(shells).pipe(Effect.map((map) => Option.fromNullishOr(map.get(threadId)))),
        }),
        Layer.mock(InfinitusService)({
          snapshot: Effect.gen(function* () {
            yield* Ref.update(snapshotReads, (n) => n + 1);
            const gate = yield* Ref.get(snapshotGate);
            if (gate !== null) yield* Deferred.await(gate);
            return yield* Ref.get(current);
          }),
          changes: () =>
            Stream.unwrap(
              Effect.acquireRelease(
                Ref.update(watchers, (n) => n + 1),
                () => Ref.update(watchers, (n) => n - 1),
              ).pipe(Effect.as(Stream.fromQueue(snapshots))),
            ),
          observed: Stream.empty,
          // A refresh polls for real: here it lands the low reading.
          refresh: Ref.update(refreshes, (n) => n + 1).pipe(Effect.andThen(Ref.set(current, low))),
        }),
        Layer.succeed(Crypto.Crypto, testCrypto),
      ),
    ),
  );
  const context = yield* Layer.build(layer);
  const gate = Context.get(context, TurnStartGate);
  const hold = Context.get(context, InfinitusSessionHold);

  return {
    start: (threadId: ThreadId, label: string = String(threadId)) =>
      gate.start({ threadId, run: Ref.update(ran, (list) => [...list, label]) }),
    startReplacing: (threadId: ThreadId) =>
      gate.start({
        threadId,
        replacesActiveTurn: true,
        run: Ref.update(ran, (list) => [...list, String(threadId)]),
      }),
    poll: (snapshot: InfinitusSnapshot) => Queue.offer(snapshots, snapshot).pipe(Effect.asVoid),
    setCurrent: (snapshot: InfinitusSnapshot) => Ref.set(current, snapshot),
    setShell: (shell: OrchestrationThreadShell) =>
      Ref.update(shells, (map) => new Map([...map, [shell.id, shell]])),
    emit: (event: OrchestrationEvent) => PubSub.publish(domainEvents, event).pipe(Effect.asVoid),
    release: hold.release,
    held: hold.held,
    ran: Ref.get(ran),
    dispatched: Ref.get(dispatched),
    markers: Ref.get(dispatched).pipe(
      Effect.map((commands) =>
        commands.flatMap((command) =>
          command.type === "thread.activity.append"
            ? [
                {
                  threadId: command.threadId,
                  kind: command.activity.kind,
                  summary: command.activity.summary,
                },
              ]
            : [],
        ),
      ),
    ),
    watchers: Ref.get(watchers),
    refreshes: Ref.get(refreshes),
    gateSnapshot: (gate: Deferred.Deferred<void> | null) => Ref.set(snapshotGate, gate),
    snapshotReads: Ref.get(snapshotReads),
  };
});

/** Lets the layer's fibers run until `check` holds; the clock is a test one,
    so this yields rather than sleeps. */
const settle = <A>(read: Effect.Effect<A>, check: (value: A) => boolean) =>
  Effect.gen(function* () {
    for (let i = 0; i < 2_000; i += 1) {
      const value = yield* read;
      if (check(value)) return value;
      yield* Effect.yieldNow;
    }
    return yield* read;
  });

describe("InfinitusSessionHoldLayers", () => {
  effectIt.effect("holds a background thread's start while its fleet reads low", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;

        expect(yield* h.start(one)).toBe("held");
        yield* settle(h.watchers, (n) => n === 1);
        expect(yield* h.ran).toEqual([]);
        expect(yield* h.markers).toEqual([
          {
            threadId: one,
            kind: HOLD_MARKER_KIND,
            summary: "Held for headroom on claude, 5h window 84 %",
          },
        ]);
      }),
    ),
  );

  effectIt.effect.each([
    { label: "pinned", shell: shellFor(one, { pinnedAt: "2026-09-11T10:00:00Z" }), snapshot: low },
    {
      label: "mid-turn (a steer)",
      shell: shellFor(one, {
        session: { activeTurnId: TurnId.make("turn-1"), status: "running" } as never,
      }),
      snapshot: low,
    },
    { label: "on a fleet that publishes no headroom", shell: shellFor(one), snapshot: silent },
    { label: "on an abundant fleet", shell: shellFor(one), snapshot: abundant },
    {
      label: "on a driver no fleet covers",
      shell: shellFor(one, {
        modelSelection: { instanceId: ProviderInstanceId.make("other"), model: "m" } as never,
      }),
      snapshot: low,
    },
  ])("starts at once when $label", ({ shell, snapshot }) =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.setShell(shell);
        yield* h.setCurrent(snapshot);

        expect(yield* h.start(one)).toBe("started");
        expect(yield* h.ran).toEqual(["thread-1"]);
        expect(yield* h.markers).toEqual([]);
        expect(yield* h.watchers).toBe(0);
      }),
    ),
  );

  effectIt.effect("holds a start that replaces the active turn (a resume of a parked turn)", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.setShell(
          shellFor(one, {
            session: { activeTurnId: TurnId.make("turn-parked"), status: "running" } as never,
          }),
        );

        expect(yield* h.startReplacing(one)).toBe("held");
        expect(yield* h.ran).toEqual([]);
      }),
    ),
  );

  effectIt.effect("polls once for a real reading when nothing has been polled yet", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.setCurrent(notPolled);

        expect(yield* h.start(one)).toBe("held");
        expect(yield* h.refreshes).toBe(1);
        expect(yield* h.ran).toEqual([]);
      }),
    ),
  );

  effectIt.effect("does not poll again once a reading exists", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.setCurrent(abundant);

        expect(yield* h.start(one)).toBe("started");
        expect(yield* h.refreshes).toBe(0);
      }),
    ),
  );

  effectIt.effect("releases held starts when the fleet reads abundant, and stops watching", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one, "first");
        yield* h.start(one, "second");
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(low);
        yield* Effect.yieldNow;
        expect(yield* h.ran).toEqual([]);

        yield* h.poll(abundant);
        const ran = yield* settle(h.ran, (list) => list.length === 2);
        expect(ran).toEqual(["first", "second"]);
        const markers = yield* h.markers;
        expect(markers.map((marker) => marker.kind)).toEqual([
          HOLD_MARKER_KIND,
          RELEASE_MARKER_KIND,
        ]);
        expect(markers[1]?.summary).toBe("Released: headroom abundant on claude");
        yield* settle(h.watchers, (n) => n === 0);
      }),
    ),
  );

  effectIt.effect("releases when a real poll carries no verdict for the fleet (mode off)", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one);
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(silent);
        const ran = yield* settle(h.ran, (list) => list.length === 1);
        expect(ran).toEqual(["thread-1"]);
        expect((yield* h.markers)[1]?.summary).toBe("Released: no headroom verdict on claude");
        yield* settle(h.watchers, (n) => n === 0);
      }),
    ),
  );

  effectIt.effect("keeps holding while the app cannot be reached", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one);
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(offline);
        yield* Effect.yieldNow;
        yield* Effect.yieldNow;
        expect(yield* h.ran).toEqual([]);
        expect(yield* h.watchers).toBe(1);
      }),
    ),
  );

  effectIt.effect("spaces two threads' releases apart", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one);
        yield* h.start(two);
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(abundant);
        yield* settle(h.ran, (list) => list.length === 1);
        expect(yield* h.ran).toEqual(["thread-1"]);
        yield* TestClock.adjust(Duration.seconds(2));
        const ran = yield* settle(h.ran, (list) => list.length === 2);
        expect(ran).toEqual(["thread-1", "thread-2"]);
      }),
    ),
  );

  effectIt.effect("skips a thread archived while it waited its turn in a release", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one);
        yield* h.start(two);
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(abundant);
        yield* settle(h.ran, (list) => list.length === 1);
        yield* h.setShell(shellFor(two, { archivedAt: "2026-09-11T10:00:00Z" }));
        yield* TestClock.adjust(Duration.seconds(2));
        yield* settle(h.watchers, (n) => n === 0);
        expect(yield* h.ran).toEqual(["thread-1"]);
        expect((yield* h.markers).map((marker) => [marker.threadId, marker.kind])).toEqual([
          [one, HOLD_MARKER_KIND],
          [two, HOLD_MARKER_KIND],
          [one, RELEASE_MARKER_KIND],
        ]);
      }),
    ),
  );

  effectIt.effect("releases a held thread the moment it is pinned", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one);
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.emit(domainEvent("thread.pinned", one));
        const ran = yield* settle(h.ran, (list) => list.length === 1);
        expect(ran).toEqual(["thread-1"]);
        expect((yield* h.markers)[1]?.summary).toBe("Released: pinned");
        yield* settle(h.watchers, (n) => n === 0);
      }),
    ),
  );

  effectIt.effect(
    "a pin that lands while the start's decision is still being read runs it instead of holding it",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness;
          const reading = yield* Deferred.make<void>();
          yield* h.gateSnapshot(reading);
          const start = yield* Effect.forkChild(h.start(one));
          yield* settle(h.snapshotReads, (n) => n === 1);

          // The pin arrives, and its event is handled, before the decision lands.
          yield* h.setShell(shellFor(one, { pinnedAt: "2026-09-11T10:00:00Z" }));
          yield* h.emit(domainEvent("thread.pinned", one));
          for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;

          yield* Deferred.succeed(reading, undefined);
          yield* Fiber.join(start);
          const ran = yield* settle(h.ran, (list) => list.length === 1);
          expect(ran).toEqual(["thread-1"]);
          expect(yield* h.markers).toEqual([]);
          yield* settle(h.watchers, (n) => n === 0);
        }),
      ),
  );

  effectIt.effect(
    "publishes the held threads: the list now, then again on every change (#741)",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness;
          const seen = yield* Ref.make<ReadonlyArray<ReadonlyArray<InfinitusHeldThread>>>([]);
          yield* Effect.forkScoped(
            Stream.runForEach(h.held, (list) => Ref.update(seen, (lists) => [...lists, list])),
          );
          expect(yield* settle(Ref.get(seen), (lists) => lists.length === 1)).toEqual([[]]);

          yield* h.start(one);
          const afterHold = yield* settle(Ref.get(seen), (lists) => lists.length === 2);
          expect(afterHold[1]).toEqual([
            {
              threadId: one,
              since: expect.any(String),
              summary: "Held for headroom on claude, 5h window 84 %",
            },
          ]);

          yield* h.poll(abundant);
          const afterRelease = yield* settle(Ref.get(seen), (lists) => lists.length === 3);
          expect(afterRelease[2]).toEqual([]);
          expect(yield* h.ran).toEqual(["thread-1"]);
        }),
      ),
  );

  effectIt.effect("releases on the user's word, once", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one);
        yield* settle(h.watchers, (n) => n === 1);

        expect(yield* h.release(one)).toEqual({ released: true });
        const ran = yield* settle(h.ran, (list) => list.length === 1);
        expect(ran).toEqual(["thread-1"]);
        expect((yield* h.markers)[1]?.summary).toBe("Released: run now");
        expect(yield* h.release(one)).toEqual({ released: false, reason: "nothing is held" });
      }),
    ),
  );

  effectIt.effect("forgets a held thread that is archived, without running it", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.start(one);
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.emit(domainEvent("thread.archived", one));
        yield* settle(h.watchers, (n) => n === 0);
        yield* h.poll(abundant);
        yield* Effect.yieldNow;
        expect(yield* h.ran).toEqual([]);
        expect((yield* h.markers).map((marker) => marker.kind)).toEqual([HOLD_MARKER_KIND]);
      }),
    ),
  );
});
