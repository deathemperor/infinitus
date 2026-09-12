import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/**
 * Fork (#834, backfill): a thread's transcript-estimated rollup
 * (`usage_baseline_json`, a `ThreadUsageRollup` with `source: "transcript"`),
 * which the runtime rows in `projection_turn_usage` fold onto. Kept apart
 * from `usage_json` so a refold from the rows (a recorded turn, a revert)
 * does not erase what the transcript said.
 */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const columns = yield* sql<{ readonly name: string }>`
    PRAGMA table_info(projection_threads)
  `;
  if (!columns.some((column) => column.name === "usage_baseline_json")) {
    yield* sql`
      ALTER TABLE projection_threads
      ADD COLUMN usage_baseline_json TEXT
    `;
  }
});
