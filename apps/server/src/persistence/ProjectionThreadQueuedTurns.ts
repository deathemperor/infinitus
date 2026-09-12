import {
  ChatAttachment,
  IsoDateTime,
  MessageId,
  ModelSelection,
  OrchestrationMessageContext,
  QueueId,
  ThreadId,
  TrimmedNonEmptyString,
} from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Struct from "effect/Struct";
import * as SqlClient from "effect/unstable/sql/SqlClient";
import * as SqlSchema from "effect/unstable/sql/SqlSchema";

import { toPersistenceSqlError, type ProjectionRepositoryError } from "./Errors.ts";

/**
 * Fork (#806): the server-side message queue's rows. One per message queued
 * on a thread; `orderKey` is a fractional key (`@t3tools/shared/orderKeys`)
 * and rows sort by plain string comparison of it.
 */
export const ProjectionThreadQueuedTurn = Schema.Struct({
  threadId: ThreadId,
  queueId: QueueId,
  messageId: MessageId,
  text: Schema.String,
  attachments: Schema.Array(ChatAttachment),
  modelSelection: Schema.NullOr(ModelSelection),
  context: Schema.NullOr(OrchestrationMessageContext),
  orderKey: TrimmedNonEmptyString,
  createdAt: IsoDateTime,
  updatedAt: IsoDateTime,
});
export type ProjectionThreadQueuedTurn = typeof ProjectionThreadQueuedTurn.Type;

export const ListProjectionThreadQueuedTurnsInput = Schema.Struct({
  threadId: ThreadId,
});
export type ListProjectionThreadQueuedTurnsInput = typeof ListProjectionThreadQueuedTurnsInput.Type;

export const DeleteProjectionThreadQueuedTurnInput = Schema.Struct({
  queueId: QueueId,
});
export type DeleteProjectionThreadQueuedTurnInput =
  typeof DeleteProjectionThreadQueuedTurnInput.Type;

export const DeleteProjectionThreadQueuedTurnsInput = Schema.Struct({
  threadId: ThreadId,
});
export type DeleteProjectionThreadQueuedTurnsInput =
  typeof DeleteProjectionThreadQueuedTurnsInput.Type;

/** The row as stored: JSON columns as strings. */
export const ProjectionThreadQueuedTurnDbRow = ProjectionThreadQueuedTurn.mapFields(
  Struct.assign({
    attachments: Schema.fromJsonString(Schema.Array(ChatAttachment)),
    modelSelection: Schema.NullOr(Schema.fromJsonString(ModelSelection)),
    context: Schema.NullOr(Schema.fromJsonString(OrchestrationMessageContext)),
  }),
);

export class ProjectionThreadQueuedTurnRepository extends Context.Service<
  ProjectionThreadQueuedTurnRepository,
  {
    /** Insert or replace by `queueId`. */
    readonly upsert: (
      row: ProjectionThreadQueuedTurn,
    ) => Effect.Effect<void, ProjectionRepositoryError>;
    /** A thread's rows in queue order. */
    readonly listByThreadId: (
      input: ListProjectionThreadQueuedTurnsInput,
    ) => Effect.Effect<ReadonlyArray<ProjectionThreadQueuedTurn>, ProjectionRepositoryError>;
    /** Every row, by thread then queue order (the drain's boot sweep). */
    readonly listAll: () => Effect.Effect<
      ReadonlyArray<ProjectionThreadQueuedTurn>,
      ProjectionRepositoryError
    >;
    readonly delete: (
      input: DeleteProjectionThreadQueuedTurnInput,
    ) => Effect.Effect<void, ProjectionRepositoryError>;
    readonly deleteByThreadId: (
      input: DeleteProjectionThreadQueuedTurnsInput,
    ) => Effect.Effect<void, ProjectionRepositoryError>;
  }
>()("t3/persistence/ProjectionThreadQueuedTurns/ProjectionThreadQueuedTurnRepository") {}

const make = Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  const upsertRow = SqlSchema.void({
    Request: ProjectionThreadQueuedTurn,
    execute: (row) => sql`
      INSERT INTO projection_thread_queued_turns (
        queue_id,
        thread_id,
        message_id,
        text,
        attachments_json,
        model_selection_json,
        context_json,
        order_key,
        created_at,
        updated_at
      )
      VALUES (
        ${row.queueId},
        ${row.threadId},
        ${row.messageId},
        ${row.text},
        ${JSON.stringify(row.attachments)},
        ${row.modelSelection === null ? null : JSON.stringify(row.modelSelection)},
        ${row.context === null ? null : JSON.stringify(row.context)},
        ${row.orderKey},
        ${row.createdAt},
        ${row.updatedAt}
      )
      ON CONFLICT (queue_id)
      DO UPDATE SET
        thread_id = excluded.thread_id,
        message_id = excluded.message_id,
        text = excluded.text,
        attachments_json = excluded.attachments_json,
        model_selection_json = excluded.model_selection_json,
        context_json = excluded.context_json,
        order_key = excluded.order_key,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at
    `,
  });

  const listRowsByThread = SqlSchema.findAll({
    Request: ListProjectionThreadQueuedTurnsInput,
    Result: ProjectionThreadQueuedTurnDbRow,
    execute: ({ threadId }) => sql`
      SELECT
        thread_id AS "threadId",
        queue_id AS "queueId",
        message_id AS "messageId",
        text,
        attachments_json AS "attachments",
        model_selection_json AS "modelSelection",
        context_json AS "context",
        order_key AS "orderKey",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
      FROM projection_thread_queued_turns
      WHERE thread_id = ${threadId}
      ORDER BY order_key ASC, created_at ASC
    `,
  });

  const listAllRows = SqlSchema.findAll({
    Request: Schema.Void,
    Result: ProjectionThreadQueuedTurnDbRow,
    execute: () => sql`
      SELECT
        thread_id AS "threadId",
        queue_id AS "queueId",
        message_id AS "messageId",
        text,
        attachments_json AS "attachments",
        model_selection_json AS "modelSelection",
        context_json AS "context",
        order_key AS "orderKey",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
      FROM projection_thread_queued_turns
      ORDER BY thread_id ASC, order_key ASC, created_at ASC
    `,
  });

  const deleteRow = SqlSchema.void({
    Request: DeleteProjectionThreadQueuedTurnInput,
    execute: ({ queueId }) => sql`
      DELETE FROM projection_thread_queued_turns
      WHERE queue_id = ${queueId}
    `,
  });

  const deleteRowsByThread = SqlSchema.void({
    Request: DeleteProjectionThreadQueuedTurnsInput,
    execute: ({ threadId }) => sql`
      DELETE FROM projection_thread_queued_turns
      WHERE thread_id = ${threadId}
    `,
  });

  const upsert: ProjectionThreadQueuedTurnRepository["Service"]["upsert"] = (row) =>
    upsertRow(row).pipe(
      Effect.mapError(toPersistenceSqlError("ProjectionThreadQueuedTurnRepository.upsert:query")),
    );
  const listByThreadId: ProjectionThreadQueuedTurnRepository["Service"]["listByThreadId"] = (
    input,
  ) =>
    listRowsByThread(input).pipe(
      Effect.mapError(
        toPersistenceSqlError("ProjectionThreadQueuedTurnRepository.listByThreadId:query"),
      ),
    );
  const listAll: ProjectionThreadQueuedTurnRepository["Service"]["listAll"] = () =>
    listAllRows(undefined).pipe(
      Effect.mapError(toPersistenceSqlError("ProjectionThreadQueuedTurnRepository.listAll:query")),
    );
  const deleteOne: ProjectionThreadQueuedTurnRepository["Service"]["delete"] = (input) =>
    deleteRow(input).pipe(
      Effect.mapError(toPersistenceSqlError("ProjectionThreadQueuedTurnRepository.delete:query")),
    );
  const deleteByThreadId: ProjectionThreadQueuedTurnRepository["Service"]["deleteByThreadId"] = (
    input,
  ) =>
    deleteRowsByThread(input).pipe(
      Effect.mapError(
        toPersistenceSqlError("ProjectionThreadQueuedTurnRepository.deleteByThreadId:query"),
      ),
    );

  return {
    upsert,
    listByThreadId,
    listAll,
    delete: deleteOne,
    deleteByThreadId,
  } satisfies ProjectionThreadQueuedTurnRepository["Service"];
});

export const layer = Layer.effect(ProjectionThreadQueuedTurnRepository, make);
