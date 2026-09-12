import type { ThreadId, TurnId } from "@t3tools/contracts";

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

/**
 * Fork (#269 C): whether the thread has a turn a side question can fork
 * from. The server forks at the session's latest completed turn; here the
 * proxy is an assistant message that finished under a turn other than the
 * one running. Imported history (no turn) does not count.
 */
export function hasCompletedTurn(thread: {
  readonly messages: ReadonlyArray<{
    readonly role: string;
    readonly turnId: TurnId | null;
    readonly streaming: boolean;
  }>;
  readonly session: { readonly activeTurnId: TurnId | null } | null;
}): boolean {
  const activeTurnId = thread.session?.activeTurnId ?? null;
  return thread.messages.some(
    (message) =>
      message.role === "assistant" &&
      !message.streaming &&
      message.turnId !== null &&
      message.turnId !== activeTurnId,
  );
}

/** The reason the Aside button is off, or null when a side question can be asked. */
export const SIDE_QUESTION_NEEDS_TURN = "Ask a side question once a turn has completed.";
