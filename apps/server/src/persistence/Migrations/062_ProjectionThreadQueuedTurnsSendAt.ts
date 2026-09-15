import * as SqlClient from "effect/unstable/sql/SqlClient";
import * as Effect from "effect/Effect";

// Fork (#1318): when a queued row is due; null is "idle".
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const columns = yield* sql<{ readonly name: string }>`
    PRAGMA table_info(projection_thread_queued_turns)
  `;

  if (!columns.some((column) => column.name === "send_at")) {
    yield* sql`
      ALTER TABLE projection_thread_queued_turns
      ADD COLUMN send_at TEXT
    `;
  }
});
