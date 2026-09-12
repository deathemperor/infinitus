import {
  QUEUED_TURN_GONE,
  QueueId,
  type OrchestrationQueuedTurn,
  type ThreadId,
} from "@t3tools/contracts";
import { orderKeyBetween } from "@t3tools/shared/orderKeys";
import * as Schema from "effect/Schema";

import { OrchestrationCommandInvariantError } from "../../orchestration/Errors.ts";

/**
 * The server-side message queue's drain (#806): the pure half. A thread's
 * queued rows are sent one at a time, oldest key first, and only while the
 * thread is idle by every gate the client drain used: no turn running or
 * starting, no turn start pending in the projection, not held by session
 * priority mode (#616), not paused by interrupt mode (#743), and no send of
 * ours still in flight. A session in `error` is never drained: a queue that
 * keeps sending into a broken session is the failure #832 (retry after a
 * transport failure) owns, and the next manual send clears the state.
 *
 * Two failures of the send itself: a row the decider refused is skipped by
 * its signature (`queuedTurnSignature`) until it is edited, moved or
 * removed, so the queue blocks behind it instead of retrying on every
 * event; a row the provider failed to start after the send consumed it is
 * put back once, at the head, under `retryQueueId` — the marker that stops
 * a second round.
 */

/** The thread fields the verdict reads; a shell or a detail both fit. */
export interface QueueDrainThread {
  readonly id: ThreadId;
  readonly archivedAt: string | null;
  readonly session: {
    readonly status: string;
    readonly activeTurnId: string | null;
  } | null;
  readonly queuedTurns?: ReadonlyArray<OrchestrationQueuedTurn> | undefined;
}

export type QueueWaitReason =
  | "empty"
  | "archived"
  | "in-flight"
  | "failed"
  | "held"
  | "paused"
  | "busy"
  | "pending-start"
  | "error";

export type QueueDrainVerdict =
  | { readonly kind: "send"; readonly row: OrchestrationQueuedTurn }
  | { readonly kind: "wait"; readonly reason: QueueWaitReason };

/** Session statuses under which nothing is running and a send may go. */
const IDLE_SESSION_STATUSES: ReadonlySet<string> = new Set([
  "idle",
  "ready",
  "stopped",
  "interrupted",
]);

/** The rows in queue order: by key, then by age for equal keys. */
export function orderedQueuedTurns(
  rows: ReadonlyArray<OrchestrationQueuedTurn> | undefined,
): ReadonlyArray<OrchestrationQueuedTurn> {
  return [...(rows ?? [])].sort(
    (left, right) =>
      left.orderKey.localeCompare(right.orderKey) ||
      left.createdAt.localeCompare(right.createdAt) ||
      left.queueId.localeCompare(right.queueId),
  );
}

/** What a refused row is remembered by: an edit or a move bumps
    `updatedAt`, a removal drops the id, and either makes it a new row. */
export function queuedTurnSignature(
  threadId: ThreadId,
  row: Pick<OrchestrationQueuedTurn, "queueId" | "updatedAt">,
): string {
  return `${threadId}\n${row.queueId}\n${row.updatedAt}`;
}

export function queueDrainVerdict(
  thread: QueueDrainThread,
  gates: {
    readonly held: boolean;
    readonly paused: boolean;
    readonly inFlight: boolean;
    /** A start requested and not yet running (the reactor is starting the
        session, or holding the start through compaction): upstream's
        `threadHasQueuedTurnStart` reading of the shell. */
    readonly pendingStart: boolean;
    /** Signatures (`queuedTurnSignature`) of rows the decider refused. */
    readonly failed?: ReadonlySet<string> | undefined;
  },
): QueueDrainVerdict {
  const row = orderedQueuedTurns(thread.queuedTurns)[0];
  if (row === undefined) return { kind: "wait", reason: "empty" };
  if (thread.archivedAt !== null) return { kind: "wait", reason: "archived" };
  if (gates.inFlight) return { kind: "wait", reason: "in-flight" };
  if (gates.failed?.has(queuedTurnSignature(thread.id, row)) === true) {
    return { kind: "wait", reason: "failed" };
  }
  if (gates.held) return { kind: "wait", reason: "held" };
  if (gates.paused) return { kind: "wait", reason: "paused" };
  const session = thread.session;
  if (session !== null) {
    if (session.status === "error") return { kind: "wait", reason: "error" };
    if (session.activeTurnId !== null || !IDLE_SESSION_STATUSES.has(session.status)) {
      return { kind: "wait", reason: "busy" };
    }
  }
  if (gates.pendingStart) return { kind: "wait", reason: "pending-start" };
  return { kind: "send", row };
}

/** Threads in `before` that are not in `after`: the ones a hold or pause
    just let go, which the drain looks at again. */
export function releasedThreads(
  before: ReadonlySet<ThreadId>,
  after: ReadonlySet<ThreadId>,
): ReadonlyArray<ThreadId> {
  return [...before].filter((threadId) => !after.has(threadId));
}

/** Why a refused send is shown, or null for the one refusal that is not a
    failure: the row was already sent or removed by someone else. */
const isInvariantError = Schema.is(OrchestrationCommandInvariantError);

export function queueSendRefusal(error: unknown): string | null {
  if (isInvariantError(error)) {
    return error.detail.includes(QUEUED_TURN_GONE) ? null : error.detail;
  }
  return error instanceof Error ? error.message : String(error);
}

const RETRY_SUFFIX = "~retry";

/** The id a row put back after a provider failure gets; one that carries
    it is never put back again. */
export function retryQueueId(queueId: QueueId): QueueId {
  return QueueId.make(`${queueId}${RETRY_SUFFIX}`);
}

export function isRetryQueueId(queueId: QueueId): boolean {
  return queueId.endsWith(RETRY_SUFFIX);
}

/** A key ahead of every row, or undefined to let the decider append when
    the head key is corrupt. */
export function queueHeadOrderKey(
  rows: ReadonlyArray<OrchestrationQueuedTurn> | undefined,
): string | undefined {
  return orderKeyBetween(null, orderedQueuedTurns(rows)[0]?.orderKey ?? null) ?? undefined;
}
