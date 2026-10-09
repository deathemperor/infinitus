import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as SqlClient from "effect/sql/SqlClient";

import { migrationEntries, runMigrations } from "../Migrations.ts";
import * as NodeSqliteClient from "@infinitus/shared/nodeSqliteClient";

const layer = it.layer(Layer.mergeAll(NodeSqliteClient.layer({ filename: ":memory:" })));

layer("065_OrchestrationV2", (it) => {
  it.effect("keeps released migrations contiguous", () =>
    Effect.sync(() => {
      assert.deepStrictEqual(
        migrationEntries.map(([id]) => id),
        Array.from({ length: 70 }, (_, index) => index + 1),
      );
    }),
  );

  // The fork's own 51-64 sit before upstream's V2 migrations (INFINITUS.md).
  it.effect("upgrades released schema 64 through the latest migrations", () =>
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;
      yield* runMigrations({ toMigrationInclusive: 64 });

      const executed = yield* runMigrations();
      assert.deepStrictEqual(executed, [
        [65, "OrchestrationV2"],
        [66, "RemoveRedundantProjectionIndexes"],
        [67, "ScheduledTaskWebhooks"],
        [68, "WebhookRelayDeliveries"],
        [69, "McpAppModelContext"],
        [70, "ThreadSnapshotWindowIndexes"],
      ]);
      assert.deepStrictEqual(yield* runMigrations(), []);

      const migrations = yield* sql<{
        readonly migration_id: number;
        readonly name: string;
      }>`
        SELECT migration_id, name
        FROM effect_sql_migrations
        WHERE migration_id >= 48
        ORDER BY migration_id
      `;
      assert.deepStrictEqual(migrations, [
        { migration_id: 48, name: "ProjectionThreadBranchPullRequest" },
        { migration_id: 49, name: "ProjectionThreadsActiveOrderKey" },
        { migration_id: 50, name: "ProjectionThreadPullRequests" },
        { migration_id: 51, name: "ProjectionThreadQueuedTurns" },
        { migration_id: 52, name: "ProjectionThreadsBabysit" },
        { migration_id: 53, name: "ProjectionThreadsSideOf" },
        { migration_id: 54, name: "ProjectionThreadsGroupId" },
        { migration_id: 55, name: "ProjectionThreadSessionsStatusReason" },
        { migration_id: 56, name: "ProjectionTurnUsage" },
        { migration_id: 57, name: "ProjectionThreadsUsageBaseline" },
        { migration_id: 58, name: "ProjectionThreadMessageContext" },
        { migration_id: 59, name: "ProjectionThreadQueuedTurnsContext" },
        { migration_id: 60, name: "ProjectionTurnUsageCompletedAtIndex" },
        { migration_id: 61, name: "ProjectionThreadTitleState" },
        { migration_id: 62, name: "ProjectionThreadQueuedTurnsSendAt" },
        { migration_id: 63, name: "PullRequestFilesViewed" },
        { migration_id: 64, name: "ProjectionThreadsAutoSettleDisabledAt" },
        { migration_id: 65, name: "OrchestrationV2" },
        { migration_id: 66, name: "RemoveRedundantProjectionIndexes" },
        { migration_id: 67, name: "ScheduledTaskWebhooks" },
        { migration_id: 68, name: "WebhookRelayDeliveries" },
        { migration_id: 69, name: "McpAppModelContext" },
        { migration_id: 70, name: "ThreadSnapshotWindowIndexes" },
      ]);

      const tables = yield* sql<{ readonly name: string }>`
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name IN (
            'orchestration_v2_projection_threads',
            'orchestration_v2_projection_subagents',
            'orchestration_v2_effect_outbox',
            'orchestration_v2_turn_item_positions',
            'orchestration_v2_projection_metadata',
            'orchestration_v2_projection_provider_session_bindings',
            'orchestration_v2_thread_launch_workflows',
            'orchestration_v2_legacy_imports',
            'scheduled_tasks'
          )
        ORDER BY name
      `;
      assert.deepStrictEqual(
        tables.map(({ name }) => name),
        [
          "orchestration_v2_effect_outbox",
          "orchestration_v2_legacy_imports",
          "orchestration_v2_projection_metadata",
          "orchestration_v2_projection_provider_session_bindings",
          "orchestration_v2_projection_subagents",
          "orchestration_v2_projection_threads",
          "orchestration_v2_thread_launch_workflows",
          "orchestration_v2_turn_item_positions",
          "scheduled_tasks",
        ],
      );

      const eventColumns = yield* sql<{ readonly name: string }>`
        PRAGMA table_info(orchestration_events)
      `;
      const receiptColumns = yield* sql<{ readonly name: string }>`
        PRAGMA table_info(orchestration_command_receipts)
      `;
      const threadColumns = yield* sql<{ readonly name: string }>`
        PRAGMA table_info(orchestration_v2_projection_threads)
      `;
      const subagentColumns = yield* sql<{ readonly name: string }>`
        PRAGMA table_info(orchestration_v2_projection_subagents)
      `;
      assert.ok(eventColumns.some(({ name }) => name === "application_event_version"));
      assert.ok(receiptColumns.some(({ name }) => name === "command_type"));
      assert.ok(threadColumns.some(({ name }) => name === "provider_instance_id"));
      assert.ok(subagentColumns.some(({ name }) => name === "driver"));
      assert.ok(subagentColumns.some(({ name }) => name === "provider_instance_id"));

      const indexes = yield* sql<{ readonly name: string }>`
        SELECT name
        FROM sqlite_master
        WHERE type = 'index'
          AND name IN (
            'idx_orchestration_events_application_high_water',
            'orchestration_events_v2_created_threads_idx',
            'orchestration_v2_projection_turn_items_shell_pending_idx'
          )
        ORDER BY name
      `;
      assert.deepStrictEqual(
        indexes.map(({ name }) => name),
        [
          "idx_orchestration_events_application_high_water",
          "orchestration_events_v2_created_threads_idx",
          "orchestration_v2_projection_turn_items_shell_pending_idx",
        ],
      );
    }),
  );
});
