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
});
