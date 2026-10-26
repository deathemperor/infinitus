import { reclaimQueuedMessageFromDispatch } from "./queued-message-dispatch";
import type { QueuedThreadMessage } from "./thread-outbox-model";
import { removeThreadOutboxMessage } from "./thread-outbox-removal";
import { holdEditingQueuedMessage, releaseEditingQueuedMessage } from "./use-thread-outbox";

/**
 * Deletes a queued reply from under its bubble (#1501). An upload in flight is aborted
 * first; false once the send is in flight. The hold is taken before the abort and any
 * await, as an edit does, so the released drain does not find the row still at the head.
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
