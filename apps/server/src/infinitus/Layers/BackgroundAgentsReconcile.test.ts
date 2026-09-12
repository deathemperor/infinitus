import { CommandId, EventId, ProjectId, ProviderInstanceId, ThreadId } from "@t3tools/contracts";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import { ServerConfig } from "../../config.ts";
import { OrchestrationCommandReceiptRepositoryLive } from "../../persistence/Layers/OrchestrationCommandReceipts.ts";
import { OrchestrationEventStoreLive } from "../../persistence/Layers/OrchestrationEventStore.ts";
import { SqlitePersistenceMemory } from "../../persistence/Layers/Sqlite.ts";
import * as RepositoryIdentityResolver from "../../project/RepositoryIdentityResolver.ts";
import { OrchestrationEngineLive } from "../../orchestration/Layers/OrchestrationEngine.ts";
import { OrchestrationProjectionPipelineLive } from "../../orchestration/Layers/ProjectionPipeline.ts";
import { OrchestrationProjectionSnapshotQueryLive } from "../../orchestration/Layers/ProjectionSnapshotQuery.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import * as ThreadBackgroundLiveness from "../../orchestration/ThreadBackgroundLiveness.ts";
import * as ThreadPlanProgress from "../../orchestration/ThreadPlanProgress.ts";
import * as ProviderService from "../../provider/Services/ProviderService.ts";
import { liveBackgroundAgentsMessage } from "../backgroundAgents.logic.ts";
import { reconcileBackgroundAgents } from "./BackgroundAgentsReconcile.ts";

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
    Layer.provideMerge(ServerConfig.layerTest(process.cwd(), { prefix: "t3-bg-agents-" })),
    Layer.provideMerge(NodeServices.layer),
  ),
);

const noLiveSessions = {
  listSessions: () => Effect.succeed([]),
} as unknown as ProviderService.ProviderService["Service"];

engineLayer("background agents reconcile at boot (#977)", (it) => {
  it.effect("a killed server's live background agents get the stopped rows and the error", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngineService;
      const snapshotQuery = yield* ProjectionSnapshotQuery;
      const createdAt = "2026-09-12T00:00:00.000Z";
      const projectId = ProjectId.make("project-bg");
      const orphaned = ThreadId.make("thread-orphaned");
      const finished = ThreadId.make("thread-finished");
      const modelSelection = { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5" };
      let seq = 0;
      const nextId = () => `bg-${seq++}`;

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make(nextId()),
        projectId,
        title: "Background",
        workspaceRoot: "/tmp/project-bg",
        defaultModelSelection: modelSelection,
        createdAt,
      });
      for (const threadId of [orphaned, finished]) {
        yield* engine.dispatch({
          type: "thread.create",
          commandId: CommandId.make(nextId()),
          threadId,
          projectId,
          title: String(threadId),
          modelSelection,
          runtimeMode: "full-access",
          interactionMode: "default",
          branch: null,
          worktreePath: null,
          createdAt,
        });
        yield* engine.dispatch({
          type: "thread.session.set",
          commandId: CommandId.make(nextId()),
          threadId,
          session: {
            threadId,
            status: "ready",
            providerName: "codex",
            providerInstanceId: modelSelection.instanceId,
            runtimeMode: "full-access",
            activeTurnId: null,
            lastError: null,
            updatedAt: createdAt,
          },
          createdAt,
        });
      }
      const append = (threadId: ThreadId, kind: string, payload: Record<string, unknown>) =>
        engine.dispatch({
          type: "thread.activity.append",
          commandId: CommandId.make(nextId()),
          threadId,
          activity: {
            id: EventId.make(nextId()),
            tone: "info",
            kind,
            summary: kind,
            payload,
            turnId: null,
            createdAt,
          },
          createdAt,
        });
      const agent = (taskId: string, extra: Record<string, unknown> = {}) => ({
        taskId,
        taskType: "local_agent",
        agentKind: "agent",
        title: `Agent ${taskId}`,
        ...extra,
      });
      // Registered in the background and never ended.
      yield* append(orphaned, "task.started", agent("bg", { isBackgrounded: true }));
      // Moved to the background later, never ended.
      yield* append(orphaned, "task.started", agent("later"));
      yield* append(orphaned, "task.updated", { taskId: "later", isBackgrounded: true });
      // Ended, foreground, shell and monitor: none count.
      yield* append(orphaned, "task.started", agent("done", { isBackgrounded: true }));
      yield* append(orphaned, "task.completed", { taskId: "done", status: "completed" });
      yield* append(orphaned, "task.started", agent("fg"));
      yield* append(orphaned, "task.started", {
        taskId: "sh",
        taskType: "local_bash",
        agentKind: "background",
        isBackgrounded: true,
      });
      // The other thread's agent failed before the server died.
      yield* append(finished, "task.started", agent("e1", { isBackgrounded: true }));
      yield* append(finished, "task.updated", { taskId: "e1", status: "failed" });

      const detail = (threadId: ThreadId) =>
        snapshotQuery.getThreadDetailById(threadId).pipe(Effect.map(Option.getOrThrow));
      const beforeIds = new Set((yield* detail(orphaned)).activities.map((a) => a.id));

      const run = reconcileBackgroundAgents.pipe(
        Effect.provideService(ProviderService.ProviderService, noLiveSessions),
      );
      yield* run;

      const after = yield* detail(orphaned);
      // Read order is by id, not append order: compare the set of new rows.
      const added = after.activities.filter((activity) => !beforeIds.has(activity.id));
      const stopped = added.filter((activity) => activity.kind === "task.completed");
      assert.deepStrictEqual(
        stopped
          .map((activity) => activity.payload)
          .sort((a, b) =>
            (a as { taskId: string }).taskId.localeCompare((b as { taskId: string }).taskId),
          ),
        [
          { taskId: "bg", status: "stopped", agentKind: "agent", title: "Agent bg" },
          { taskId: "later", status: "stopped", agentKind: "agent", title: "Agent later" },
        ],
      );
      const error = added.find((activity) => activity.kind === "runtime.error");
      assert.strictEqual(added.length, 3);
      assert.strictEqual(error?.tone, "error");
      assert.deepStrictEqual(error?.payload, { message: liveBackgroundAgentsMessage(2) });
      assert.strictEqual(after.session?.status, "error");
      assert.strictEqual(after.session?.lastError, liveBackgroundAgentsMessage(2));

      const untouched = yield* detail(finished);
      assert.strictEqual(untouched.session?.status, "ready");
      assert.strictEqual(untouched.activities.length, 2);

      // A second boot finds nothing: the stopped rows ended the tasks.
      yield* run;
      assert.strictEqual((yield* detail(orphaned)).activities.length, after.activities.length);
    }),
  );
});
