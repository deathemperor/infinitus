import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/**
 * Fork (#834): what each completed turn cost, one row per turn
 * (`ThreadTurnUsage` as JSON), and the thread's rollup on its row
 * (`usage_json`, a `ThreadUsageRollup`) so every thread read carries it
 * without a join. Rows go with their turns on a revert and with the thread.
 */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  yield* sql`
    CREATE TABLE IF NOT EXISTS projection_turn_usage (
      thread_id TEXT NOT NULL,
      turn_id TEXT NOT NULL,
      usage_json TEXT NOT NULL,
      completed_at TEXT NOT NULL,
      PRIMARY KEY (thread_id, turn_id)
    )
  `;

  const columns = yield* sql<{ readonly name: string }>`
    PRAGMA table_info(projection_threads)
  `;
  if (!columns.some((column) => column.name === "usage_json")) {
    yield* sql`
      ALTER TABLE projection_threads
      ADD COLUMN usage_json TEXT
    `;
  }
});
