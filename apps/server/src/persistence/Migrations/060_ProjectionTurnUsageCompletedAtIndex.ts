import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/**
 * Fork (#1127): the live token rate reads every thread's turns from an instant
 * on (`listCompletedSince`), where the table's only index is its thread-first
 * primary key. Without this the Utilization page's half-minute poll scans the
 * whole row set, which grows with every turn the server ever ran.
 */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  yield* sql`
    CREATE INDEX IF NOT EXISTS idx_projection_turn_usage_completed_at
    ON projection_turn_usage(completed_at)
  `;
});
