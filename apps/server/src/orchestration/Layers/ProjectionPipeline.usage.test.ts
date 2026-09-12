import {
  CommandId,
  ProjectId,
  ProviderInstanceId,
  ThreadId,
  TurnId,
  type ThreadTurnUsage,
} from "@t3tools/contracts";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as SqlClient from "effect/unstable/sql/SqlClient";

import { ServerConfig } from "../../config.ts";
import { OrchestrationCommandReceiptRepositoryLive } from "../../persistence/Layers/OrchestrationCommandReceipts.ts";
import { ProjectionTurnUsageRepository } from "../../persistence/ProjectionTurnUsage.ts";
import { OrchestrationEventStoreLive } from "../../persistence/Layers/OrchestrationEventStore.ts";
import { SqlitePersistenceMemory } from "../../persistence/Layers/Sqlite.ts";
import * as RepositoryIdentityResolver from "../../project/RepositoryIdentityResolver.ts";
import { OrchestrationEngineService } from "../Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../Services/ProjectionSnapshotQuery.ts";
import * as ThreadBackgroundLiveness from "../ThreadBackgroundLiveness.ts";
import * as ThreadPlanProgress from "../ThreadPlanProgress.ts";
import { OrchestrationEngineLive } from "./OrchestrationEngine.ts";
import { OrchestrationProjectionPipelineLive } from "./ProjectionPipeline.ts";
import { OrchestrationProjectionSnapshotQueryLive } from "./ProjectionSnapshotQuery.ts";

const engineLayer = it.layer(
  OrchestrationEngineLive.pipe(
    Layer.provideMerge(OrchestrationProjectionSnapshotQueryLive),
    Layer.provide(ThreadBackgroundLiveness.layer),
    Layer.provide(ThreadPlanProgress.layer),
    Layer.provideMerge(OrchestrationProjectionPipelineLive),
    Layer.provide(OrchestrationEventStoreLive),
    Layer.provide(OrchestrationCommandReceiptRepositoryLive),
    Layer.provide(RepositoryIdentityResolver.layer),
    Layer.provideMerge(SqlitePersistenceMemory),
    Layer.provideMerge(ServerConfig.layerTest(process.cwd(), { prefix: "t3-usage-projection-" })),
    Layer.provideMerge(NodeServices.layer),
  ),
);

const turn = (id: string, completedAt: string, costUsd: number | null): ThreadTurnUsage => ({
  turnId: TurnId.make(id),
  model: "claude-opus-4-7",
  inputTokens: 1000,
  outputTokens: 100,
  cachedInputTokens: 900,
  cacheCreationTokens: 10,
  reasoningTokens: 5,
  complete: true,
  hasSubagents: false,
  costUsd,
  completedAt,
});

engineLayer("turn usage on the thread projection (#834)", (it) => {
  it.effect("rows and the rollup land, a revert prunes them, a delete drops them", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngineService;
      const snapshotQuery = yield* ProjectionSnapshotQuery;
      const sql = yield* SqlClient.SqlClient;
      const createdAt = "2026-09-12T00:00:00.000Z";
      const projectId = ProjectId.make("project-usage");
      const threadId = ThreadId.make("thread-usage");
      const modelSelection = { instanceId: ProviderInstanceId.make("claude"), model: "opus" };
      const shell = () =>
        snapshotQuery.getThreadShellById(threadId).pipe(Effect.map(Option.getOrThrow));
      const rowCount = () =>
        sql<{ readonly n: number }>`
          SELECT COUNT(*) AS n FROM projection_turn_usage WHERE thread_id = ${threadId}
        `.pipe(Effect.map((rows) => Number(rows[0]?.n ?? 0)));
      const record = (commandId: string, turnUsage: ThreadTurnUsage) =>
        engine.dispatch({
          type: "thread.turn.usage.record",
          commandId: CommandId.make(commandId),
          threadId,
          turnUsage,
          createdAt: turnUsage.completedAt,
        });

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make("cmd-usage-project"),
        projectId,
        title: "Usage",
        workspaceRoot: "/tmp/project-usage",
        defaultModelSelection: modelSelection,
        createdAt,
      });
      yield* engine.dispatch({
        type: "thread.create",
        commandId: CommandId.make("cmd-usage-thread"),
        threadId,
        projectId,
        title: "Costly",
        modelSelection,
        runtimeMode: "full-access",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        createdAt,
      });
      const before = yield* shell();
      assert.isUndefined(before.usage);

      yield* record("cmd-usage-1", turn("turn-1", "2026-09-12T00:01:00.000Z", 0.25));
      yield* record("cmd-usage-2", turn("turn-2", "2026-09-12T00:02:00.000Z", null));
      const after = yield* shell();
      assert.deepStrictEqual(after.usage, {
        source: "runtime",
        turns: 2,
        inputTokens: 2000,
        outputTokens: 200,
        cachedInputTokens: 1800,
        cacheCreationTokens: 20,
        reasoningTokens: 10,
        subagentTurns: 0,
        costUsd: 0.25,
        models: ["claude-opus-4-7"],
        lastTurnAt: "2026-09-12T00:02:00.000Z",
      });
      // Usage is not activity: the thread's stamp is the create's.
      assert.strictEqual(after.updatedAt, before.updatedAt);
      assert.strictEqual(yield* rowCount(), 2);
      const detail = yield* snapshotQuery
        .getThreadDetailById(threadId)
        .pipe(Effect.map(Option.getOrThrow));
      assert.strictEqual(detail.usage?.turns, 2);

      // A re-recorded turn replaces its row rather than adding one, and the
      // stored rollup follows the rows, not the event's running sum.
      yield* record("cmd-usage-2-again", turn("turn-2", "2026-09-12T00:02:00.000Z", 0.1));
      assert.strictEqual(yield* rowCount(), 2);
      assert.strictEqual((yield* shell()).usage?.turns, 2);
      assert.strictEqual((yield* shell()).usage?.costUsd, 0.35);

      // No turn of this thread has a checkpoint at or under count 0, so a
      // revert to it prunes every usage row and the rollup with them.
      yield* engine.dispatch({
        type: "thread.revert.complete",
        commandId: CommandId.make("cmd-usage-revert"),
        threadId,
        turnCount: 0,
        createdAt: "2026-09-12T00:03:00.000Z",
      });
      assert.isUndefined((yield* shell()).usage);
      assert.strictEqual(yield* rowCount(), 0);

      yield* record("cmd-usage-3", turn("turn-3", "2026-09-12T00:04:00.000Z", 0.5));
      assert.strictEqual((yield* shell()).usage?.turns, 1);
      yield* engine.dispatch({
        type: "thread.delete",
        commandId: CommandId.make("cmd-usage-delete"),
        threadId,
      });
      assert.strictEqual(yield* rowCount(), 0);
    }),
  );

  it.effect("a transcript backfill is the baseline later turns fold onto and a revert keeps", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngineService;
      const snapshotQuery = yield* ProjectionSnapshotQuery;
      const createdAt = "2026-09-12T00:00:00.000Z";
      const projectId = ProjectId.make("project-backfill");
      const threadId = ThreadId.make("thread-backfill");
      const modelSelection = { instanceId: ProviderInstanceId.make("claude"), model: "opus" };
      const shell = () =>
        snapshotQuery.getThreadShellById(threadId).pipe(Effect.map(Option.getOrThrow));
      const transcript = {
        source: "transcript" as const,
        turns: 3,
        inputTokens: 500,
        outputTokens: 50,
        cachedInputTokens: 400,
        cacheCreationTokens: 20,
        reasoningTokens: 0,
        subagentTurns: 0,
        costUsd: 0.1,
        models: ["claude-sonnet-5"],
        lastTurnAt: "2026-09-11T00:00:00.000Z",
      };

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make("cmd-backfill-project"),
        projectId,
        title: "Backfill",
        workspaceRoot: "/tmp/project-backfill",
        defaultModelSelection: modelSelection,
        createdAt,
      });
      yield* engine.dispatch({
        type: "thread.create",
        commandId: CommandId.make("cmd-backfill-thread"),
        threadId,
        projectId,
        title: "Legacy",
        modelSelection,
        runtimeMode: "full-access",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        createdAt,
      });
      yield* engine.dispatch({
        type: "thread.usage.backfill",
        commandId: CommandId.make("cmd-backfill-1"),
        threadId,
        usage: transcript,
        createdAt: "2026-09-12T00:01:00.000Z",
      });
      assert.deepStrictEqual((yield* shell()).usage, transcript);

      // A runtime turn folds onto the estimate, which keeps its source.
      yield* engine.dispatch({
        type: "thread.turn.usage.record",
        commandId: CommandId.make("cmd-backfill-record"),
        threadId,
        turnUsage: turn("turn-1", "2026-09-12T00:02:00.000Z", 0.25),
        createdAt: "2026-09-12T00:02:00.000Z",
      });
      const folded = (yield* shell()).usage;
      assert.strictEqual(folded?.source, "transcript");
      assert.strictEqual(folded?.turns, 4);
      assert.strictEqual(folded?.inputTokens, 1500);
      assert.closeTo(folded?.costUsd ?? -1, 0.35, 1e-9);
      assert.deepStrictEqual(folded?.models, ["claude-sonnet-5", "claude-opus-4-7"]);
      assert.strictEqual(folded?.lastTurnAt, "2026-09-12T00:02:00.000Z");

      // A second estimate is refused: the thread has a rollup.
      const refused = yield* engine
        .dispatch({
          type: "thread.usage.backfill",
          commandId: CommandId.make("cmd-backfill-2"),
          threadId,
          usage: transcript,
          createdAt: "2026-09-12T00:03:00.000Z",
        })
        .pipe(Effect.flip);
      assert.include(String(refused), "already has a usage rollup");

      // Reverting prunes the runtime row; the transcript estimate stays.
      yield* engine.dispatch({
        type: "thread.revert.complete",
        commandId: CommandId.make("cmd-backfill-revert"),
        threadId,
        turnCount: 0,
        createdAt: "2026-09-12T00:04:00.000Z",
      });
      assert.deepStrictEqual((yield* shell()).usage, transcript);
    }),
  );

  it.effect("the backfill candidates are the Claude bindings with no rollup and no live turn", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngineService;
      const repository = yield* ProjectionTurnUsageRepository;
      const sql = yield* SqlClient.SqlClient;
      const createdAt = "2026-09-12T00:00:00.000Z";
      const projectId = ProjectId.make("project-candidates");
      const modelSelection = { instanceId: ProviderInstanceId.make("claude"), model: "opus" };
      const candidates = () => repository.listBackfillCandidates({ limit: 10 });
      const bind = (threadId: ThreadId, providerName: string, cursor: string | null) => sql`
        INSERT INTO provider_session_runtime (
          thread_id, provider_name, adapter_key, runtime_mode, status, last_seen_at,
          resume_cursor_json, runtime_payload_json
        )
        VALUES (
          ${threadId}, ${providerName}, ${providerName}, 'full-access', 'idle', ${createdAt},
          ${cursor}, NULL
        )
      `;
      const createThread = (threadId: ThreadId, commandId: string) =>
        engine.dispatch({
          type: "thread.create",
          commandId: CommandId.make(commandId),
          threadId,
          projectId,
          title: threadId,
          modelSelection,
          runtimeMode: "full-access",
          interactionMode: "default",
          branch: null,
          worktreePath: null,
          createdAt,
        });

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make("cmd-candidates-project"),
        projectId,
        title: "Candidates",
        workspaceRoot: "/tmp/project-candidates",
        defaultModelSelection: modelSelection,
        createdAt,
      });
      const legacy = ThreadId.make("thread-candidate-legacy");
      const codex = ThreadId.make("thread-candidate-codex");
      const unbound = ThreadId.make("thread-candidate-unbound");
      yield* createThread(legacy, "cmd-candidates-legacy");
      yield* createThread(codex, "cmd-candidates-codex");
      yield* createThread(unbound, "cmd-candidates-unbound");
      yield* bind(legacy, "claudeAgent", `{"threadId":"${legacy}","resume":"session-x"}`);
      yield* bind(codex, "codex", `{"threadId":"${codex}","resume":"session-codex"}`);
      yield* bind(unbound, "claudeAgent", `{"threadId":"${unbound}"}`);

      // Only the Claude binding whose cursor names a session; no turns yet.
      assert.deepStrictEqual(yield* candidates(), [
        { threadId: legacy, providerSessionId: "session-x", turns: 0, lastTurnAt: null },
      ]);

      // A turn in flight hides the thread; its row, of any state, is the marker.
      yield* sql`
        INSERT INTO projection_turns (thread_id, turn_id, state, requested_at, checkpoint_files_json)
        VALUES (${legacy}, 'turn-live', 'running', '2026-09-12T00:05:00.000Z', '[]')
      `;
      assert.deepStrictEqual(yield* candidates(), []);
      yield* sql`
        UPDATE projection_turns SET state = 'interrupted', completed_at = NULL
        WHERE thread_id = ${legacy} AND turn_id = 'turn-live'
      `;
      assert.deepStrictEqual(yield* candidates(), [
        {
          threadId: legacy,
          providerSessionId: "session-x",
          turns: 0,
          lastTurnAt: "2026-09-12T00:05:00.000Z",
        },
      ]);
      yield* sql`
        UPDATE projection_turns SET state = 'completed', completed_at = '2026-09-12T00:06:00.000Z'
        WHERE thread_id = ${legacy} AND turn_id = 'turn-live'
      `;
      assert.deepStrictEqual(yield* candidates(), [
        {
          threadId: legacy,
          providerSessionId: "session-x",
          turns: 1,
          lastTurnAt: "2026-09-12T00:06:00.000Z",
        },
      ]);
      assert.deepStrictEqual(
        yield* repository.listBackfillCandidates({ threadId: codex, limit: 10 }),
        [],
      );

      // A rollup, from a backfill or the runtime, retires the thread.
      yield* engine.dispatch({
        type: "thread.usage.backfill",
        commandId: CommandId.make("cmd-candidates-backfill"),
        threadId: legacy,
        usage: {
          source: "transcript",
          turns: 1,
          inputTokens: 10,
          outputTokens: 1,
          cachedInputTokens: 0,
          cacheCreationTokens: 0,
          reasoningTokens: 0,
          subagentTurns: 0,
          costUsd: null,
          models: [],
          lastTurnAt: "2026-09-12T00:06:00.000Z",
        },
        createdAt: "2026-09-12T00:07:00.000Z",
      });
      assert.deepStrictEqual(yield* candidates(), []);
    }),
  );
});
