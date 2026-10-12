import { CommandId, ThreadId, ThreadUsageRollup } from "@infinitus/contracts";
import { makeDrainableWorker } from "@infinitus/shared/DrainableWorker";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import * as SqlClient from "effect/sql/SqlClient";

import * as Orchestrator from "../../orchestration-v2/Orchestrator.ts";
import { forkParked } from "../../serverActivation.ts";
import { UsageService } from "../../usage/UsageService.ts";
import {
  baselineForCandidate,
  wantsTranscript,
  type ThreadUsageBackfillCandidate,
} from "../threadUsageBackfill.logic.ts";

type Input = { readonly kind: "sweep" } | { readonly kind: "thread"; readonly threadId: ThreadId };

/** One boot's worth; a server with more legacy threads gets the rest next boot. */
const SWEEP_LIMIT = 500;

const decodeRollup = Schema.decodeUnknownOption(Schema.fromJsonString(ThreadUsageRollup));

interface CandidateRow {
  readonly thread_id: string;
  readonly v1_usage_json: string | null;
  readonly claude_session_id: string | null;
  readonly turns: number;
  readonly last_turn_at: string | null;
  readonly recorded_usage: number;
}

/**
 * Threads the backfill may give a baseline (#834): not deleted, no baseline
 * yet, no run pending or running (a turn mid-flight would be read half-way
 * and then recorded on top), and either a v1 rollup the import left in the
 * fork's `projection_threads.usage_json` (the thread ids survive the
 * import unchanged) or a root Claude session to read the transcript of —
 * the provider thread's native ref, else the v1 session binding's resume
 * cursor. `turns` counts the completed runs; `last_turn_at` is the newest
 * mark on any run, whatever its state, for the caller to tell a legacy
 * thread from one whose turns this server already records; `recorded_usage`
 * says whether any provider turn already carries usage.
 */
export const listThreadUsageBackfillCandidates = Effect.fn(
  "ThreadUsageBackfill.listCandidates",
)(function* (input: { readonly threadId?: ThreadId; readonly limit: number }) {
  const sql = yield* SqlClient.SqlClient;
  const rows = yield* sql<CandidateRow>`
    SELECT
      t.thread_id,
      v1.usage_json AS v1_usage_json,
      COALESCE(
        (
          SELECT json_extract(pt.payload_json, '$.nativeThreadRef.nativeId')
          FROM orchestration_v2_projection_provider_threads pt
          WHERE pt.thread_id = t.thread_id
            AND pt.owner_node_id IS NULL
            AND pt.provider = 'claudeAgent'
            AND json_type(pt.payload_json, '$.nativeThreadRef.nativeId') = 'text'
          ORDER BY pt.updated_at DESC
          LIMIT 1
        ),
        (
          SELECT json_extract(runtime.resume_cursor_json, '$.resume')
          FROM provider_session_runtime runtime
          WHERE runtime.thread_id = t.thread_id
            AND runtime.provider_name = 'claudeAgent'
            AND json_type(runtime.resume_cursor_json, '$.resume') = 'text'
        )
      ) AS claude_session_id,
      (
        SELECT COUNT(*) FROM orchestration_v2_projection_runs r
        WHERE r.thread_id = t.thread_id AND r.status = 'completed'
      ) AS turns,
      (
        SELECT MAX(COALESCE(r.completed_at, json_extract(r.payload_json, '$.startedAt'), r.requested_at))
        FROM orchestration_v2_projection_runs r
        WHERE r.thread_id = t.thread_id
      ) AS last_turn_at,
      EXISTS (
        SELECT 1 FROM orchestration_v2_projection_provider_turns pturn
        WHERE pturn.thread_id = t.thread_id
          AND json_type(pturn.payload_json, '$.turnTokenUsage') = 'object'
      ) AS recorded_usage
    FROM orchestration_v2_projection_threads t
    LEFT JOIN projection_threads v1 ON v1.thread_id = t.thread_id
    WHERE t.deleted_at IS NULL
      AND json_type(t.payload_json, '$.usageBaseline') IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM orchestration_v2_projection_runs live
        WHERE live.thread_id = t.thread_id
          AND live.status IN ('preparing', 'queued', 'starting', 'running', 'waiting')
      )
      ${input.threadId === undefined ? sql`` : sql`AND t.thread_id = ${input.threadId}`}
    ORDER BY t.updated_at DESC
    LIMIT ${input.limit}
  `;
  const candidates: ThreadUsageBackfillCandidate[] = [];
  for (const row of rows) {
    const v1Usage =
      row.v1_usage_json === null
        ? undefined
        : Option.getOrUndefined(decodeRollup(row.v1_usage_json));
    const claudeSessionId = row.claude_session_id;
    if (v1Usage === undefined && claudeSessionId === null) continue;
    candidates.push({
      threadId: ThreadId.make(row.thread_id),
      v1Usage: v1Usage ?? null,
      claudeSessionId,
      turns: Number(row.turns),
      lastTurnAt: row.last_turn_at,
      recordedUsage: Number(row.recorded_usage) === 1,
    });
  }
  return candidates;
});

/**
 * Fork (#834): the usage backfill, on orchestrator v2 (#1627). Threads whose
 * turns ran before this server recorded usage get one baseline on their app
 * thread, through `thread.metadata.update`'s `usageBaseline`, which the
 * client fold adds the recorded turns to: the v1 rollup the import left
 * (exact, its own source) or, for a legacy Claude thread, the transcript's
 * total. A boot sweep (parked until activation) covers the backlog; a v1
 * import landing later (`thread.created` with `historyOrigin: "v1_import"`)
 * re-checks that one thread. Codex is not estimated.
 *
 * A thread is attempted at most once per process: a session with no
 * transcript is not re-read on every trigger. Only thread ids and counts
 * are logged.
 */
export const ThreadUsageBackfillLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrator = yield* Orchestrator.OrchestratorV2;
    const usageService = yield* UsageService;
    const sql = yield* SqlClient.SqlClient;
    const crypto = yield* Crypto.Crypto;
    const bootAt = DateTime.formatIso(yield* DateTime.now);
    const attempted = new Set<ThreadId>();

    const backfill = Effect.fn("ThreadUsageBackfill.backfill")(function* (
      candidates: ReadonlyArray<ThreadUsageBackfillCandidate>,
    ) {
      const fresh = candidates.filter((candidate) => !attempted.has(candidate.threadId));
      if (fresh.length === 0) return;
      const sessionIds = fresh
        .filter((candidate) => wantsTranscript(candidate, bootAt))
        .flatMap((candidate) => (candidate.claudeSessionId === null ? [] : [candidate.claudeSessionId]));
      const sessions =
        sessionIds.length === 0
          ? new Map<string, never>()
          : yield* usageService.readSessionUsage({ sessionIds });
      // Marked after the read, so a failed read (the settings file, the
      // transcript directory) leaves the batch for the next trigger.
      for (const candidate of fresh) attempted.add(candidate.threadId);
      let backfilled = 0;
      for (const candidate of fresh) {
        const usageBaseline = baselineForCandidate(candidate, sessions, bootAt);
        if (usageBaseline === undefined) continue;
        const uuid = yield* crypto.randomUUIDv4;
        yield* orchestrator
          .dispatch({
            type: "thread.metadata.update",
            commandId: CommandId.make(`server:usage-backfill:${uuid}`),
            threadId: candidate.threadId,
            usageBaseline,
          })
          .pipe(
            Effect.map(() => {
              backfilled += 1;
            }),
            Effect.catchCause((cause) =>
              Effect.logWarning("thread.usage-backfill.refused", {
                threadId: candidate.threadId,
                cause: Cause.pretty(cause),
              }),
            ),
          );
      }
      yield* Effect.logInfo("thread.usage-backfill.done", {
        candidates: fresh.length,
        backfilled,
      });
    });

    const onInput = (input: Input) =>
      (input.kind === "sweep"
        ? listThreadUsageBackfillCandidates({ limit: SWEEP_LIMIT }).pipe(
            Effect.tap((candidates) =>
              candidates.length === SWEEP_LIMIT
                ? Effect.logInfo("thread.usage-backfill.sweep-capped", { limit: SWEEP_LIMIT })
                : Effect.void,
            ),
          )
        : attempted.has(input.threadId)
          ? Effect.succeed([])
          : listThreadUsageBackfillCandidates({ threadId: input.threadId, limit: 1 })
      ).pipe(
        Effect.flatMap(backfill),
        Effect.provideService(SqlClient.SqlClient, sql),
      );

    const worker = yield* makeDrainableWorker((input: Input) =>
      onInput(input).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("thread.usage-backfill.input-failed", {
            kind: input.kind,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      orchestrator.streamDomainEvents.pipe(
        Stream.runForEach((event) =>
          event.type === "thread.created" && event.payload.historyOrigin === "v1_import"
            ? worker.enqueue({ kind: "thread", threadId: event.payload.id })
            : Effect.void,
        ),
        Effect.catchCause((cause) =>
          Effect.logWarning("thread.usage-backfill.stream-ended", {
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );
    // Parked like the stream: the projection is complete once the server
    // has activated, and the sweep is what a restart works through.
    yield* forkParked(worker.enqueue({ kind: "sweep" }));
  }),
);
