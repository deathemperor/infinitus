import {
  CommandId,
  ProjectId,
  ProviderInstanceId,
  ThreadBabysit,
  ThreadId,
} from "@t3tools/contracts";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
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

const decodeBabysitJson = Schema.decodeUnknownEffect(Schema.fromJsonString(ThreadBabysit));

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
    Layer.provideMerge(ServerConfig.layerTest(process.cwd(), { prefix: "t3-babysit-projection-" })),
    Layer.provideMerge(NodeServices.layer),
  ),
);

engineLayer("babysit on the thread projection (#269 A)", (it) => {
  it.effect("meta updates set, bump, keep and clear it, through the store and back", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngineService;
      const snapshotQuery = yield* ProjectionSnapshotQuery;
      const sql = yield* SqlClient.SqlClient;
      const createdAt = "2026-09-12T00:00:00.000Z";
      const projectId = ProjectId.make("project-babysit");
      const threadId = ThreadId.make("thread-babysit");
      const modelSelection = { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5" };
      const shell = () =>
        snapshotQuery.getThreadShellById(threadId).pipe(Effect.map(Option.getOrThrow));
      const update = (commandId: string, fields: { babysit?: boolean; babysitRounds?: number }) =>
        engine.dispatch({
          type: "thread.meta.update",
          commandId: CommandId.make(commandId),
          threadId,
          ...fields,
        });

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make("cmd-babysit-project"),
        projectId,
        title: "Babysit",
        workspaceRoot: "/tmp/project-babysit",
        defaultModelSelection: modelSelection,
        createdAt,
      });
      yield* engine.dispatch({
        type: "thread.create",
        commandId: CommandId.make("cmd-babysit-thread"),
        threadId,
        projectId,
        title: "Babysat",
        modelSelection,
        runtimeMode: "full-access",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        createdAt,
      });
      assert.isUndefined((yield* shell()).babysit);

      yield* update("cmd-babysit-on", { babysit: true });
      const on = (yield* shell()).babysit;
      assert.isNotNull(on);
      assert.strictEqual(on?.rounds, 0);
      const since = on?.since;

      yield* update("cmd-babysit-round", { babysitRounds: 3 });
      assert.deepStrictEqual((yield* shell()).babysit, { since, rounds: 3 });

      // On again is idempotent: the start and the rounds stay.
      yield* update("cmd-babysit-on-again", { babysit: true });
      assert.deepStrictEqual((yield* shell()).babysit, { since, rounds: 3 });
      const rows = yield* sql<{ readonly babysit: string | null }>`
        SELECT babysit_json AS babysit FROM projection_threads WHERE thread_id = ${threadId}
      `;
      assert.deepStrictEqual(yield* decodeBabysitJson(rows[0]?.babysit), { since, rounds: 3 });

      yield* update("cmd-babysit-off", { babysit: false });
      assert.isUndefined((yield* shell()).babysit);
      // A round count while off changes nothing.
      yield* update("cmd-babysit-round-off", { babysitRounds: 4 });
      assert.isUndefined((yield* shell()).babysit);

      // Fork (#269 C): a side question carries its main thread through the store.
      const sideId = ThreadId.make("thread-side");
      yield* engine.dispatch({
        type: "thread.create",
        commandId: CommandId.make("cmd-side-thread"),
        threadId: sideId,
        projectId,
        title: "Side question: Babysat",
        modelSelection,
        runtimeMode: "full-access",
        interactionMode: "plan",
        branch: null,
        worktreePath: null,
        createdAt,
        sideOf: threadId,
      });
      const side = yield* snapshotQuery
        .getThreadShellById(sideId)
        .pipe(Effect.map(Option.getOrThrow));
      assert.strictEqual(side.sideOf, threadId);
      assert.isUndefined((yield* shell()).sideOf);
      const sideRows = yield* sql<{ readonly sideOf: string | null }>`
        SELECT side_of AS "sideOf" FROM projection_threads WHERE thread_id = ${sideId}
      `;
      assert.strictEqual(sideRows[0]?.sideOf, threadId);
    }),
  );
});
