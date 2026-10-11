import { reclaimQueuedMessageFromDispatch } from "./queued-message-dispatch";
import type { QueuedThreadMessage } from "./thread-outbox-model";
import { removeThreadOutboxMessage } from "./thread-outbox-removal";

/**
 * Deletes a queued reply from under its bubble (#1501). An upload in flight
 * is aborted first; false once the send itself is in flight, when the turn
 * may already be the server's. The drain removes its own delivered rows
 * through `removeThreadOutboxMessage` directly, so the guard lives here.
 */
export async function deletePendingThreadMessage(message: QueuedThreadMessage): Promise<boolean> {
  if (!reclaimQueuedMessageFromDispatch(message.messageId)) {
    return false;
  }
  // A row that left the queue meanwhile (delivered, or removed elsewhere) is
  // exactly what the user asked for.
  await removeThreadOutboxMessage(message);
  return true;
}
