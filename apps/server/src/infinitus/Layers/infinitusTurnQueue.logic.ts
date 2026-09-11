import type { OrchestrationQueuedTurn, ThreadId } from "@t3tools/contracts";

/**
 * The server-side message queue's drain (#806): the pure half. A thread's
 * queued rows are sent one at a time, oldest key first, and only while the
 * thread is idle by every gate the client drain used: no turn running or
 * starting, no turn start pending in the projection, not held by session
 * priority mode (#616), not paused by interrupt mode (#743), and no send of
 * ours still in flight. A session in `error` is never drained: a queue that
 * keeps sending into a broken session is the failure #832 (retry after a
 * transport failure) owns, and the next manual send clears the state.
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
  },
): QueueDrainVerdict {
  const row = orderedQueuedTurns(thread.queuedTurns)[0];
  if (row === undefined) return { kind: "wait", reason: "empty" };
  if (thread.archivedAt !== null) return { kind: "wait", reason: "archived" };
  if (gates.inFlight) return { kind: "wait", reason: "in-flight" };
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
