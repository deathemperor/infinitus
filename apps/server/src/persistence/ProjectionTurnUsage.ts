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

export const DeleteProjectionTurnUsageExceptInput = Schema.Struct({
  threadId: ThreadId,
  /** The turns whose rows stay. */
  turnIds: Schema.Array(TurnId),
});
export type DeleteProjectionTurnUsageExceptInput = typeof DeleteProjectionTurnUsageExceptInput.Type;

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

  return {
    upsert,
    listByThreadId,
    deleteByThreadIdExcept,
    deleteByThreadId,
  } satisfies ProjectionTurnUsageRepository["Service"];
});

export const layer = Layer.effect(ProjectionTurnUsageRepository, make);
