import {
  EnvironmentId,
  ProjectId,
  ThreadId,
  type OrchestrationEvent,
  type OrchestrationProjectShell,
  type OrchestrationThreadShell,
} from "@t3tools/contracts";
import {
  InfinitusUnavailable,
  type InfinitusManifestCommand,
  type InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { PRODUCT_NAME } from "@t3tools/contracts/productName";
import { HostProcessEnvironment } from "@t3tools/shared/hostProcess";
import { it as effectIt } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import * as ServerSecretStore from "../../auth/ServerSecretStore.ts";
import { RELAY_ENVIRONMENT_CREDENTIAL_SECRET, RELAY_URL_SECRET } from "../../cloud/config.ts";
import { ServerConfig } from "../../config.ts";
import { ServerEnvironment } from "../../environment/ServerEnvironment.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import {
  InfinitusControlClient,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import { InfinitusAgentActivityLive } from "./InfinitusAgentActivity.ts";

const environmentId = EnvironmentId.make("env-1");
const projectId = ProjectId.make("project-1");
const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");

const project = { id: projectId, title: "Acme" } as unknown as OrchestrationProjectShell;
const TURN_START = "2026-09-13T09:59:00.000Z";

type Phase = "idle" | "running" | "approval" | "error";
const shell = (threadId: ThreadId, phase: Phase, at: string): OrchestrationThreadShell =>
  ({
    id: threadId,
    projectId,
    title: "Fix the build",
    modelSelection: { instanceId: "claude", model: "opus" },
    session:
      phase === "idle"
        ? { activeTurnId: null, status: "ready" }
        : phase === "error"
          ? { activeTurnId: null, status: "error" }
          : { activeTurnId: "turn-1", status: "running" },
    latestTurn:
      phase === "running"
        ? {
            turnId: "turn-1",
            state: "running",
            // The turn's start holds while its thread's `updatedAt` moves.
            requestedAt: TURN_START,
            startedAt: TURN_START,
            completedAt: null,
            assistantMessageId: null,
          }
        : null,
    updatedAt: at,
    hasPendingApprovals: phase === "approval",
    hasPendingUserInput: false,
  }) as unknown as OrchestrationThreadShell;

const sessionSet = (threadId: ThreadId): OrchestrationEvent =>
  ({
    type: "thread.session-set",
    aggregateKind: "thread",
    aggregateId: threadId,
    metadata: {},
    payload: { threadId },
  }) as never;

const push = (summary: string): InfinitusManifestCommand => ({
  name: "push",
  args: [],
  options: [],
  effect: "write",
  summary,
  replyShape: "{pushed, card?}",
  stdin: "payload",
});
const snapshotWith = (commands: ReadonlyArray<InfinitusManifestCommand>): InfinitusSnapshot => ({
  available: true,
  fleets: [],
  commands,
});
const cardManifest = snapshotWith([push('… {kind: "thread.activity", state} …')]);
const phaseOnlyManifest = snapshotWith([push("…{kind, threadId, title, phase}…")]);
const notPolled: InfinitusSnapshot = {
  available: false,
  unavailableReason: NOT_POLLED_REASON,
  fleets: [],
  commands: [],
};

const memoryFs = FileSystem.layerNoop({
  makeTempDirectoryScoped: () => Effect.succeed("/mem/tmp"),
  makeDirectory: () => Effect.void,
  exists: () => Effect.succeed(false),
});

type Payload = {
  readonly kind: string;
  readonly state: null | { readonly [key: string]: unknown };
};

const makeHarness = (input: {
  readonly snapshot?: InfinitusSnapshot;
  readonly polled?: InfinitusSnapshot;
  readonly controlSocketOverride?: string;
  readonly initial?: ReadonlyArray<OrchestrationThreadShell>;
  /** The T3 Connect link in the secret store (#1322). */
  readonly relayLinked?: boolean;
}) =>
  Effect.gen(function* () {
    const linked = yield* Ref.make(input.relayLinked ?? false);
    const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
    const shells = yield* Ref.make<ReadonlyMap<ThreadId, OrchestrationThreadShell>>(
      new Map((input.initial ?? []).map((row) => [row.id, row])),
    );
    const current = yield* Ref.make(input.snapshot ?? cardManifest);
    const reads = yield* Ref.make(0);
    const requests = yield* Ref.make<ReadonlyArray<InfinitusControlRequestInput>>([]);
    const unavailable = yield* Ref.make(false);
    const scope = yield* Scope.make();
    const layer = InfinitusAgentActivityLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(OrchestrationEngineService)({
            get streamDomainEvents() {
              return Stream.fromPubSub(domainEvents);
            },
          }),
          Layer.mock(ProjectionSnapshotQuery)({
            getShellSnapshot: () =>
              Ref.update(reads, (count) => count + 1).pipe(
                Effect.andThen(Ref.get(shells)),
                Effect.map(
                  (map) =>
                    ({
                      snapshotSequence: 1,
                      projects: [project],
                      threads: [...map.values()],
                      updatedAt: "2026-09-13T10:00:00.000Z",
                    }) as never,
                ),
              ),
          }),
          Layer.succeed(ServerEnvironment, {
            getEnvironmentId: Effect.succeed(environmentId),
            getDescriptor: Effect.die("unused"),
          }),
          Layer.mock(InfinitusService)({
            snapshot: Ref.get(current),
            refresh: Ref.set(current, input.polled ?? cardManifest),
            changes: () => Stream.empty,
            observed: Stream.empty,
          }),
          Layer.mock(InfinitusControlClient)({
            socketPath: "/tmp/test.sock",
            request: (request) =>
              Ref.update(requests, (list) => [...list, request]).pipe(
                Effect.andThen(Ref.get(unavailable)),
                Effect.flatMap((down) =>
                  down
                    ? Effect.fail(
                        new InfinitusUnavailable({ path: "/tmp/test.sock", cause: "ECONNREFUSED" }),
                      )
                    : Effect.succeed({ pushed: true, card: true }),
                ),
              ),
          }),
          Layer.mock(ServerSecretStore.ServerSecretStore)({
            get: (name) =>
              Ref.get(linked).pipe(
                Effect.map((on) =>
                  on && (name === RELAY_URL_SECRET || name === RELAY_ENVIRONMENT_CREDENTIAL_SECRET)
                    ? Option.some(new TextEncoder().encode("x"))
                    : Option.none(),
                ),
              ),
          }),
          Layer.succeed(
            HostProcessEnvironment,
            input.controlSocketOverride === undefined
              ? {}
              : { INFINITUS_CONTROL_SOCKET: input.controlSocketOverride },
          ),
          Layer.fresh(ServerConfig.layerTest("/mem", { prefix: "agent-activity-" })).pipe(
            Layer.provide(Layer.mergeAll(memoryFs, Path.layer)),
          ),
          memoryFs,
          Path.layer,
        ),
      ),
    );
    yield* Layer.buildWithScope(layer, scope);
    // The forked stream subscribes on its first step.
    for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;
    const settle = Effect.gen(function* () {
      for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;
    });
    const now = DateTime.now.pipe(Effect.map(DateTime.formatIso));
    return {
      /** The clock forward, then the fibers that woke settle. */
      elapse: (duration: Duration.Input) => TestClock.adjust(duration).pipe(Effect.andThen(settle)),
      set: (row: OrchestrationThreadShell) =>
        Ref.update(shells, (map) => new Map(map).set(row.id, row)),
      now,
      emit: (event: OrchestrationEvent) =>
        PubSub.publish(domainEvents, event).pipe(Effect.andThen(settle)),
      setUnavailable: (down: boolean) => Ref.set(unavailable, down),
      setRelayLinked: (on: boolean) => Ref.set(linked, on),
      reads: Ref.get(reads),
      pushes: Ref.get(requests).pipe(
        Effect.map((list) =>
          list.map((request) => {
            expect(request.command).toBe("push");
            return JSON.parse(request.secret ?? "") as Payload;
          }),
        ),
      ),
      shutdown: Scope.close(scope, Exit.void).pipe(Effect.andThen(settle)),
    };
  });

describe("InfinitusAgentActivityLive (#1047)", () => {
  effectIt.effect("stands down while the server is linked to a T3 Connect relay (#1322)", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ relayLinked: true });
      yield* h.set(shell(one, "running", yield* h.now));
      yield* h.emit(sessionSet(one));
      yield* h.elapse("5 seconds");
      // The relay's pusher draws this card; a second one from the Mac would double it.
      expect(yield* h.pushes).toEqual([]);
      // Unlinked: the next event folds as before.
      yield* h.setRelayLinked(false);
      yield* h.emit(sessionSet(one));
      yield* h.elapse("5 seconds");
      expect(yield* h.pushes).toHaveLength(1);
      // Linked again: nothing more goes out, and the shutdown sends the
      // null for the card this server put up.
      yield* h.setRelayLinked(true);
      yield* h.set(shell(two, "approval", yield* h.now));
      yield* h.emit(sessionSet(two));
      yield* h.elapse("5 seconds");
      expect(yield* h.pushes).toHaveLength(1);
      yield* h.shutdown;
      expect((yield* h.pushes).at(-1)?.state).toBeNull();
    }),
  );

  effectIt.effect(
    "folds the running threads into one card 5 s after the event, once per change",
    () =>
      Effect.gen(function* () {
        const h = yield* makeHarness({});
        yield* h.set(shell(one, "running", yield* h.now));
        yield* h.emit(sessionSet(one));
        // Coalesced: nothing before the 5 s.
        expect(yield* h.pushes).toEqual([]);
        yield* h.elapse("5 seconds");
        const pushes = yield* h.pushes;
        expect(pushes).toHaveLength(1);
        expect(pushes[0]).toMatchObject({
          kind: "thread.activity",
          state: { title: PRODUCT_NAME, subtitle: "Agent work in progress", activeCount: 1 },
        });
        expect(pushes[0]?.state?.activities).toEqual([
          expect.objectContaining({
            threadId: one,
            status: "Working",
            deepLink: `/threads/${environmentId}/${one}`,
            startedAt: expect.any(String),
          }),
        ]);
        // The same card again (a message landed, the timestamp moved) is no push.
        yield* h.set(shell(one, "running", yield* h.now));
        yield* h.emit(sessionSet(one));
        yield* h.elapse("5 seconds");
        expect(yield* h.pushes).toHaveLength(1);
        // A second thread waiting on an approval leads the card.
        yield* h.set(shell(two, "approval", yield* h.now));
        yield* h.emit(sessionSet(two));
        yield* h.emit(sessionSet(one));
        yield* h.elapse("5 seconds");
        const second = yield* h.pushes;
        expect(second).toHaveLength(2);
        expect(second[1]?.state).toMatchObject({ activeCount: 2 });
        const rows = (second[1]?.state?.activities ?? []) as ReadonlyArray<{ threadId: string }>;
        expect(rows.map((row) => row.threadId)).toEqual([two, one]);
      }),
  );

  effectIt.effect(
    "a finished thread shows as Done, then the card ends 15 min later on its own",
    () =>
      Effect.gen(function* () {
        const h = yield* makeHarness({});
        yield* h.set(shell(one, "running", yield* h.now));
        yield* h.emit(sessionSet(one));
        yield* h.elapse("5 seconds");
        yield* h.set(shell(one, "idle", yield* h.now));
        yield* h.emit(sessionSet(one));
        yield* h.elapse("5 seconds");
        const pushes = yield* h.pushes;
        expect(pushes).toHaveLength(2);
        expect(pushes[1]?.state).toMatchObject({
          subtitle: "Agent work completed",
          activeCount: 0,
          activities: [expect.objectContaining({ threadId: one, status: "Done" })],
        });
        // No thread event says the row aged out: the layer wakes itself.
        yield* h.elapse("14 minutes");
        expect(yield* h.pushes).toHaveLength(2);
        yield* h.elapse("2 minutes");
        const ended = yield* h.pushes;
        expect(ended).toHaveLength(3);
        expect(ended[2]).toEqual({ kind: "thread.activity", state: null });
      }),
  );

  effectIt.effect("an unreachable Mac leaves the card unsent, so the next event tries again", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.setUnavailable(true);
      yield* h.set(shell(one, "running", yield* h.now));
      yield* h.emit(sessionSet(one));
      yield* h.elapse("5 seconds");
      expect(yield* h.pushes).toHaveLength(1);
      yield* h.setUnavailable(false);
      yield* h.emit(sessionSet(one));
      yield* h.elapse("5 seconds");
      const pushes = yield* h.pushes;
      expect(pushes).toHaveLength(2);
      expect(pushes[1]?.state).toMatchObject({ activeCount: 1 });
    }),
  );

  effectIt.effect(
    "quiet on a build whose push does not take the card; an unpolled app is polled first",
    () =>
      Effect.gen(function* () {
        const older = yield* makeHarness({
          snapshot: phaseOnlyManifest,
          polled: phaseOnlyManifest,
        });
        yield* older.set(shell(one, "running", yield* older.now));
        yield* older.emit(sessionSet(one));
        yield* older.elapse("5 seconds");
        expect(yield* older.pushes).toEqual([]);
        expect(yield* older.reads).toBe(0);

        const fresh = yield* makeHarness({ snapshot: notPolled });
        yield* fresh.set(shell(one, "running", yield* fresh.now));
        yield* fresh.emit(sessionSet(one));
        yield* fresh.elapse("5 seconds");
        expect(yield* fresh.pushes).toHaveLength(1);
      }),
  );

  effectIt.effect("withheld from an isolated instance like the port publish", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ controlSocketOverride: "/tmp/other.sock" });
      yield* h.set(shell(one, "running", yield* h.now));
      yield* h.emit(sessionSet(one));
      yield* h.elapse("5 seconds");
      expect(yield* h.pushes).toEqual([]);
      expect(yield* h.reads).toBe(0);
    }),
  );

  effectIt.effect("a clean shutdown ends the card it left up, and only then", () =>
    Effect.gen(function* () {
      const idle = yield* makeHarness({});
      yield* idle.shutdown;
      expect(yield* idle.pushes).toEqual([]);

      const busy = yield* makeHarness({});
      yield* busy.set(shell(one, "running", yield* busy.now));
      yield* busy.emit(sessionSet(one));
      yield* busy.elapse("5 seconds");
      yield* busy.shutdown;
      const pushes = yield* busy.pushes;
      expect(pushes).toHaveLength(2);
      expect(pushes[1]).toEqual({ kind: "thread.activity", state: null });
    }),
  );
});
