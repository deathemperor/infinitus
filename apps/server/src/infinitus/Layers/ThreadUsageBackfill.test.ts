import { assert, it } from "@effect/vitest";
import {
  EventId,
  MessageId,
  type ModelSelection,
  NodeId,
  type OrchestrationV2AppThread,
  type OrchestrationV2Run,
  ProjectId,
  ProviderDriverKind,
  ProviderInstanceId,
  ProviderSessionId,
  ProviderThreadId,
  ProviderTurnId,
  RunId,
  ThreadId,
  ThreadUsageRollup,
} from "@infinitus/contracts";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as SqlClient from "effect/sql/SqlClient";

import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import * as SqlitePersistence from "../../persistence/Sqlite.ts";
import { listThreadUsageBackfillCandidates } from "./ThreadUsageBackfill.ts";

const layerTest = Layer.mergeAll(
  ProjectionStore.layer.pipe(Layer.provideMerge(SqlitePersistence.layerMemory)),
  SqlitePersistence.layerMemory,
);
const claude = ProviderDriverKind.make("claudeAgent");
const modelSelection = {
  instanceId: ProviderInstanceId.make("claudeAgent"),
  model: "claude-opus-4-7",
} satisfies ModelSelection;
const encodeRollup = Schema.encodeSync(Schema.fromJsonString(ThreadUsageRollup));

const v1Usage: ThreadUsageRollup = {
  source: "runtime",
  turns: 2,
  inputTokens: 1000,
  outputTokens: 50,
  cachedInputTokens: 800,
  cacheCreationTokens: 100,
  reasoningTokens: 0,
  subagentTurns: 0,
  costUsd: 0.4,
  models: ["claude-opus-4-7"],
  lastTurnAt: "2026-09-01T00:00:00.000Z",
};

/**
 * Seeds one app thread with the runs it asks for, optionally a root Claude
 * provider thread naming a native session, and optionally a completed
 * provider turn carrying usage.
 */
const seedThread = Effect.fn("seedThread")(function* (input: {
  readonly suffix: string;
  readonly runs: ReadonlyArray<OrchestrationV2Run["status"]>;
  readonly nativeSessionId?: string;
  readonly recordedUsage?: boolean;
  readonly usageBaseline?: ThreadUsageRollup;
}) {
  const projectionStore = yield* ProjectionStore.ProjectionStoreV2;
  const now = yield* DateTime.now;
  const threadId = ThreadId.make(`thread:${input.suffix}`);
  const nodeId = NodeId.make(`node:${input.suffix}`);
  const providerThreadId = ProviderThreadId.make(`provider-thread:${input.suffix}`);
  const thread: OrchestrationV2AppThread = {
    createdBy: "user",
    creationSource: "web",
    id: threadId,
    projectId: ProjectId.make("project:usage-backfill"),
    title: input.suffix,
    providerInstanceId: modelSelection.instanceId,
    modelSelection,
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath: null,
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
    ...(input.usageBaseline === undefined ? {} : { usageBaseline: input.usageBaseline }),
  };
  yield* projectionStore.apply({
    id: EventId.make(`event:${input.suffix}:thread-created`),
    type: "thread.created",
    threadId,
    occurredAt: now,
    payload: thread,
  });
  if (input.nativeSessionId !== undefined) {
    yield* projectionStore.apply({
      id: EventId.make(`event:${input.suffix}:provider-thread`),
      type: "provider-thread.updated",
      threadId,
      driver: claude,
      occurredAt: now,
      payload: {
        id: providerThreadId,
        driver: claude,
        providerInstanceId: modelSelection.instanceId,
        providerSessionId: ProviderSessionId.make(`session:${input.suffix}`),
        appThreadId: threadId,
        ownerNodeId: null,
        nativeThreadRef: { driver: claude, nativeId: input.nativeSessionId, strength: "strong" },
        nativeConversationHeadRef: null,
        status: "idle",
        firstRunOrdinal: null,
        lastRunOrdinal: null,
        handoffIds: [],
        forkedFrom: null,
        createdAt: now,
        updatedAt: now,
      },
    });
  }
  let ordinal = 0;
  for (const status of input.runs) {
    ordinal += 1;
    const runId = RunId.make(`run:${input.suffix}:${ordinal}`);
    const requestedAt = DateTime.makeUnsafe(
      Date.parse("2026-09-01T00:00:00.000Z") + ordinal * 60_000,
    );
    const terminal = status === "completed" || status === "interrupted" || status === "failed";
    yield* projectionStore.apply({
      id: EventId.make(`event:${input.suffix}:run-${ordinal}`),
      type: "run.created",
      threadId,
      runId,
      nodeId,
      driver: claude,
      providerInstanceId: modelSelection.instanceId,
      occurredAt: now,
      payload: {
        id: runId,
        threadId,
        ordinal,
        providerInstanceId: modelSelection.instanceId,
        modelSelection,
        providerThreadId: null,
        userMessageId: MessageId.make(`message:${input.suffix}:${ordinal}`),
        rootNodeId: nodeId,
        activeAttemptId: null,
        status,
        requestedAt,
        startedAt: requestedAt,
        completedAt: terminal ? requestedAt : null,
        checkpointId: null,
        contextHandoffId: null,
      },
    });
  }
  if (input.recordedUsage) {
    yield* projectionStore.apply({
      id: EventId.make(`event:${input.suffix}:provider-turn`),
      type: "provider-turn.updated",
      threadId,
      nodeId,
      driver: claude,
      occurredAt: now,
      payload: {
        id: ProviderTurnId.make(`provider-turn:${input.suffix}`),
        providerThreadId,
        nodeId,
        runAttemptId: null,
        nativeTurnRef: null,
        ordinal: 1,
        status: "completed",
        startedAt: now,
        completedAt: now,
        turnTokenUsage: {
          usageStatus: "complete",
          usageScope: "main_agent",
          hasSubagents: false,
          inputTokens: 10,
          outputTokens: 5,
        },
      },
    });
  }
  return threadId;
});

it.layer(layerTest)("listThreadUsageBackfillCandidates (#834, v2)", (it) => {
  it.effect(
    "names the legacy threads with a v1 rollup or a root Claude session, and no other",
    () =>
      Effect.gen(function* () {
        const sql = yield* SqlClient.SqlClient;
        // A v1 import: the fork's old projection row survives under the same id.
        const imported = yield* seedThread({ suffix: "imported", runs: ["completed"] });
        yield* sql`
        INSERT INTO projection_threads (thread_id, project_id, title, created_at, updated_at, usage_json)
        VALUES (${imported}, 'project:usage-backfill', 'imported', '2026-09-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z', ${encodeRollup(v1Usage)})
      `;
        // A legacy Claude thread the provider thread names the session of.
        const legacy = yield* seedThread({
          suffix: "legacy",
          runs: ["completed", "interrupted"],
          nativeSessionId: "sess-legacy",
        });
        // A v1 session binding, when no provider thread names the session.
        const bound = yield* seedThread({ suffix: "bound", runs: ["completed"] });
        yield* sql`
        INSERT INTO provider_session_runtime (thread_id, provider_name, adapter_key, status, last_seen_at, resume_cursor_json)
        VALUES (${bound}, 'claudeAgent', 'claude', 'idle', '2026-09-01T00:00:00.000Z', '{"resume":"sess-bound"}')
      `;
        // A thread whose turns this server already recorded usage for.
        const recorded = yield* seedThread({
          suffix: "recorded",
          runs: ["completed"],
          nativeSessionId: "sess-recorded",
          recordedUsage: true,
        });
        // Excluded: a run in flight, a baseline already given, nothing to read.
        yield* seedThread({
          suffix: "live",
          runs: ["completed", "running"],
          nativeSessionId: "sess-live",
        });
        yield* seedThread({
          suffix: "baselined",
          runs: ["completed"],
          nativeSessionId: "sess-baselined",
          usageBaseline: v1Usage,
        });
        yield* seedThread({ suffix: "codex", runs: ["completed"] });

        const candidates = yield* listThreadUsageBackfillCandidates({ limit: 100 });
        const byThread = new Map(candidates.map((candidate) => [candidate.threadId, candidate]));
        assert.deepEqual([...byThread.keys()].sort(), [imported, legacy, bound, recorded].sort());
        assert.deepEqual(byThread.get(imported), {
          threadId: imported,
          v1Usage,
          claudeSessionId: null,
          turns: 1,
          lastTurnAt: "2026-09-01T00:01:00.000Z",
          recordedUsage: false,
        });
        assert.deepEqual(byThread.get(legacy), {
          threadId: legacy,
          v1Usage: null,
          claudeSessionId: "sess-legacy",
          turns: 1,
          lastTurnAt: "2026-09-01T00:02:00.000Z",
          recordedUsage: false,
        });
        assert.equal(byThread.get(bound)?.claudeSessionId, "sess-bound");
        assert.isTrue(byThread.get(recorded)?.recordedUsage);

        const one = yield* listThreadUsageBackfillCandidates({ threadId: legacy, limit: 1 });
        assert.deepEqual(
          one.map((candidate) => candidate.threadId),
          [legacy],
        );
      }),
  );
});
