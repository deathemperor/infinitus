import type { ThreadId, TurnId } from "@t3tools/contracts";

/**
 * Fork (#269 C, #863): a thread with `sideOf` set is a hidden side question
 * of another thread. The web shows it in that thread's drawer; the phone has
 * no drawer, so it stays out of every list and never opens as a page.
 */
export function isSideQuestion(thread: { readonly sideOf?: ThreadId | null }): boolean {
  return thread.sideOf != null;
}

/** The threads that are not side questions; the same array when none are. */
export function withoutSideQuestions<T extends { readonly sideOf?: ThreadId | null }>(
  threads: ReadonlyArray<T>,
): ReadonlyArray<T> {
  return threads.some(isSideQuestion)
    ? threads.filter((thread) => !isSideQuestion(thread))
    : threads;
}

/** Archived snapshots with their side questions dropped; each entry is kept
    as is when it has none. */
export function withoutSideQuestionSnapshots<
  T extends {
    readonly snapshot: { readonly threads: ReadonlyArray<{ readonly sideOf?: ThreadId | null }> };
  },
>(entries: ReadonlyArray<T>): ReadonlyArray<T> {
  return entries.map((entry) => {
    const threads = withoutSideQuestions(entry.snapshot.threads);
    return threads === entry.snapshot.threads
      ? entry
      : { ...entry, snapshot: { ...entry.snapshot, threads } };
  });
}

/**
 * Fork (#269 C, #881): whether a message of a side thread was asked or
 * answered there. The fork seeds the thread with the main thread's history
 * through `thread.history.import`, whose messages carry the ids the fork
 * minted (`<threadId>:000000`, `:000001`, …); a question asked from the
 * sheet gets a fresh random id, and its answer streams in under a turn.
 * The web's `SideQuestionPanel.logic.ts`, kept local so neither app edits
 * the other's file.
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
 * Whether the thread has a turn a side question can fork from. The server
 * forks at the session's latest completed turn; here the proxy is an
 * assistant message that finished under a turn other than the one running.
 * Imported history (no turn) does not count.
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

/** Why the side question cannot be asked yet; the web's wording. */
export const SIDE_QUESTION_NEEDS_TURN = "Ask a side question once a turn has completed.";

/** The latest finished answer among the side thread's own messages, or null. */
export function latestSideAnswer(
  messages: ReadonlyArray<{
    readonly role: string;
    readonly text: string;
    readonly streaming: boolean;
  }>,
): string | null {
  return (
    messages.findLast((message) => message.role === "assistant" && !message.streaming)?.text ?? null
  );
}

/** The main composer's draft with the answer brought over: appended after a
    blank line, or the answer alone when the draft is blank. */
export function bringToMainText(currentDraft: string, answer: string): string {
  return currentDraft.trim().length > 0 ? `${currentDraft.trimEnd()}\n\n${answer}` : answer;
}
