import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/** Fork (#269 B): the best-of-N group a thread was started in. */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const columns = yield* sql<{ readonly name: string }>`
    PRAGMA table_info(projection_threads)
  `;

  if (!columns.some((column) => column.name === "group_id")) {
    yield* sql`
      ALTER TABLE projection_threads
      ADD COLUMN group_id TEXT
    `;
  }
});
