import {
  DEFAULT_PROVIDER_INTERACTION_MODE,
  DEFAULT_RUNTIME_MODE,
  DEFAULT_SERVER_SETTINGS,
  EventId,
  type OrchestrationCommand,
  type OrchestrationThreadShell,
  ProviderDriverKind,
  type ProviderRuntimeEvent,
  ThreadId,
  TurnId,
} from "@t3tools/contracts";
import type {
  InfinitusAccount,
  InfinitusHeldThread,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Context from "effect/Context";
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
  type TurnStartInput,
} from "../../orchestration/Services/TurnStartGate.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import { InfinitusResumeOnLimitLive } from "./InfinitusResumeOnLimit.ts";
import {
  CONTINUATION_PROMPT,
  LIMIT_MARKER_KIND,
  RESUME_MARKER_KIND,
} from "./infinitusResumeOnLimit.logic.ts";

const threadId = ThreadId.make("thread-1");
const turnId = TurnId.make("turn-1");
const claude = ProviderDriverKind.make("claudeAgent");

const account = (
  number: number,
  email: string,
  overrides: Partial<InfinitusAccount> = {},
): InfinitusAccount => ({
  number,
  email,
  active: false,
  isOrganization: false,
  usageStatus: "ok",
  ...overrides,
});

const snapshotWith = (accounts: ReadonlyArray<InfinitusAccount>): InfinitusSnapshot => ({
  available: true,
  fleets: [
    { key: "swapd/claude", engineID: "swapd", provider: "claude", capabilities: [], accounts },
  ],
  sessions: [],
  commands: [],
});

/** The engine still on the account that just ran out: no probe since. */
const stale = snapshotWith([
  account(1, "one@example.com", { active: true, usageStatus: "exhausted" }),
  account(2, "two@example.com"),
]);
/** Swapped, and the new account probed after the stop. */
const swapped = (fetchedAt: string) =>
  snapshotWith([
    account(1, "one@example.com", { usageStatus: "exhausted" }),
    account(2, "two@example.com", { active: true, usageFetchedAt: fetchedAt }),
  ]);

let eventCount = 0;
const runtimeEvent = (
  type: ProviderRuntimeEvent["type"],
  payload: unknown,
  turn: TurnId = turnId,
): ProviderRuntimeEvent =>
  ({
    type,
    eventId: EventId.make(`evt-${(eventCount += 1)}`),
    provider: claude,
    createdAt: "2026-09-11T10:00:00Z",
    threadId,
    turnId: turn,
    payload,
  }) as ProviderRuntimeEvent;

const parkedWarning = (turn: TurnId = turnId) =>
  runtimeEvent(
    "runtime.warning",
    {
      message: "Claude usage limit reached. This turn is paused until the 5-hour limit resets.",
      detail: { status: "rejected", rateLimitType: "five_hour" },
    },
    turn,
  );

const shell = {
  id: threadId,
  archivedAt: null,
  interactionMode: DEFAULT_PROVIDER_INTERACTION_MODE,
} as unknown as OrchestrationThreadShell;

const session = {
  threadId,
  status: "running" as const,
  providerName: "claudeAgent",
  runtimeMode: DEFAULT_RUNTIME_MODE,
  activeTurnId: turnId,
  lastError: null,
  updatedAt: "2026-09-11T10:00:00Z",
};

const testCrypto = Crypto.make({
  randomBytes: (size) => new Uint8Array(size).fill(1),
  digest: (_algorithm, data) => Effect.succeed(data),
});

interface Harness {
  readonly emit: (event: ProviderRuntimeEvent) => Effect.Effect<void>;
  readonly poll: (snapshot: InfinitusSnapshot) => Effect.Effect<void>;
  readonly setCurrent: (snapshot: InfinitusSnapshot) => Effect.Effect<void>;
  readonly setEnabled: (enabled: boolean) => Effect.Effect<void>;
  readonly interrupts: Effect.Effect<ReadonlyArray<{ threadId: ThreadId; turnId?: TurnId }>>;
  readonly turns: Effect.Effect<ReadonlyArray<{ threadId: ThreadId; input?: string }>>;
  readonly dispatched: Effect.Effect<ReadonlyArray<OrchestrationCommand>>;
  readonly watchers: Effect.Effect<number>;
  /** The sidebar's view of the stops (#270 I). */
  readonly stopped: Stream.Stream<ReadonlyArray<InfinitusHeldThread>>;
}

/** Fork (#616): the gate a resume passes through; passthrough by default. */
const makeHarnessWith = (gate?: TurnStartGateShape) =>
  Effect.gen(function* () {
    const events = yield* PubSub.unbounded<ProviderRuntimeEvent>();
    const snapshots = yield* Queue.unbounded<InfinitusSnapshot>();
    const current = yield* Ref.make<InfinitusSnapshot>(stale);
    const enabled = yield* Ref.make(true);
    const interrupts = yield* Ref.make<ReadonlyArray<{ threadId: ThreadId; turnId?: TurnId }>>([]);
    const turns = yield* Ref.make<ReadonlyArray<{ threadId: ThreadId; input?: string }>>([]);
    const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);
    const watchers = yield* Ref.make(0);

    const layer = InfinitusResumeOnLimitLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          gate === undefined ? TurnStartGatePassthrough : Layer.succeed(TurnStartGate, gate),
          Layer.mock(ProviderService)({
            get streamEvents() {
              return Stream.fromPubSub(events);
            },
            interruptTurn: (input) =>
              Ref.update(interrupts, (previous) => [
                ...previous,
                { threadId: input.threadId, ...(input.turnId ? { turnId: input.turnId } : {}) },
              ]),
            sendTurn: (input) =>
              Ref.update(turns, (previous) => [
                ...previous,
                { threadId: input.threadId, ...(input.input ? { input: input.input } : {}) },
              ]).pipe(Effect.as({ turnId, resumeCursor: null } as never)),
          }),
          Layer.mock(OrchestrationEngineService)({
            dispatch: (command) =>
              Ref.update(dispatched, (previous) => [...previous, command]).pipe(
                Effect.as({ sequence: 1 }),
              ),
          }),
          Layer.mock(ProjectionSnapshotQuery)({
            getThreadShellById: () => Effect.succeed(Option.some(shell)),
            getThreadRuntimeContext: () =>
              Effect.succeed(
                Option.some({ id: threadId, projectId: shell.projectId, title: "Thread", session }),
              ),
          }),
          Layer.mock(ServerSettingsService)({
            getSettings: Ref.get(enabled).pipe(
              Effect.map((value) => ({
                ...DEFAULT_SERVER_SETTINGS,
                infinitusResumeOnLimit: value,
              })),
            ),
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
          }),
          Layer.succeed(Crypto.Crypto, testCrypto),
        ),
      ),
    );
    const context = yield* Layer.build(layer);
    const limitStops = Context.get(context, InfinitusLimitStops);

    return {
      emit: (event) => PubSub.publish(events, event).pipe(Effect.asVoid),
      poll: (snapshot) => Queue.offer(snapshots, snapshot).pipe(Effect.asVoid),
      setCurrent: (snapshot) => Ref.set(current, snapshot),
      setEnabled: (value) => Ref.set(enabled, value),
      interrupts: Ref.get(interrupts),
      turns: Ref.get(turns),
      dispatched: Ref.get(dispatched),
      watchers: Ref.get(watchers),
      stopped: limitStops.stopped,
    } satisfies Harness;
  });
const makeHarness = makeHarnessWith();

/** Lets the worker's fibers run until `check` holds; the clock is a test one,
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

/** An ISO instant `offsetSeconds` after the test clock's epoch. */
const at = (offsetSeconds: number) => DateTime.formatIso(DateTime.makeUnsafe(offsetSeconds * 1000));

describe("InfinitusResumeOnLimitLive", () => {
  effectIt.effect(
    "hands the resume to the TurnStartGate: a holding gate resumes nothing until the start runs (#616)",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const kept: Array<{
            threadId: ThreadId;
            replacesActiveTurn: boolean | undefined;
            run: Effect.Effect<void>;
          }> = [];
          const h = yield* makeHarnessWith({
            start: <E, R>({ threadId: held, replacesActiveTurn, run }: TurnStartInput<E, R>) =>
              Effect.gen(function* () {
                // What the real hold does: bind the caller's context, own the failures.
                const context = yield* Effect.context<R>();
                kept.push({
                  replacesActiveTurn,
                  threadId: held,
                  run: run.pipe(Effect.provideContext(context), Effect.orDie),
                });
                return "held" as const;
              }),
          });
          yield* TestClock.adjust(Duration.seconds(100));
          yield* h.emit(parkedWarning());
          yield* settle(h.watchers, (n) => n === 1);

          yield* h.poll(swapped(at(150)));
          yield* settle(
            Effect.sync(() => kept.length),
            (n) => n === 1,
          );
          expect(kept[0]?.threadId).toBe(threadId);
          // The parked turn is still the thread's active one; the hold must not read it as a steer.
          expect(kept[0]?.replacesActiveTurn).toBe(true);
          expect(yield* h.turns).toEqual([]);
          expect(yield* h.interrupts).toEqual([]);
          // The stop itself left its row (#270 I); nothing resumed yet.
          expect((yield* h.dispatched).map((command) => command.type)).toEqual([
            "thread.activity.append",
          ]);

          // Released later: the resume runs then, on the account live now.
          yield* kept[0]!.run;
          expect(yield* h.turns).toEqual([{ threadId, input: CONTINUATION_PROMPT }]);
          expect(yield* h.interrupts).toEqual([{ threadId, turnId }]);
          expect((yield* h.dispatched).map((command) => command.type)).toEqual([
            "thread.activity.append",
            "thread.activity.append",
            "thread.session.set",
          ]);
        }),
      ),
  );

  effectIt.effect("resumes a parked turn once the swapped-to account is probed ok", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* TestClock.adjust(Duration.seconds(100));
        yield* h.emit(parkedWarning());
        yield* settle(h.watchers, (n) => n === 1);

        yield* h.poll(stale);
        yield* h.poll(swapped(at(50)));
        yield* Effect.yieldNow;
        expect(yield* h.turns).toEqual([]);

        yield* h.poll(swapped(at(150)));
        const turns = yield* settle(h.turns, (list) => list.length === 1);
        expect(turns).toEqual([{ threadId, input: CONTINUATION_PROMPT }]);
        expect(yield* h.interrupts).toEqual([{ threadId, turnId }]);
        const dispatched = yield* h.dispatched;
        expect(dispatched.map((command) => command.type)).toEqual([
          "thread.activity.append",
          "thread.activity.append",
          "thread.session.set",
        ]);
        // The stop's own row came first (#270 I).
        const limited = dispatched[0]!;
        if (limited.type !== "thread.activity.append") throw new Error("limited row expected");
        expect(limited.activity.kind).toBe(LIMIT_MARKER_KIND);
        expect(limited.activity.summary).toBe("Limit hit on one@example.com");
        expect(limited.activity.turnId).toBe(turnId);
        const marker = dispatched[1]!;
        if (marker.type !== "thread.activity.append") throw new Error("marker expected");
        expect(marker.activity.kind).toBe(RESUME_MARKER_KIND);
        expect(marker.activity.summary).toBe("Turn resumed on two@example.com");
        expect(marker.activity.turnId).toBe(turnId);
        expect(marker.activity.payload).toMatchObject({
          from: "one@example.com",
          to: "two@example.com",
        });
        const set = dispatched[2]!;
        if (set.type !== "thread.session.set") throw new Error("session.set expected");
        expect(set.session).toMatchObject({
          status: "starting",
          activeTurnId: null,
          lastError: null,
        });
        // Nothing stopped: the snapshot subscription is released again.
        yield* settle(h.watchers, (n) => n === 0);

        // The same news again resumes nothing more.
        yield* h.poll(swapped(at(160)));
        yield* Effect.yieldNow;
        expect((yield* h.turns).length).toBe(1);
      }),
    ),
  );

  effectIt.effect("a failed turn is continued without an interrupt", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* TestClock.adjust(Duration.seconds(100));
        yield* h.emit(
          runtimeEvent("turn.completed", {
            state: "failed",
            errorMessage: "Claude stopped: a usage limit blocked the request.",
          }),
        );
        yield* settle(h.watchers, (n) => n === 1);
        yield* h.poll(swapped(at(150)));
        yield* settle(h.turns, (list) => list.length === 1);
        expect(yield* h.interrupts).toEqual([]);
      }),
    ),
  );

  effectIt.effect("a turn the user moved on from is forgotten", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* TestClock.adjust(Duration.seconds(100));
        yield* h.emit(parkedWarning());
        yield* settle(h.watchers, (n) => n === 1);
        yield* h.emit(runtimeEvent("turn.started", {}, TurnId.make("turn-2")));
        yield* settle(h.watchers, (n) => n === 0);
        yield* h.poll(swapped(at(150)));
        yield* Effect.yieldNow;
        expect(yield* h.turns).toEqual([]);
      }),
    ),
  );

  effectIt.effect("the setting off drops the stop instead of resuming", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* TestClock.adjust(Duration.seconds(100));
        yield* h.setEnabled(false);
        yield* h.emit(parkedWarning());
        yield* settle(h.watchers, (n) => n === 1);
        yield* h.poll(swapped(at(150)));
        yield* settle(h.watchers, (n) => n === 0);
        expect(yield* h.turns).toEqual([]);
        // Only the stop's own row (#270 I); no resume.
        expect((yield* h.dispatched).map((command) => command.type)).toEqual([
          "thread.activity.append",
        ]);
      }),
    ),
  );

  effectIt.effect("a second stop on the same thread waits out the cooldown", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* TestClock.adjust(Duration.seconds(100));
        yield* h.emit(parkedWarning());
        yield* settle(h.watchers, (n) => n === 1);
        yield* h.poll(swapped(at(150)));
        yield* settle(h.turns, (list) => list.length === 1);

        yield* TestClock.adjust(Duration.seconds(30));
        yield* h.emit(parkedWarning(TurnId.make("turn-2")));
        yield* settle(h.watchers, (n) => n === 1);
        yield* h.poll(swapped(at(140)));
        yield* Effect.yieldNow;
        expect((yield* h.turns).length).toBe(1);

        yield* TestClock.adjust(Duration.seconds(120));
        yield* h.poll(swapped(at(260)));
        yield* settle(h.turns, (list) => list.length === 2);
      }),
    ),
  );

  effectIt.effect("publishes the stopped thread for the sidebar until it resumes (#270 I)", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        const seen = yield* Ref.make<ReadonlyArray<ReadonlyArray<InfinitusHeldThread>>>([]);
        yield* Effect.forkScoped(
          Stream.runForEach(h.stopped, (list) => Ref.update(seen, (lists) => [...lists, list])),
        );
        expect(yield* settle(Ref.get(seen), (lists) => lists.length === 1)).toEqual([[]]);

        yield* TestClock.adjust(Duration.seconds(100));
        yield* h.emit(parkedWarning());
        const afterStop = yield* settle(Ref.get(seen), (lists) => lists.length === 2);
        expect(afterStop[1]).toEqual([
          {
            threadId,
            since: expect.any(String),
            summary: "Limit hit on one@example.com",
            kind: "limited",
          },
        ]);

        yield* h.poll(swapped(at(150)));
        const afterResume = yield* settle(Ref.get(seen), (lists) => lists.length === 3);
        expect(afterResume[2]).toEqual([]);
      }),
    ),
  );
});
