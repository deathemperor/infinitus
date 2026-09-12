import {
  DEFAULT_PROVIDER_INTERACTION_MODE,
  DEFAULT_SERVER_SETTINGS,
  EnvironmentId,
  ProjectId,
  ThreadId,
  type OrchestrationEvent,
  type OrchestrationProjectShell,
  type OrchestrationThreadShell,
} from "@t3tools/contracts";
import {
  type InfinitusManifestCommand,
  type InfinitusSnapshot,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import * as ServerEnvironment from "../../environment/ServerEnvironment.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import {
  InfinitusControlClient,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import { InfinitusPushBridgeLive } from "./InfinitusPushBridge.ts";

const environmentId = EnvironmentId.make("env-1");
const projectId = ProjectId.make("project-1");
const one = ThreadId.make("thread-1");
const now = "2026-09-13T10:00:00.000Z";

const project = { id: projectId, title: "Acme" } as unknown as OrchestrationProjectShell;

type Phase = "idle" | "running" | "approval" | "input" | "error";
const shell = (threadId: ThreadId, phase: Phase): OrchestrationThreadShell =>
  ({
    id: threadId,
    projectId,
    title: "Fix the build",
    archivedAt: null,
    pinnedAt: null,
    runtimeMode: "full-access",
    interactionMode: DEFAULT_PROVIDER_INTERACTION_MODE,
    modelSelection: { instanceId: "claude", model: "opus" },
    session:
      phase === "idle"
        ? { activeTurnId: null, status: "ready" }
        : phase === "error"
          ? { activeTurnId: null, status: "error" }
          : { activeTurnId: "turn-1", status: "running" },
    latestTurn: null,
    latestUserMessageAt: null,
    updatedAt: now,
    hasPendingApprovals: phase === "approval",
    hasPendingUserInput: phase === "input",
    pullRequests: [],
  }) as unknown as OrchestrationThreadShell;

const sessionSet = (threadId: ThreadId): OrchestrationEvent =>
  ({
    type: "thread.session-set",
    aggregateKind: "thread",
    aggregateId: threadId,
    metadata: {},
    payload: { threadId },
  }) as never;

const command = (name: string, stdin?: string): InfinitusManifestCommand => ({
  name,
  args: [],
  options: [],
  effect: "write",
  summary: "",
  replyShape: "",
  ...(stdin === undefined ? {} : { stdin }),
});
const snapshotWith = (commands: ReadonlyArray<InfinitusManifestCommand>): InfinitusSnapshot => ({
  available: true,
  fleets: [],
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
const pushManifest = snapshotWith([command("push", "payload")]);

const makeHarness = (input: {
  readonly enabled?: boolean;
  readonly snapshot?: InfinitusSnapshot;
  readonly polled?: InfinitusSnapshot;
  readonly reply?: Effect.Effect<unknown, InfinitusUnavailable>;
  readonly initial?: ReadonlyArray<OrchestrationThreadShell>;
}) =>
  Effect.gen(function* () {
    const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
    const shells = yield* Ref.make<ReadonlyMap<ThreadId, OrchestrationThreadShell>>(
      new Map((input.initial ?? []).map((row) => [row.id, row])),
    );
    const current = yield* Ref.make(input.snapshot ?? pushManifest);
    const refreshes = yield* Ref.make(0);
    const requests = yield* Ref.make<ReadonlyArray<InfinitusControlRequestInput>>([]);
    const layer = InfinitusPushBridgeLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(OrchestrationEngineService)({
            get streamDomainEvents() {
              return Stream.fromPubSub(domainEvents);
            },
          }),
          Layer.mock(ProjectionSnapshotQuery)({
            getThreadShellById: (threadId) =>
              Ref.get(shells).pipe(Effect.map((map) => Option.fromNullishOr(map.get(threadId)))),
            getProjectShellById: (id) =>
              Effect.succeed(id === projectId ? Option.some(project) : Option.none()),
          }),
          Layer.mock(ServerSettingsService)({
            getSettings: Effect.succeed({
              ...DEFAULT_SERVER_SETTINGS,
              infinitusPushBridge: input.enabled ?? true,
            }),
          }),
          Layer.mock(InfinitusService)({
            snapshot: Ref.get(current),
            refresh: Ref.update(refreshes, (n) => n + 1).pipe(
              Effect.andThen(Ref.set(current, input.polled ?? pushManifest)),
            ),
            changes: () => Stream.empty,
            observed: Stream.empty,
          }),
          Layer.mock(InfinitusControlClient)({
            socketPath: "/tmp/test.sock",
            request: (request) =>
              Ref.update(requests, (list) => [...list, request]).pipe(
                Effect.andThen(input.reply ?? Effect.succeed({ pushed: true })),
              ),
          }),
          Layer.succeed(ServerEnvironment.ServerEnvironment, {
            getEnvironmentId: Effect.succeed(environmentId),
            getDescriptor: Effect.die("unused"),
          }),
        ),
      ),
    );
    yield* Layer.build(layer);
    // The forked stream subscribes on its first step.
    for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;

    const settle = Effect.gen(function* () {
      for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;
    });
    return {
      /** Puts the thread in `phase` and emits a session event for it. */
      move: (threadId: ThreadId, phase: Phase) =>
        Ref.update(shells, (map) => new Map([...map, [threadId, shell(threadId, phase)]])).pipe(
          Effect.andThen(PubSub.publish(domainEvents, sessionSet(threadId))),
          Effect.andThen(settle),
        ),
      forget: (threadId: ThreadId) =>
        Ref.update(shells, (map) => new Map([...map].filter(([id]) => id !== threadId))).pipe(
          Effect.andThen(PubSub.publish(domainEvents, sessionSet(threadId))),
          Effect.andThen(settle),
        ),
      pushes: Ref.get(requests).pipe(
        Effect.map((list) =>
          list.map((request) => ({
            command: request.command,
            payload: JSON.parse(request.secret ?? "null") as unknown,
          })),
        ),
      ),
      refreshes: Ref.get(refreshes),
    };
  });

describe("InfinitusPushBridgeLive (#269 G)", () => {
  effectIt.effect("pushes a thread's move into approval, once, and its finish", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.move(one, "running");
      expect(yield* h.pushes).toEqual([]);
      yield* h.move(one, "approval");
      yield* h.move(one, "approval");
      expect(yield* h.pushes).toEqual([
        {
          command: "push",
          payload: {
            kind: "thread.phase",
            threadId: one,
            title: "Fix the build",
            phase: "waiting_for_approval",
          },
        },
      ]);
      yield* h.move(one, "running");
      yield* h.move(one, "idle");
      expect((yield* h.pushes).map((push) => (push.payload as { phase: string }).phase)).toEqual([
        "waiting_for_approval",
        "completed",
      ]);
    }),
  );

  effectIt.effect("the first sighting of a thread seeds its phase and pushes nothing", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ initial: [shell(one, "idle")] });
      yield* h.move(one, "idle");
      yield* h.move(one, "error");
      expect((yield* h.pushes).map((push) => (push.payload as { phase: string }).phase)).toEqual([
        "failed",
      ]);
    }),
  );

  effectIt.effect("a deleted thread is forgotten, so its return is a first sighting again", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.move(one, "running");
      yield* h.forget(one);
      yield* h.move(one, "idle");
      expect(yield* h.pushes).toEqual([]);
    }),
  );

  effectIt.effect("stays quiet with the setting off, and touches no socket", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ enabled: false, snapshot: notPolled });
      yield* h.move(one, "running");
      yield* h.move(one, "approval");
      expect(yield* h.pushes).toEqual([]);
      expect(yield* h.refreshes).toBe(0);
    }),
  );

  effectIt.effect("refreshes an unpolled snapshot once for the manifest, then pushes", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ snapshot: notPolled });
      yield* h.move(one, "running");
      yield* h.move(one, "approval");
      expect(yield* h.refreshes).toBe(1);
      expect(yield* h.pushes).toHaveLength(1);
    }),
  );

  effectIt.effect(
    "an app without the verb, or an unreachable one, gets no push and no failure",
    () =>
      Effect.gen(function* () {
        const noVerb = yield* makeHarness({ snapshot: snapshotWith([command("status")]) });
        yield* noVerb.move(one, "running");
        yield* noVerb.move(one, "approval");
        expect(yield* noVerb.pushes).toEqual([]);

        const down = yield* makeHarness({
          reply: Effect.fail(
            new InfinitusUnavailable({ path: "/tmp/test.sock", cause: "ECONNREFUSED" }),
          ),
        });
        yield* down.move(one, "running");
        yield* down.move(one, "approval");
        yield* down.move(one, "running");
        yield* down.move(one, "idle");
        // Both were attempted; neither failure stopped the stream.
        expect(yield* down.pushes).toHaveLength(2);
      }),
  );
});
