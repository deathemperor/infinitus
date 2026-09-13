import { ThreadId, ThreadTurnUsage, TurnId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Struct from "effect/Struct";
import * as SqlClient from "effect/unstable/sql/SqlClient";
import * as SqlSchema from "effect/unstable/sql/SqlSchema";

import { toPersistenceSqlError, type ProjectionRepositoryError } from "./Errors.ts";

/**
 * Fork (#834): one row per completed turn with what it cost. The thread's
 * rollup lives on `projection_threads.usage_json`; these rows are what a
 * revert refolds it from once the pruned turns' rows are gone.
 */
export const ProjectionTurnUsage = Schema.Struct({
  threadId: ThreadId,
  turnUsage: ThreadTurnUsage,
});
export type ProjectionTurnUsage = typeof ProjectionTurnUsage.Type;

export const ListProjectionTurnUsageInput = Schema.Struct({
  threadId: ThreadId,
});
export type ListProjectionTurnUsageInput = typeof ListProjectionTurnUsageInput.Type;

/**
 * A thread the transcript backfill may estimate (#834): a Claude session
 * binding whose cursor names the session, no rollup and no baseline yet,
 * not deleted, and no turn pending or running (a turn mid-flight would be
 * read half-way and then recorded on top). `turns` counts its completed
 * turns; `lastTurnAt` is the newest mark on any turn row, whatever its
 * state (an interrupted or errored first turn is one this server already
 * saw), for the caller to tell a legacy thread from one whose turns this
 * server already records.
 */
export const ThreadUsageBackfillCandidate = Schema.Struct({
  threadId: ThreadId,
  providerSessionId: Schema.String,
  turns: Schema.Number,
  lastTurnAt: Schema.NullOr(Schema.String),
});
export type ThreadUsageBackfillCandidate = typeof ThreadUsageBackfillCandidate.Type;

export const ListThreadUsageBackfillCandidatesInput = Schema.Struct({
  threadId: Schema.optional(ThreadId),
  limit: Schema.Number,
});
export type ListThreadUsageBackfillCandidatesInput =
  typeof ListThreadUsageBackfillCandidatesInput.Type;

export const DeleteProjectionTurnUsageExceptInput = Schema.Struct({
  threadId: ThreadId,
  /** The turns whose rows stay. */
  turnIds: Schema.Array(TurnId),
});
export type DeleteProjectionTurnUsageExceptInput = typeof DeleteProjectionTurnUsageExceptInput.Type;

export const SumProjectionTurnUsageSinceInput = Schema.Struct({
  /** ISO instant; rows completed at or after it are summed. */
  since: Schema.String,
});
export type SumProjectionTurnUsageSinceInput = typeof SumProjectionTurnUsageSinceInput.Type;

/**
 * Fork (#1127): the turns of every thread that completed inside a window and
 * what they reported. Turns whose provider reported no usage are left out —
 * their tokens are zero for "not reported", and counting them would read as
 * work that spent nothing.
 */
export const ProjectionTurnUsageSum = Schema.Struct({
  turns: Schema.Number,
  inputTokens: Schema.Number,
  outputTokens: Schema.Number,
});
export type ProjectionTurnUsageSum = typeof ProjectionTurnUsageSum.Type;

const ProjectionTurnUsageDbRow = ProjectionTurnUsage.mapFields(
  Struct.assign({ turnUsage: Schema.fromJsonString(ThreadTurnUsage) }),
);

export class ProjectionTurnUsageRepository extends Context.Service<
  ProjectionTurnUsageRepository,
  {
    /** Insert or replace by thread and turn. */
    readonly upsert: (row: ProjectionTurnUsage) => Effect.Effect<void, ProjectionRepositoryError>;
    /** A thread's rows, oldest completion first. */
    readonly listByThreadId: (
      input: ListProjectionTurnUsageInput,
    ) => Effect.Effect<ReadonlyArray<ProjectionTurnUsage>, ProjectionRepositoryError>;
    /** Drop every row of the thread but the named turns' (a revert). */
    readonly deleteByThreadIdExcept: (
      input: DeleteProjectionTurnUsageExceptInput,
    ) => Effect.Effect<void, ProjectionRepositoryError>;
    readonly deleteByThreadId: (
      input: ListProjectionTurnUsageInput,
    ) => Effect.Effect<void, ProjectionRepositoryError>;
    /** Every thread's turns that completed at or after an instant, summed. */
    readonly sumSince: (
      input: SumProjectionTurnUsageSinceInput,
    ) => Effect.Effect<ProjectionTurnUsageSum, ProjectionRepositoryError>;
    /** Threads the transcript backfill may estimate, most recently active first. */
    readonly listBackfillCandidates: (
      input: ListThreadUsageBackfillCandidatesInput,
    ) => Effect.Effect<ReadonlyArray<ThreadUsageBackfillCandidate>, ProjectionRepositoryError>;
  }
>()("t3/persistence/ProjectionTurnUsage/ProjectionTurnUsageRepository") {}

const make = Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  const upsertRow = SqlSchema.void({
    Request: ProjectionTurnUsage,
    execute: (row) => sql`
      INSERT INTO projection_turn_usage (thread_id, turn_id, usage_json, completed_at)
      VALUES (
        ${row.threadId},
        ${row.turnUsage.turnId},
        ${JSON.stringify(row.turnUsage)},
        ${row.turnUsage.completedAt}
      )
      ON CONFLICT (thread_id, turn_id)
      DO UPDATE SET
        usage_json = excluded.usage_json,
        completed_at = excluded.completed_at
    `,
  });

  const listRowsByThread = SqlSchema.findAll({
    Request: ListProjectionTurnUsageInput,
    Result: ProjectionTurnUsageDbRow,
    execute: ({ threadId }) => sql`
      SELECT thread_id AS "threadId", usage_json AS "turnUsage"
      FROM projection_turn_usage
      WHERE thread_id = ${threadId}
      ORDER BY completed_at ASC, turn_id ASC
    `,
  });

  const deleteRowsExcept = SqlSchema.void({
    Request: DeleteProjectionTurnUsageExceptInput,
    execute: ({ threadId, turnIds }) => sql`
      DELETE FROM projection_turn_usage
      WHERE thread_id = ${threadId}
      ${turnIds.length === 0 ? sql`` : sql`AND NOT ${sql.in("turn_id", turnIds)}`}
    `,
  });

  const deleteRowsByThread = SqlSchema.void({
    Request: ListProjectionTurnUsageInput,
    execute: ({ threadId }) => sql`
      DELETE FROM projection_turn_usage
      WHERE thread_id = ${threadId}
    `,
  });

  const sumRowsSince = SqlSchema.findAll({
    Request: SumProjectionTurnUsageSinceInput,
    Result: ProjectionTurnUsageSum,
    execute: ({ since }) => sql`
      SELECT
        COUNT(*) AS "turns",
        COALESCE(SUM(json_extract(usage_json, '$.inputTokens')), 0) AS "inputTokens",
        COALESCE(SUM(json_extract(usage_json, '$.outputTokens')), 0) AS "outputTokens"
      FROM projection_turn_usage
      WHERE completed_at >= ${since}
        AND json_extract(usage_json, '$.usageUnavailable') IS NULL
    `,
  });

  const listCandidates = SqlSchema.findAll({
    Request: ListThreadUsageBackfillCandidatesInput,
    Result: ThreadUsageBackfillCandidate,
    execute: ({ threadId, limit }) => sql`
      SELECT
        runtime.thread_id AS "threadId",
        json_extract(runtime.resume_cursor_json, '$.resume') AS "providerSessionId",
        (
          SELECT COUNT(*) FROM projection_turns AS turns
          WHERE turns.thread_id = runtime.thread_id AND turns.state = 'completed'
        ) AS "turns",
        (
          SELECT MAX(COALESCE(turns.completed_at, turns.started_at, turns.requested_at))
          FROM projection_turns AS turns
          WHERE turns.thread_id = runtime.thread_id
        ) AS "lastTurnAt"
      FROM provider_session_runtime AS runtime
      JOIN projection_threads AS threads ON threads.thread_id = runtime.thread_id
      WHERE runtime.provider_name = 'claudeAgent'
        AND json_type(runtime.resume_cursor_json, '$.resume') = 'text'
        AND threads.usage_json IS NULL
        AND threads.usage_baseline_json IS NULL
        AND threads.deleted_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM projection_turns AS live
          WHERE live.thread_id = runtime.thread_id AND live.state IN ('pending', 'running')
        )
        ${threadId === undefined ? sql`` : sql`AND runtime.thread_id = ${threadId}`}
      ORDER BY threads.updated_at DESC
      LIMIT ${limit}
    `,
  });

  const upsert: ProjectionTurnUsageRepository["Service"]["upsert"] = (row) =>
    upsertRow(row).pipe(
      Effect.mapError(toPersistenceSqlError("ProjectionTurnUsageRepository.upsert:query")),
    );
  const listByThreadId: ProjectionTurnUsageRepository["Service"]["listByThreadId"] = (input) =>
    listRowsByThread(input).pipe(
      Effect.mapError(toPersistenceSqlError("ProjectionTurnUsageRepository.listByThreadId:query")),
    );
  const deleteByThreadIdExcept: ProjectionTurnUsageRepository["Service"]["deleteByThreadIdExcept"] =
    (input) =>
      deleteRowsExcept(input).pipe(
        Effect.mapError(
          toPersistenceSqlError("ProjectionTurnUsageRepository.deleteByThreadIdExcept:query"),
        ),
      );
  const deleteByThreadId: ProjectionTurnUsageRepository["Service"]["deleteByThreadId"] = (input) =>
    deleteRowsByThread(input).pipe(
      Effect.mapError(
        toPersistenceSqlError("ProjectionTurnUsageRepository.deleteByThreadId:query"),
      ),
    );

  const sumSince: ProjectionTurnUsageRepository["Service"]["sumSince"] = (input) =>
    sumRowsSince(input).pipe(
      Effect.map((rows) => rows[0] ?? { turns: 0, inputTokens: 0, outputTokens: 0 }),
      Effect.mapError(toPersistenceSqlError("ProjectionTurnUsageRepository.sumSince:query")),
    );

  const listBackfillCandidates: ProjectionTurnUsageRepository["Service"]["listBackfillCandidates"] =
    (input) =>
      listCandidates(input).pipe(
        Effect.mapError(
          toPersistenceSqlError("ProjectionTurnUsageRepository.listBackfillCandidates:query"),
        ),
      );

  return {
    upsert,
    listByThreadId,
    deleteByThreadIdExcept,
    deleteByThreadId,
    sumSince,
    listBackfillCandidates,
  } satisfies ProjectionTurnUsageRepository["Service"];
});

export const layer = Layer.effect(ProjectionTurnUsageRepository, make);
