import {
  DEFAULT_SERVER_SETTINGS,
  RunId,
  ThreadId,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2Run,
  type OrchestrationV2ServerCommand,
  type OrchestrationV2ThreadShell,
  type ServerSettings,
} from "@infinitus/contracts";
import type {
  InfinitusAccount,
  InfinitusLimitStop,
  InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import type { ClaudeUsageLimitRefusal } from "../../orchestration-v2/Adapters/ClaudeAdapterV2.ts";
import * as Orchestrator from "../../orchestration-v2/Orchestrator.ts";
import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import * as ServerSettingsService from "../../serverSettings.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusLimitStops, InfinitusLimitStopsLive } from "../Services/InfinitusLimitStops.ts";
import { InfinitusSwapdProbe } from "../Services/InfinitusSwapdProbe.ts";
import { InfinitusResumeOnLimitLive } from "./InfinitusResumeOnLimit.ts";

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");
const runOne = RunId.make("run-1");
const runTwo = RunId.make("run-2");

/** hiep1's weekly reset, as a refusal carries it (epoch ms) and swapd reads it (ISO). */
const HIEP1_WEEKLY = "2026-10-15T08:00:00.000Z";
const LOC_WEEKLY = "2026-10-16T00:59:00.000Z";

const account = (
  email: string,
  overrides: Partial<InfinitusAccount> & { readonly usage?: unknown } = {},
): InfinitusAccount => ({
  number: 1,
  email,
  active: false,
  isOrganization: false,
  usageStatus: "ok",
  // The test clock starts at the epoch: every probe is "after the stop".
  usageFetchedAt: "1970-01-01T00:00:01.000Z",
  ...overrides,
});

const fleet = (...accounts: ReadonlyArray<InfinitusAccount>): InfinitusSnapshot => ({
  available: true,
  commands: [],
  fleets: [
    { key: "swapd/claude", engineID: "swapd", provider: "claude", capabilities: [], accounts },
  ],
});
const noFleet: InfinitusSnapshot = { available: true, commands: [], fleets: [] };

const shell = (
  threadId: ThreadId,
  overrides: Partial<OrchestrationV2ThreadShell> = {},
): OrchestrationV2ThreadShell =>
  ({
    id: threadId,
    status: "running",
    lastErrorClass: null,
    usageLimitResetAt: null,
    latestRunId: runOne,
    activeRunId: runOne,
    latestRunCompletedAt: null,
    archivedAt: null,
    settledOverride: null,
    modelSelection: { instanceId: "claude", model: "opus" },
    ...overrides,
  }) as unknown as OrchestrationV2ThreadShell;

let counter = 0;
const runUpdated = (
  threadId: ThreadId,
  runId: RunId,
  status: OrchestrationV2Run["status"],
): OrchestrationV2DomainEvent =>
  ({
    type: "run.updated",
    id: `evt-${(counter += 1)}`,
    threadId,
    occurredAt: "1970-01-01T00:00:00Z",
    payload: { id: runId, threadId, status },
  }) as never;
const threadEvent = (
  threadId: ThreadId,
  type: "thread.settled" | "thread.archived",
): OrchestrationV2DomainEvent =>
  ({ type, id: `evt-${(counter += 1)}`, threadId, occurredAt: "1970-01-01T00:00:00Z" }) as never;

const refusal = (
  threadId: ThreadId,
  runId: RunId,
  overrides: Partial<ClaudeUsageLimitRefusal> = {},
): ClaudeUsageLimitRefusal => ({
  threadId,
  runId,
  rateLimitType: "seven_day",
  resetsAt: Date.parse(HIEP1_WEEKLY),
  ...overrides,
});

const makeHarness = (input: {
  readonly snapshot?: InfinitusSnapshot;
  readonly shells?: ReadonlyArray<OrchestrationV2ThreadShell>;
  readonly settings?: Partial<ServerSettings>;
}) =>
  Effect.gen(function* () {
    const events = yield* PubSub.unbounded<OrchestrationV2DomainEvent>();
    const commands = yield* Ref.make<ReadonlyArray<OrchestrationV2ServerCommand>>([]);
    const reports = yield* Ref.make<ReadonlyArray<[string, string | null]>>([]);
    const shells = yield* Ref.make(new Map((input.shells ?? []).map((s) => [s.id, s])));
    const snapshots = yield* SubscriptionRef.make(input.snapshot ?? noFleet);
    const stopped = yield* Ref.make<ReadonlyArray<InfinitusLimitStop>>([]);
    const stops = InfinitusLimitStopsLive;
    const layer = InfinitusResumeOnLimitLive.pipe(
      Layer.provideMerge(stops),
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(Orchestrator.OrchestratorV2)({
            get streamDomainEvents() {
              return Stream.fromPubSub(events);
            },
            dispatch: (command) =>
              Ref.update(commands, (list) => [...list, command]).pipe(
                Effect.as({ lastEventSequence: 0 } as never),
              ),
          }),
          Layer.mock(ProjectionStore.ProjectionStoreV2)({
            getThreadShell: (threadId) =>
              Ref.get(shells).pipe(Effect.map((map) => map.get(threadId) ?? null)),
            getShellSnapshot: () =>
              Ref.get(shells).pipe(
                Effect.map(
                  (map) =>
                    ({
                      schemaVersion: 1,
                      snapshotSequence: 0,
                      threads: [...map.values()],
                      archivedThreads: [],
                    }) as never,
                ),
              ),
          }),
          Layer.mock(InfinitusService)({
            snapshot: SubscriptionRef.get(snapshots),
            changes: () => SubscriptionRef.changes(snapshots),
          }),
          Layer.mock(InfinitusSwapdProbe)({
            snapshot: Effect.succeed({ available: false, fleets: [], commands: [] }),
            reportLimit: (account, resetsAt) =>
              Ref.update(reports, (list) => [...list, [account, resetsAt]]),
          }),
          Layer.mock(ServerSettingsService.ServerSettingsService)({
            getSettings: Effect.succeed({ ...DEFAULT_SERVER_SETTINGS, ...input.settings }),
          }),
        ),
      ),
    );
    const context = yield* Layer.build(layer);
    const limitStops = Context.get(context, InfinitusLimitStops);
    yield* limitStops.stopped.pipe(
      Stream.runForEach((list) => Ref.set(stopped, list)),
      Effect.forkScoped,
    );
    // The forked streams subscribe on their first steps.
    const settle = Effect.gen(function* () {
      for (let i = 0; i < 80; i += 1) yield* Effect.yieldNow;
    });
    yield* settle;
    return {
      refuse: (value: ClaudeUsageLimitRefusal) =>
        limitStops.reportRefusal(value).pipe(Effect.andThen(settle)),
      emit: (event: OrchestrationV2DomainEvent) =>
        PubSub.publish(events, event).pipe(Effect.andThen(settle)),
      probe: (snapshot: InfinitusSnapshot) =>
        SubscriptionRef.set(snapshots, snapshot).pipe(Effect.andThen(settle)),
      setShell: (value: OrchestrationV2ThreadShell) =>
        Ref.update(shells, (map) => new Map(map).set(value.id, value)),
      settle,
      stopped: Ref.get(stopped),
      reports: Ref.get(reports),
      commands: Ref.get(commands).pipe(
        Effect.map((list) =>
          list.map((command) =>
            command.type === "message.dispatch"
              ? {
                  type: command.type,
                  threadId: command.threadId,
                  source: command.manualContinuationOfRunId,
                  text: command.text,
                }
              : command.type === "run.interrupt"
                ? { type: command.type, threadId: command.threadId, runId: command.runId }
                : { type: command.type },
          ),
        ),
      ),
    };
  });

describe("InfinitusResumeOnLimitLive (#648, #1627)", () => {
  effectIt.effect(
    "a parked refusal lists the thread, blames the account whose window matches (#1486), and resumes on a swap",
    () =>
      Effect.gen(function* () {
        // 02:22:34 swapd swapped hiep1 → loctruongh; the refusal lands with
        // hiep1's weekly reset on loctruongh's watch.
        const h = yield* makeHarness({
          shells: [shell(one)],
          snapshot: fleet(
            account("hiep1", { usage: { sevenDay: { pct: 100, resetsAt: HIEP1_WEEKLY } } }),
            account("loctruongh", {
              active: true,
              usage: { sevenDay: { pct: 34, resetsAt: LOC_WEEKLY } },
            }),
          ),
        });
        yield* h.refuse(refusal(one, runOne));
        expect(yield* h.stopped).toEqual([
          {
            threadId: one,
            kind: "parked",
            since: "1970-01-01T00:00:00.000Z",
            account: "hiep1",
            resetsAt: HIEP1_WEEKLY,
          },
        ]);
        expect(yield* h.reports).toEqual([["hiep1", HIEP1_WEEKLY]]);
        // The live account has room in the window: the resume replaces the
        // parked turn, then continues the run once the orchestrator records
        // the interrupt.
        yield* h.settle;
        expect(yield* h.commands).toEqual([{ type: "run.interrupt", threadId: one, runId: runOne }]);
        expect(yield* h.stopped).toEqual([]);
        yield* h.setShell(shell(one, { status: "interrupted", activeRunId: null }));
        yield* h.emit(runUpdated(one, runOne, "interrupted"));
        expect(yield* h.commands).toEqual([
          { type: "run.interrupt", threadId: one, runId: runOne },
          {
            type: "message.dispatch",
            threadId: one,
            source: runOne,
            text: "Continue where you left off.",
          },
        ]);
        // The continuation's own run moves the thread on without a second stop.
        yield* h.emit(runUpdated(one, runTwo, "running"));
        expect(yield* h.stopped).toEqual([]);
      }),
  );

  effectIt.effect("the stop waits while the live account is the spent one", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        shells: [shell(one)],
        snapshot: fleet(
          account("hiep1", {
            active: true,
            usage: { sevenDay: { pct: 100, resetsAt: HIEP1_WEEKLY } },
          }),
        ),
      });
      yield* h.refuse(refusal(one, runOne));
      expect((yield* h.stopped).map((stop) => stop.account)).toEqual(["hiep1"]);
      expect(yield* h.commands).toEqual([]);
      // The SDK re-announces the parked turn as its reset moves: the entry
      // follows, nothing is reported twice.
      yield* h.refuse(refusal(one, runOne, { resetsAt: Date.parse(LOC_WEEKLY) }));
      expect((yield* h.stopped).map((stop) => stop.resetsAt)).toEqual([LOC_WEEKLY]);
      expect(yield* h.reports).toHaveLength(1);
      // The swap lands: a different account with room.
      yield* h.probe(
        fleet(
          account("hiep1", { usage: { sevenDay: { pct: 100, resetsAt: HIEP1_WEEKLY } } }),
          account("hiep2", { active: true, usage: { sevenDay: { pct: 5 } } }),
        ),
      );
      expect(yield* h.commands).toEqual([{ type: "run.interrupt", threadId: one, runId: runOne }]);
    }),
  );

  effectIt.effect("a failed limit run is a stop too, continued at once on the next account", () =>
    Effect.gen(function* () {
      const failed = shell(one, {
        status: "failed",
        activeRunId: null,
        lastErrorClass: "usage_limit",
        usageLimitResetAt: HIEP1_WEEKLY,
      });
      const h = yield* makeHarness({
        shells: [failed],
        snapshot: fleet(
          account("hiep1", {
            active: true,
            usage: { sevenDay: { pct: 100, resetsAt: HIEP1_WEEKLY } },
          }),
        ),
      });
      // The refusal came first (the parked turn), then the CLI gave up: one
      // stop, the window kept, reported once.
      yield* h.refuse(refusal(one, runOne));
      yield* h.emit(runUpdated(one, runOne, "failed"));
      expect(yield* h.stopped).toEqual([
        {
          threadId: one,
          kind: "failed",
          since: "1970-01-01T00:00:00.000Z",
          account: "hiep1",
          resetsAt: HIEP1_WEEKLY,
        },
      ]);
      expect(yield* h.reports).toHaveLength(1);
      yield* h.probe(fleet(account("hiep2", { active: true, usage: { sevenDay: { pct: 5 } } })));
      expect(yield* h.commands).toEqual([
        { type: "message.dispatch", threadId: one, source: runOne, text: "Continue where you left off." },
      ]);
      expect(yield* h.stopped).toEqual([]);
    }),
  );

  effectIt.effect("a run that failed for another reason, a settle or an archive ends the stop", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        shells: [shell(one), shell(two)],
        snapshot: fleet(account("hiep1", { active: true, usage: { sevenDay: { pct: 100 } } })),
      });
      yield* h.refuse(refusal(one, runOne));
      yield* h.refuse(refusal(two, runOne));
      expect((yield* h.stopped).map((stop) => stop.threadId)).toEqual([one, two]);
      yield* h.emit(threadEvent(one, "thread.settled"));
      expect((yield* h.stopped).map((stop) => stop.threadId)).toEqual([two]);
      yield* h.setShell(shell(two, { status: "failed", lastErrorClass: "provider_error" }));
      yield* h.emit(runUpdated(two, runOne, "failed"));
      expect(yield* h.stopped).toEqual([]);
      // A context-window failure (#1107) never becomes a stop.
      yield* h.emit(runUpdated(two, runTwo, "failed"));
      expect(yield* h.stopped).toEqual([]);
      expect(yield* h.commands).toEqual([]);
    }),
  );

  effectIt.effect("a proxied instance's stop (#1088) names no account, reports nothing, never resumes", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        shells: [shell(one, { modelSelection: { instanceId: "proxied", model: "opus" } as never })],
        snapshot: fleet(account("hiep1", { active: true, usage: { sevenDay: { pct: 1 } } })),
        settings: {
          providerInstances: {
            proxied: {
              driver: "claudeAgent",
              displayName: "Through cliproxy",
              environment: [{ name: "ANTHROPIC_BASE_URL", value: "http://127.0.0.1:8317" }],
            },
          } as never,
        },
      });
      yield* h.refuse(refusal(one, runOne));
      expect(yield* h.stopped).toEqual([
        {
          threadId: one,
          kind: "parked",
          since: "1970-01-01T00:00:00.000Z",
          account: null,
          resetsAt: HIEP1_WEEKLY,
          proxy: "Through cliproxy",
        },
      ]);
      yield* h.probe(fleet(account("hiep2", { active: true, usage: { sevenDay: { pct: 1 } } })));
      expect(yield* h.reports).toEqual([]);
      expect(yield* h.commands).toEqual([]);
    }),
  );

  effectIt.effect("the setting off keeps the pill and drops the report and the resume", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        shells: [shell(one)],
        snapshot: fleet(account("hiep2", { active: true, usage: { sevenDay: { pct: 1 } } })),
        settings: { infinitusResumeOnLimit: false },
      });
      yield* h.refuse(refusal(one, runOne));
      expect((yield* h.stopped).map((stop) => stop.threadId)).toEqual([one]);
      expect(yield* h.reports).toEqual([]);
      expect(yield* h.commands).toEqual([]);
    }),
  );

  effectIt.effect("a settled thread's parked turn records nothing, and a resume stands down once the thread moved on (#1522)", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        shells: [shell(one, { settledOverride: "settled" }), shell(two)],
        snapshot: fleet(account("hiep1", { active: true, usage: { sevenDay: { pct: 100 } } })),
      });
      yield* h.refuse(refusal(one, runOne));
      expect(yield* h.stopped).toEqual([]);
      yield* h.refuse(refusal(two, runOne));
      // The user's own send started another run before the probe came back.
      yield* h.setShell(shell(two, { latestRunId: runTwo, activeRunId: runTwo }));
      yield* h.probe(fleet(account("hiep2", { active: true, usage: { sevenDay: { pct: 1 } } })));
      expect(yield* h.commands).toEqual([]);
    }),
  );

  effectIt.effect("two resumes of one thread are spaced by the cooldown", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        shells: [shell(one)],
        snapshot: fleet(account("hiep1", { active: true, usage: { sevenDay: { pct: 100 } } })),
      });
      yield* h.refuse(refusal(one, runOne));
      yield* h.probe(fleet(account("hiep2", { active: true, usage: { sevenDay: { pct: 1 } } })));
      expect(yield* h.commands).toHaveLength(1);
      // The resumed turn is refused again on a second run, a minute later.
      yield* TestClock.adjust(Duration.minutes(1));
      yield* h.setShell(shell(one, { latestRunId: runTwo, activeRunId: runTwo }));
      yield* h.refuse(refusal(one, runTwo));
      expect((yield* h.stopped).map((stop) => stop.threadId)).toEqual([one]);
      expect(yield* h.commands).toHaveLength(1);
      yield* TestClock.adjust(Duration.minutes(1));
      yield* h.probe(fleet(account("hiep3", { active: true, usage: { sevenDay: { pct: 1 } } })));
      expect(yield* h.commands).toHaveLength(2);
    }),
  );

  effectIt.effect("failed limit runs are restored at boot and resumed on the next probe", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        shells: [
          shell(one, {
            status: "failed",
            activeRunId: null,
            lastErrorClass: "usage_limit",
            usageLimitResetAt: HIEP1_WEEKLY,
          }),
          shell(two, { status: "failed", activeRunId: null, lastErrorClass: "provider_error" }),
        ],
        snapshot: fleet(account("hiep2", { active: true, usage: { sevenDay: { pct: 1 } } })),
      });
      expect((yield* h.stopped).map((stop) => [stop.threadId, stop.kind, stop.account])).toEqual([
        [one, "failed", null],
      ]);
      yield* h.settle;
      expect(yield* h.commands).toEqual([
        { type: "message.dispatch", threadId: one, source: runOne, text: "Continue where you left off." },
      ]);
    }),
  );
});
