import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/** Fork (#269 C): the thread a side question belongs to. */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const columns = yield* sql<{ readonly name: string }>`
    PRAGMA table_info(projection_threads)
  `;

  if (!columns.some((column) => column.name === "side_of")) {
    yield* sql`
      ALTER TABLE projection_threads
      ADD COLUMN side_of TEXT
    `;
  }
});
