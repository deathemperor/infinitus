import { assert, it } from "@effect/vitest";
import {
  EventId,
  MessageId,
  NodeId,
  ProjectId,
  ProviderInstanceId,
  ProviderThreadId,
  RunAttemptId,
  RunId,
  ThreadId,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2Run,
} from "@infinitus/contracts";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as SqlitePersistence from "../../persistence/Sqlite.ts";
import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import { InfinitusRunningTurns } from "../Services/InfinitusRunningTurns.ts";
import { InfinitusRunningTurnsLive } from "./InfinitusRunningTurns.ts";

const providerInstanceId = ProviderInstanceId.make("codex");
const modelSelection = { instanceId: providerInstanceId, model: "gpt-6" };

/** One thread with one run in `status`, as the projection sees them. */
function threadWithRun(
  name: string,
  status: OrchestrationV2Run["status"],
  now: DateTime.Utc,
): ReadonlyArray<OrchestrationV2DomainEvent> {
  const threadId = ThreadId.make(`thread:${name}`);
  const common = { threadId, occurredAt: now };
  return [
    {
      ...common,
      id: EventId.make(`${name}:thread`),
      type: "thread.created",
      payload: {
        id: threadId,
        projectId: ProjectId.make("project:running-turns"),
        title: name,
        providerInstanceId,
        modelSelection,
        createdBy: "user",
        creationSource: "web",
        runtimeMode: "full-access",
        interactionMode: "default",
        branch: null,
        worktreePath: "/workspace",
        activeProviderThreadId: null,
        lineage: { parentThreadId: null, relationshipToParent: null, rootThreadId: threadId },
        forkedFrom: null,
        createdAt: now,
        updatedAt: now,
        archivedAt: null,
        settledOverride: null,
        settledAt: null,
        lastVisitedAt: null,
        deletedAt: null,
      },
    },
    {
      ...common,
      id: EventId.make(`${name}:run`),
      type: "run.created",
      payload: {
        id: RunId.make(`run:${name}`),
        threadId,
        ordinal: 1,
        providerInstanceId,
        modelSelection,
        providerThreadId: ProviderThreadId.make(`provider-thread:${name}`),
        userMessageId: MessageId.make(`message:${name}`),
        rootNodeId: NodeId.make(`node:${name}`),
        activeAttemptId: RunAttemptId.make(`attempt:${name}`),
        status,
        requestedAt: now,
        startedAt: now,
        completedAt: status === "completed" ? now : null,
        checkpointId: null,
        contextHandoffId: null,
      },
    },
  ];
}

const layer = InfinitusRunningTurnsLive.pipe(
  Layer.provideMerge(ProjectionStore.layer.pipe(Layer.provideMerge(SqlitePersistence.layerMemory))),
);

it.effect("lists the threads whose run is live, a waiting one included (#829)", () =>
  Effect.gen(function* () {
    const store = yield* ProjectionStore.ProjectionStoreV2;
    const now = yield* DateTime.now;
    const events = [
      ...threadWithRun("running", "running", now),
      ...threadWithRun("waiting", "waiting", now),
      ...threadWithRun("completed", "completed", now),
    ];
    yield* Effect.forEach(events, (event) => store.apply(event), { discard: true });
    const turns = yield* (yield* InfinitusRunningTurns).list;
    assert.deepEqual(
      turns.toSorted((left, right) => left.threadId.localeCompare(right.threadId)),
      [
        { threadId: "thread:running", turnId: "run:running" },
        { threadId: "thread:waiting", turnId: "run:waiting" },
      ],
    );
  }).pipe(Effect.provide(layer)),
);
