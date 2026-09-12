import type {
  OrchestrationMessageContext,
  OrchestrationQueuedTurn,
  QueueId,
} from "@t3tools/contracts";
import { orderKeyBetween } from "@t3tools/shared/orderKeys";

import { reidentifyComposerContext, uploadedComposerContext } from "../../lib/composerContext";

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

/**
 * The row's text and context records for the composer, when the row carries
 * any (#971): the records get fresh ids (a queued copy must never overwrite a
 * record the draft already holds) with the text's references rewritten to
 * match, and a file or image record follows its attachment to the new id the
 * download gave it — `attachments` is one entry per `row.attachments`, in
 * order. Null for a row without context, which stays a plain text append.
 */
export function restoredQueuedTurn(
  row: OrchestrationQueuedTurn,
  attachments: ReadonlyArray<{ readonly id: string }>,
  createId: () => string,
): { text: string; context: OrchestrationMessageContext } | null {
  if (!row.context) return null;
  const fresh = reidentifyComposerContext(
    queuedTurnEditableText(row.text),
    row.context.records,
    createId,
  );
  const context = uploadedComposerContext(fresh.context, row.attachments, attachments);
  return context ? { text: fresh.text, context } : null;
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
