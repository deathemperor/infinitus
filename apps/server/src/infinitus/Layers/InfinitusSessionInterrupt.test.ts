import {
  DEFAULT_PROVIDER_INTERACTION_MODE,
  EventId,
  type OrchestrationCommand,
  type OrchestrationEvent,
  type OrchestrationThreadShell,
  ProviderDriverKind,
  type ProviderRuntimeEvent,
  ThreadId,
  TurnId,
} from "@t3tools/contracts";
import type {
  InfinitusFleet,
  InfinitusPrefs,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
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
import {
  TurnStartGate,
  TurnStartGatePassthrough,
  type TurnStartGateShape,
} from "../../orchestration/Services/TurnStartGate.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusSessionInterrupt } from "../Services/InfinitusSessionInterrupt.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import { CONTINUATION_PROMPT } from "./infinitusResumeOnLimit.logic.ts";
import { InfinitusSessionInterruptLive } from "./InfinitusSessionInterrupt.ts";
import { PAUSE_MARKER_KIND, RESUME_MARKER_KIND } from "./infinitusSessionInterrupt.logic.ts";

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");
const turnOne = TurnId.make("turn-1");
const turnTwo = TurnId.make("turn-2");
const claude = ProviderDriverKind.make("claudeAgent");
const codex = ProviderDriverKind.make("codex");
const opencode = ProviderDriverKind.make("opencode");

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

/** The catalog row that arms this layer: the reading at turn start decides
    whether running turns are watched at all. */
const prefs = (mode: string): InfinitusPrefs => ({
  sections: [],
  prefs: [
    {
      key: "priority_mode",
      type: "string",
      default: "off",
      value: mode,
      section: "sessions",
      effect: "live",
    },
  ],
});

const snapshotWith = (
  fleets: ReadonlyArray<InfinitusFleet>,
  mode: string = "interrupt",
): InfinitusSnapshot => ({
  available: true,
  fleets,
  sessions: [],
  commands: [],
  prefs: prefs(mode),
});

const low = snapshotWith([fleet({ headroom: { state: "low", window: "5h", pct: 84 } })]);
const critical = snapshotWith([fleet({ headroom: { state: "critical", window: "5h", pct: 92 } })]);
const abundant = snapshotWith([fleet({ headroom: { state: "abundant" } })]);
const silent = snapshotWith([fleet()]);
/** Hold mode: `low` at most, and the pref says so. */
const lowHold = snapshotWith(
  [fleet({ headroom: { state: "low", window: "5h", pct: 84 } })],
  "hold",
);
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
    interactionMode: DEFAULT_PROVIDER_INTERACTION_MODE,
    session: null,
    ...overrides,
  }) as unknown as OrchestrationThreadShell;

/** A thread whose session names `turnId` as the running turn. */
const runningShell = (
  threadId: ThreadId,
  turnId: TurnId,
  overrides: Partial<OrchestrationThreadShell> = {},
) =>
  shellFor(threadId, {
    session: { activeTurnId: turnId, status: "running" } as never,
    ...overrides,
  });

let eventCount = 0;
const runtimeEvent = (
  type: ProviderRuntimeEvent["type"],
  threadId: ThreadId,
  turnId: TurnId | undefined,
  provider: ProviderDriverKind = claude,
): ProviderRuntimeEvent =>
  ({
    type,
    eventId: EventId.make(`evt-${(eventCount += 1)}`),
    provider,
    createdAt: "2026-09-11T10:00:00Z",
    threadId,
    ...(turnId === undefined ? {} : { turnId }),
    payload: {},
  }) as ProviderRuntimeEvent;

const domainEvent = (type: OrchestrationEvent["type"], threadId: ThreadId): OrchestrationEvent =>
  ({ type, aggregateKind: "thread", aggregateId: threadId, payload: { threadId } }) as never;

const testCrypto = Crypto.make({
  randomBytes: (size) => new Uint8Array(size).fill(1),
  digest: (_algorithm, data) => Effect.succeed(data),
});

/** The gate a resume passes through; passthrough by default. */
const makeHarnessWith = (gate?: TurnStartGateShape) =>
  Effect.gen(function* () {
    const events = yield* PubSub.unbounded<ProviderRuntimeEvent>();
    const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
    const snapshots = yield* Queue.unbounded<InfinitusSnapshot>();
    const current = yield* Ref.make<InfinitusSnapshot>(low);
    const shells = yield* Ref.make<ReadonlyMap<ThreadId, OrchestrationThreadShell>>(
      new Map([
        [one, runningShell(one, turnOne)],
        [two, runningShell(two, turnTwo)],
      ]),
    );
    const turns = yield* Ref.make<ReadonlyArray<{ threadId: ThreadId; input: string }>>([]);
    const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);
    const watchers = yield* Ref.make(0);
    const refreshes = yield* Ref.make(0);

    const layer = InfinitusSessionInterruptLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          gate === undefined ? TurnStartGatePassthrough : Layer.succeed(TurnStartGate, gate),
          Layer.mock(ProviderService)({
            get streamEvents() {
              return Stream.fromPubSub(events);
            },
            sendTurn: (input) =>
              Ref.update(turns, (previous) => [
                ...previous,
                { threadId: input.threadId, input: input.input ?? "" },
              ]).pipe(Effect.as({ turnId: turnTwo, resumeCursor: null } as never)),
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
            snapshot: Ref.get(current),
            changes: () =>
              Stream.unwrap(
                Effect.acquireRelease(
                  Ref.update(watchers, (n) => n + 1),
                  () => Ref.update(watchers, (n) => n - 1),
                ).pipe(Effect.as(Stream.fromQueue(snapshots))),
              ),
            observed: Stream.empty,
            // A refresh polls for real: here it lands the low reading.
            refresh: Ref.update(refreshes, (n) => n + 1).pipe(
              Effect.andThen(Ref.set(current, low)),
            ),
          }),
          Layer.succeed(Crypto.Crypto, testCrypto),
        ),
      ),
    );
    const context = yield* Layer.build(layer);
    const interrupt = Context.get(context, InfinitusSessionInterrupt);
    // The forked streams subscribe on their first step; an event published
    // before that reaches nobody.
    for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;

    return {
      emit: (event: ProviderRuntimeEvent) => PubSub.publish(events, event).pipe(Effect.asVoid),
      emitDomain: (event: OrchestrationEvent) =>
        PubSub.publish(domainEvents, event).pipe(Effect.asVoid),
      poll: (snapshot: InfinitusSnapshot) => Queue.offer(snapshots, snapshot).pipe(Effect.asVoid),
      setCurrent: (snapshot: InfinitusSnapshot) => Ref.set(current, snapshot),
      setShell: (shell: OrchestrationThreadShell) =>
        Ref.update(shells, (map) => new Map([...map, [shell.id, shell]])),
      resume: interrupt.resume,
      pausedThreads: interrupt.pausedThreads,
      turns: Ref.get(turns),
      interrupts: Ref.get(dispatched).pipe(
        Effect.map((commands) =>
          commands.flatMap((command) =>
            command.type === "thread.turn.interrupt"
              ? [{ threadId: command.threadId, turnId: command.turnId }]
              : [],
          ),
        ),
      ),
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
    };
  });
const makeHarness = makeHarnessWith();

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

/** A turn started and, after the fleet flipped to critical, paused. */
const pausedOne = (h: Effect.Success<typeof makeHarness>) =>
  Effect.gen(function* () {
    yield* h.emit(runtimeEvent("turn.started", one, turnOne));
    yield* settle(h.watchers, (n) => n === 1);
    yield* h.poll(critical);
    yield* settle(h.interrupts, (list) => list.length === 1);
    // The projection would clear the session's turn on the interrupt; here we do.
    yield* h.setShell(shellFor(one));
  });

describe("InfinitusSessionInterruptLive", () => {
  effectIt.effect("pauses a running background turn when its fleet reads critical", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(critical);
        const interrupts = yield* settle(h.interrupts, (list) => list.length === 1);
        expect(interrupts).toEqual([{ threadId: one, turnId: turnOne }]);
        expect(yield* h.markers).toEqual([
          {
            threadId: one,
            kind: PAUSE_MARKER_KIND,
            summary: "Paused for headroom on claude, 5h window 92 %",
          },
        ]);
        // Paused: still watching, and a second critical reading changes nothing.
        yield* h.poll(critical);
        yield* Effect.yieldNow;
        yield* Effect.yieldNow;
        expect((yield* h.interrupts).length).toBe(1);
        expect(yield* h.watchers).toBe(1);
      }),
    ),
  );

  effectIt.effect.each([
    { label: "pinned", shell: runningShell(one, turnOne, { pinnedAt: "2026-09-11T10:00:00Z" }) },
    { label: "already on another turn", shell: runningShell(one, turnTwo) },
    { label: "between turns", shell: shellFor(one) },
    { label: "archived", shell: shellFor(one, { archivedAt: "2026-09-11T10:00:00Z" }) },
  ])("never interrupts a thread that is $label", ({ shell }) =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.setShell(shell);
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(critical);
        yield* Effect.yieldNow;
        yield* Effect.yieldNow;
        expect(yield* h.interrupts).toEqual([]);
        expect(yield* h.markers).toEqual([]);
      }),
    ),
  );

  effectIt.effect("leaves turns on other drivers alone", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(runtimeEvent("turn.started", one, turnOne, opencode));
        yield* h.emit(runtimeEvent("turn.started", two, turnTwo, codex));
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(critical);
        yield* Effect.yieldNow;
        yield* Effect.yieldNow;
        expect(yield* h.interrupts).toEqual([]);
      }),
    ),
  );

  effectIt.effect("keeps running turns while the fleet reads only low", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(low);
        yield* Effect.yieldNow;
        yield* Effect.yieldNow;
        expect(yield* h.interrupts).toEqual([]);
        expect(yield* h.watchers).toBe(1);
      }),
    ),
  );

  effectIt.effect("does not watch at all outside interrupt mode", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.setCurrent(lowHold);
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;
        expect(yield* h.watchers).toBe(0);
      }),
    ),
  );

  effectIt.effect("polls once for a real reading when nothing has been polled yet", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.setCurrent(notPolled);
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        yield* settle(h.watchers, (n) => n === 1);
        expect(yield* h.refreshes).toBe(1);

        yield* h.emit(runtimeEvent("turn.started", two, turnTwo));
        for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;
        expect(yield* h.refreshes).toBe(1);
      }),
    ),
  );

  effectIt.effect(
    "keeps a turn the session does not name yet (projection lag) for the next reading",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness;
          yield* h.setShell(shellFor(one));
          yield* h.emit(runtimeEvent("turn.started", one, turnOne));
          yield* settle(h.watchers, (n) => n === 1);

          yield* h.poll(critical);
          for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;
          expect(yield* h.interrupts).toEqual([]);
          yield* h.setShell(runningShell(one, turnOne));
          yield* h.poll(critical);
          const interrupts = yield* settle(h.interrupts, (list) => list.length === 1);
          expect(interrupts).toEqual([{ threadId: one, turnId: turnOne }]);
        }),
      ),
  );

  effectIt.effect("stops watching when the session exits, even without a turn id", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.emit(runtimeEvent("session.exited", one, undefined));
        yield* settle(h.watchers, (n) => n === 0);
      }),
    ),
  );

  effectIt.effect("stops watching when the last running turn ends", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.emit(runtimeEvent("turn.completed", one, turnOne));
        yield* settle(h.watchers, (n) => n === 0);
        yield* h.poll(critical);
        yield* Effect.yieldNow;
        expect(yield* h.interrupts).toEqual([]);
      }),
    ),
  );

  effectIt.effect("continues a paused turn when the fleet reads abundant, and stops watching", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* pausedOne(h);

        yield* h.poll(abundant);
        const turns = yield* settle(h.turns, (list) => list.length === 1);
        expect(turns).toEqual([{ threadId: one, input: CONTINUATION_PROMPT }]);
        const markers = yield* h.markers;
        expect(markers.map((marker) => marker.kind)).toEqual([
          PAUSE_MARKER_KIND,
          RESUME_MARKER_KIND,
        ]);
        expect(markers[1]?.summary).toBe("Resumed: headroom abundant on claude");
        yield* settle(h.watchers, (n) => n === 0);
      }),
    ),
  );

  effectIt.effect("continues when a real poll carries no verdict for the fleet (mode off)", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* pausedOne(h);

        yield* h.poll(silent);
        yield* settle(h.turns, (list) => list.length === 1);
        expect((yield* h.markers)[1]?.summary).toBe("Resumed: no headroom verdict on claude");
      }),
    ),
  );

  effectIt.effect("keeps a turn paused while the app cannot be reached", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* pausedOne(h);

        yield* h.poll(offline);
        yield* Effect.yieldNow;
        yield* Effect.yieldNow;
        expect(yield* h.turns).toEqual([]);
        expect(yield* h.watchers).toBe(1);
      }),
    ),
  );

  effectIt.effect("resumes through the gate: a fleet still low holds the continuation", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarnessWith({ start: () => Effect.succeed("held" as const) });
        yield* pausedOne(h);

        yield* h.poll(abundant);
        yield* settle(h.watchers, (n) => n === 0);
        expect(yield* h.turns).toEqual([]);
        expect((yield* h.markers).map((marker) => marker.kind)).toEqual([PAUSE_MARKER_KIND]);
      }),
    ),
  );

  effectIt.effect("spaces two threads' continuations apart, oldest first", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(runtimeEvent("turn.started", one, turnOne));
        yield* h.emit(runtimeEvent("turn.started", two, turnTwo));
        yield* settle(h.watchers, (n) => n === 1);
        yield* h.poll(critical);
        yield* settle(h.interrupts, (list) => list.length === 2);
        yield* h.setShell(shellFor(one));
        yield* h.setShell(shellFor(two));

        yield* h.poll(abundant);
        yield* settle(h.turns, (list) => list.length === 1);
        expect((yield* h.turns).map((turn) => turn.threadId)).toEqual([one]);
        yield* TestClock.adjust(Duration.seconds(2));
        const turns = yield* settle(h.turns, (list) => list.length === 2);
        expect(turns.map((turn) => turn.threadId)).toEqual([one, two]);
      }),
    ),
  );

  effectIt.effect("continues a paused thread the moment it is pinned", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* pausedOne(h);

        yield* h.emitDomain(domainEvent("thread.pinned", one));
        yield* settle(h.turns, (list) => list.length === 1);
        expect((yield* h.markers)[1]?.summary).toBe("Resumed: pinned");
        yield* settle(h.watchers, (n) => n === 0);
      }),
    ),
  );

  effectIt.effect("publishes the paused threads, then the empty list on resume (#806)", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        const seen = yield* Ref.make<ReadonlyArray<ReadonlyArray<ThreadId>>>([]);
        yield* Effect.forkScoped(
          Stream.runForEach(h.pausedThreads, (list) => Ref.update(seen, (all) => [...all, list])),
        );
        yield* settle(Ref.get(seen), (all) => all.length === 1);
        expect((yield* Ref.get(seen))[0]).toEqual([]);

        yield* pausedOne(h);
        yield* settle(Ref.get(seen), (all) => all.at(-1)?.includes(one) === true);

        expect(yield* h.resume(one)).toEqual({ released: true });
        yield* settle(Ref.get(seen), (all) => all.at(-1)?.length === 0);
        expect(yield* Ref.get(seen)).toEqual([[], [one], []]);
      }),
    ),
  );

  effectIt.effect("continues on the user's word, whatever the fleet reads, once", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarnessWith({ start: () => Effect.succeed("held" as const) });
        yield* pausedOne(h);

        expect(yield* h.resume(one)).toEqual({ released: true });
        yield* settle(h.turns, (list) => list.length === 1);
        expect((yield* h.markers)[1]?.summary).toBe("Resumed: resume now");
        expect(yield* h.resume(one)).toEqual({ released: false, reason: "nothing is paused" });
      }),
    ),
  );

  effectIt.effect("forgets a paused thread the user sends into", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* pausedOne(h);

        yield* h.emit(runtimeEvent("turn.started", one, turnTwo));
        yield* h.emit(runtimeEvent("turn.completed", one, turnTwo));
        yield* settle(h.watchers, (n) => n === 0);
        yield* h.poll(abundant);
        yield* Effect.yieldNow;
        expect(yield* h.turns).toEqual([]);
      }),
    ),
  );

  effectIt.effect("forgets a paused thread that is archived, without continuing it", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* pausedOne(h);

        yield* h.emitDomain(domainEvent("thread.archived", one));
        yield* settle(h.watchers, (n) => n === 0);
        yield* h.poll(abundant);
        yield* Effect.yieldNow;
        expect(yield* h.turns).toEqual([]);
        expect((yield* h.markers).map((marker) => marker.kind)).toEqual([PAUSE_MARKER_KIND]);
      }),
    ),
  );
});
