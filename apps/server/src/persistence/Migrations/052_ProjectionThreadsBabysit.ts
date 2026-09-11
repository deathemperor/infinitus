import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/** Fork (#269 A): the babysit state of a thread, as JSON (`ThreadBabysit`). */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const columns = yield* sql<{ readonly name: string }>`
    PRAGMA table_info(projection_threads)
  `;

  if (!columns.some((column) => column.name === "babysit_json")) {
    yield* sql`
      ALTER TABLE projection_threads
      ADD COLUMN babysit_json TEXT
    `;
  }
});
