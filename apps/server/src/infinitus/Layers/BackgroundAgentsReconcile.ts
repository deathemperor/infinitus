import { CommandId, EventId, ThreadId, TurnId } from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import * as SqlClient from "effect/unstable/sql/SqlClient";

import * as OrchestrationEngine from "../../orchestration/Services/OrchestrationEngine.ts";
import * as ProjectionSnapshotQuery from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import * as ProviderService from "../../provider/Services/ProviderService.ts";
import {
  BACKGROUND_AGENTS_MESSAGE_PREFIX,
  liveBackgroundAgentsMessage,
  orphanedBackgroundAgentRows,
  type OrphanedBackgroundAgent,
} from "../backgroundAgents.logic.ts";

/**
 * Boot-time reconcile of background subagents (#977, the killed-server half
 * of #974). A Claude session stopped gracefully writes stopped rows for its
 * live background agents and one error row naming them; a server killed
 * outright (the desktop quitting) writes nothing, and the thread reads
 * `ready` while the agent's work is gone. At startup, after the provider
 * session reconcile, this finds every thread whose session still reads
 * ready/running/starting and whose `task.started` rows of agent kind went
 * to the background and never ended, and writes the same rows plus the
 * session's error state — so the thread reads failed, the footer stops
 * counting, and a queued follow-up does not drain onto dead work (#832).
 *
 * The candidate set is one SQL statement over the sessions table with
 * correlated lookups on each thread's activity index, never a read of every
 * thread's activities (Infi4's bound on the boot path). Idempotence: the
 * stopped rows end the tasks, and a #974 error row written after the start
 * row excludes it as well.
 */

const CandidateRow = Schema.Struct({
  threadId: ThreadId,
  turnId: Schema.NullOr(TurnId),
  taskId: Schema.String,
  title: Schema.NullOr(Schema.String),
});
const decodeCandidates = Schema.decodeUnknownEffect(Schema.Array(CandidateRow));

export const reconcileBackgroundAgents = Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const crypto = yield* Crypto.Crypto;
  const engine = yield* OrchestrationEngine.OrchestrationEngineService;
  const providerService = yield* ProviderService.ProviderService;
  const query = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;

  const candidates = yield* sql`
    SELECT
      a.thread_id AS "threadId",
      a.turn_id AS "turnId",
      json_extract(a.payload_json, '$.taskId') AS "taskId",
      json_extract(a.payload_json, '$.title') AS "title"
    FROM projection_thread_sessions s
    JOIN projection_thread_activities a
      ON a.thread_id = s.thread_id AND a.kind = 'task.started'
    WHERE s.status IN ('ready', 'running', 'starting')
      AND (
        json_extract(a.payload_json, '$.agentKind') = 'agent'
        OR (
          json_extract(a.payload_json, '$.agentKind') IS NULL
          AND json_extract(a.payload_json, '$.taskType') = 'local_agent'
        )
      )
      AND (
        json_extract(a.payload_json, '$.isBackgrounded') = 1
        OR EXISTS (
          SELECT 1 FROM projection_thread_activities u
          WHERE u.thread_id = a.thread_id
            AND u.kind = 'task.updated'
            AND json_extract(u.payload_json, '$.taskId') = json_extract(a.payload_json, '$.taskId')
            AND json_extract(u.payload_json, '$.isBackgrounded') = 1
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM projection_thread_activities e
        WHERE e.thread_id = a.thread_id
          AND e.kind IN ('task.completed', 'task.updated')
          AND json_extract(e.payload_json, '$.taskId') = json_extract(a.payload_json, '$.taskId')
          AND (
            e.kind = 'task.completed'
            OR json_extract(e.payload_json, '$.endedAt') IS NOT NULL
            OR json_extract(e.payload_json, '$.status')
              IN ('completed', 'failed', 'cancelled', 'interrupted', 'stopped')
          )
      )
      AND NOT EXISTS (
        SELECT 1 FROM projection_thread_activities r
        WHERE r.thread_id = a.thread_id
          AND r.kind = 'runtime.error'
          AND r.created_at >= a.created_at
          AND json_extract(r.payload_json, '$.message') LIKE ${`${BACKGROUND_AGENTS_MESSAGE_PREFIX}%`}
      )
    ORDER BY a.thread_id, a.created_at, a.activity_id
  `.pipe(Effect.flatMap(decodeCandidates));
  if (candidates.length === 0) return;

  const liveThreadIds = new Set(
    (yield* providerService.listSessions()).map((session) => session.threadId),
  );
  const { threads } = yield* query.getCommandReadModel();
  const byThread = new Map<ThreadId, Array<OrphanedBackgroundAgent>>();
  for (const row of candidates) {
    if (liveThreadIds.has(row.threadId)) continue;
    const agents = byThread.get(row.threadId) ?? [];
    agents.push({ taskId: row.taskId, turnId: row.turnId, title: row.title });
    byThread.set(row.threadId, agents);
  }

  for (const [threadId, agents] of byThread) {
    const thread = threads.find((candidate) => candidate.id === threadId);
    const session = thread?.session;
    if (!thread || !session || thread.deletedAt !== null || thread.archivedAt !== null) continue;
    yield* Effect.gen(function* () {
      const createdAt = DateTime.formatIso(yield* DateTime.now);
      const ids = yield* Effect.forEach(agents.concat([agents[0]!]), () =>
        crypto.randomUUIDv4.pipe(Effect.map(EventId.make)),
      );
      for (const activity of orphanedBackgroundAgentRows({ threadId, agents, ids, createdAt })) {
        yield* engine.dispatch({
          type: "thread.activity.append",
          commandId: CommandId.make(yield* crypto.randomUUIDv4),
          threadId,
          activity,
          createdAt,
        });
      }
      yield* engine.dispatch({
        type: "thread.session.set",
        commandId: CommandId.make(yield* crypto.randomUUIDv4),
        threadId,
        session: {
          ...session,
          status: "error",
          activeTurnId: null,
          lastError: liveBackgroundAgentsMessage(agents.length),
          updatedAt: createdAt,
        },
        createdAt,
      });
      yield* Effect.logInfo("infinitus.background-agents.reconciled", {
        threadId,
        agents: agents.length,
      });
    }).pipe(
      Effect.catchCause((cause) =>
        Cause.hasInterrupts(cause)
          ? Effect.failCause(cause)
          : Effect.logWarning("infinitus.background-agents.reconcile-failed", { threadId, cause }),
      ),
    );
  }
}).pipe(
  Effect.catchCause((cause) =>
    Cause.hasInterrupts(cause)
      ? Effect.failCause(cause)
      : Effect.logWarning("infinitus.background-agents.reconcile-failed", { cause }),
  ),
);
