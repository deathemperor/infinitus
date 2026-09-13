import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/**
 * Fork (#1127): the live rate reads every thread's turns that completed
 * inside a five-minute window. The table's only key is (thread_id, turn_id),
 * so that read is a full scan of every turn this server ever recorded, which
 * grows without bound. This index makes the window a range scan.
 */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  yield* sql`
    CREATE INDEX IF NOT EXISTS idx_projection_turn_usage_completed_at
    ON projection_turn_usage(completed_at)
  `;
});
