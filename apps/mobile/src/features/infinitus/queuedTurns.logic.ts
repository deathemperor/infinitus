import type { OrchestrationQueuedTurn, QueueId } from "@t3tools/contracts";
import { orderKeyBetween } from "@t3tools/shared/orderKeys";

/**
 * The phone's copy of the web's `composerSendQueue.logic.ts` (#806, #851):
 * the rows under the composer are the thread's server-side `queuedTurns`,
 * which start once the thread is idle whether or not this phone is still
 * open. Kept local so a mobile PR never edits the web's file; the two can be
 * lifted into `@t3tools/shared` together later.
 */

/** The thread's queued messages in send order. */
export function orderedQueuedTurns(
  rows: ReadonlyArray<OrchestrationQueuedTurn> | undefined,
): ReadonlyArray<OrchestrationQueuedTurn> {
  if (!rows || rows.length === 0) return [];
  return [...rows].sort((left, right) =>
    left.orderKey < right.orderKey ? -1 : left.orderKey > right.orderKey ? 1 : 0,
  );
}

/** The one line the send applied for "ultrathink" (`applyClaudePromptEffortPrefix`). */
const EFFORT_PREFIX = "Ultrathink:\n";

/** The row's text as the user typed it: the effort prefix the send added comes off. */
export function queuedTurnEditableText(text: string): string {
  return text.startsWith(EFFORT_PREFIX) ? text.slice(EFFORT_PREFIX.length) : text;
}

/** One line of the row for the list; attachments alone read as "N attachments". */
export function queuedTurnSnippet(row: OrchestrationQueuedTurn): string {
  const text = queuedTurnEditableText(row.text).trim().replace(/\s+/g, " ");
  if (text.length > 0) return text;
  const count = row.attachments.length;
  return count === 1 ? "1 attachment" : `${count} attachments`;
}

/**
 * The order key that moves a row one place earlier or later among the
 * thread's rows (already in send order), or null when it is at that end or
 * the neighbouring keys leave no room.
 */
export function queuedTurnMoveKey(
  rows: ReadonlyArray<OrchestrationQueuedTurn>,
  queueId: QueueId,
  direction: "earlier" | "later",
): string | null {
  const index = rows.findIndex((row) => row.queueId === queueId);
  if (index === -1) return null;
  if (direction === "earlier") {
    const before = rows[index - 1];
    if (!before) return null;
    return orderKeyBetween(rows[index - 2]?.orderKey ?? null, before.orderKey);
  }
  const after = rows[index + 1];
  if (!after) return null;
  return orderKeyBetween(after.orderKey, rows[index + 2]?.orderKey ?? null);
}

/** The card's header: what the queue is waiting on. */
export function queuedTurnsTitle(count: number, threadRunning: boolean): string {
  const noun = count === 1 ? "1 queued message" : `${count} queued messages`;
  return threadRunning ? `${noun} · sends when this turn finishes` : `${noun} · sending when idle`;
}
