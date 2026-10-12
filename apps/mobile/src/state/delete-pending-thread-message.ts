import { reclaimQueuedMessageFromDispatch } from "./queued-message-dispatch";
import type { QueuedThreadMessage } from "./thread-outbox-model";
import { removeThreadOutboxMessage } from "./thread-outbox-removal";
import { holdEditingQueuedMessage, releaseEditingQueuedMessage } from "./use-thread-outbox";

/**
 * Deletes a queued reply from under its bubble (#1501). An upload in flight
 * is aborted first; false once the send itself is in flight, when the turn
 * may already be the server's. The drain removes its own delivered rows
 * through `removeThreadOutboxMessage` directly, so the guard lives here.
 *
 * The hold is taken before the abort and before any await, the same way an
 * edit takes it: the aborted attempt releases the drain, whose next pass
 * would otherwise find the row still at the head of the queue while its
 * removal is in flight. A held id is skipped there.
 */
export async function deletePendingThreadMessage(message: QueuedThreadMessage): Promise<boolean> {
  holdEditingQueuedMessage(message.messageId);
  try {
    if (!reclaimQueuedMessageFromDispatch(message.messageId)) {
      return false;
    }
    // A row that left the queue meanwhile (delivered, or removed elsewhere) is
    // exactly what the user asked for.
    await removeThreadOutboxMessage(message);
    return true;
  } finally {
    releaseEditingQueuedMessage(message.messageId);
  }
}
