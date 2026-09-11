import * as Effect from "effect/Effect";
import * as SqlClient from "effect/unstable/sql/SqlClient";

/**
 * Fork (#806): the server-side message queue. One row per message queued on a
 * thread, ordered by a fractional key; the drain turns a row into a
 * `thread.turn.start` when the thread is idle and the decider removes it in
 * the same event batch as the send.
 */
export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  yield* sql`
    CREATE TABLE IF NOT EXISTS projection_thread_queued_turns (
      queue_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      text TEXT NOT NULL,
      attachments_json TEXT NOT NULL,
      model_selection_json TEXT,
      order_key TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;

  yield* sql`
    CREATE INDEX IF NOT EXISTS idx_projection_thread_queued_turns_thread_order
    ON projection_thread_queued_turns(thread_id, order_key)
  `;
});
