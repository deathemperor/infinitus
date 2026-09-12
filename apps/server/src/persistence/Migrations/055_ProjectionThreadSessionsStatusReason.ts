import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/** Fork (#832): the provider's reason behind a running session (`reconnecting:n/max`). */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const columns = yield* sql<{ readonly name: string }>`
    PRAGMA table_info(projection_thread_sessions)
  `;

  if (!columns.some((column) => column.name === "status_reason")) {
    yield* sql`
      ALTER TABLE projection_thread_sessions
      ADD COLUMN status_reason TEXT
    `;
  }
});
