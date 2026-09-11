import type { ThreadId } from "@t3tools/contracts";

/**
 * Fork (#269 C): whether a message of a side thread was asked or answered
 * here. The fork seeds the thread with the main thread's history through
 * `thread.history.import`, whose messages carry the ids the fork minted
 * (`<threadId>:000000`, `:000001`, …); a question sent from the drawer gets
 * a fresh random id, and its answer streams in under a turn. `turnId` does
 * not separate the two: a user message has none either way.
 */
export function isSideQuestionMessage(
  threadId: ThreadId,
  message: { readonly id: string; readonly role: string; readonly text: string },
): boolean {
  return (
    !message.id.startsWith(`${threadId}:`) &&
    (message.role === "user" || message.role === "assistant") &&
    message.text.trim().length > 0
  );
}
