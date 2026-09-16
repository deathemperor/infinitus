import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as SqlClient from "effect/unstable/sql/SqlClient";

import { runMigrations } from "../Migrations.ts";
import * as NodeSqliteClient from "@infinitus/shared/nodeSqliteClient";

const layer = it.layer(Layer.mergeAll(NodeSqliteClient.layerMemory()));

layer("060_ProjectionTurnUsageCompletedAtIndex", (it) => {
  it.effect("puts the live rate's window read on an index instead of a table scan", () =>
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;

      yield* runMigrations({ toMigrationInclusive: 59 });
      const before = yield* sql<{ readonly detail: string }>`
        EXPLAIN QUERY PLAN
        SELECT thread_id, usage_json
        FROM projection_turn_usage
        WHERE completed_at >= '2026-09-14T11:55:00.000Z'
        ORDER BY completed_at ASC, turn_id ASC
      `;
      assert.ok(before.some((row) => row.detail.includes("SCAN")));

      yield* runMigrations({ toMigrationInclusive: 60 });

      const after = yield* sql<{ readonly detail: string }>`
        EXPLAIN QUERY PLAN
        SELECT thread_id, usage_json
        FROM projection_turn_usage
        WHERE completed_at >= '2026-09-14T11:55:00.000Z'
        ORDER BY completed_at ASC, turn_id ASC
      `;
      assert.ok(
        after.some((row) => row.detail.includes("idx_projection_turn_usage_completed_at")),
        after.map((row) => row.detail).join(" | "),
      );
      assert.ok(!after.some((row) => row.detail.includes("SCAN projection_turn_usage")));
    }),
  );
});
