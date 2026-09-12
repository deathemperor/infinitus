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

/**
 * Whether the drawer's side thread is gone (deleted from the sidebar, or
 * while the app was closed). Only once the environment's shell index is
 * bootstrapped is a missing shell authoritative, and only once the drawer
 * has either seen the thread or waited out `SIDE_QUESTION_GONE_GRACE_MS`:
 * the fork's reply can land before the created thread's shell does.
 */
export function isSideQuestionGone(input: {
  readonly hasThread: boolean;
  readonly bootstrapped: boolean;
  readonly settled: boolean;
}): boolean {
  return !input.hasThread && input.bootstrapped && input.settled;
}

export const SIDE_QUESTION_GONE_GRACE_MS = 3000;

/** The main composer's draft with the answer brought over, for a composer
    that cannot take a caret insert (not mounted, connecting, answering an
    approval): appended after a blank line, or the answer alone. */
export function appendAnswerToDraft(currentDraft: string, answer: string): string {
  return currentDraft.trim().length > 0 ? `${currentDraft.trimEnd()}\n\n${answer}` : answer;
}

/** What the drawer says when the side thread's turn failed, and the question to re-ask. */
export interface SideQuestionFailure {
  readonly text: string;
  readonly question: string;
}

const asText = (value: unknown): string | null =>
  typeof value === "string" && value.trim().length > 0 ? value.trim() : null;

/**
 * Fork (#269 C follow-up): why the latest side question got no answer, the
 * way the main timeline would say it — the turn's error activity after the
 * question (`runtime.error`'s message, a `*.failed` row's detail, else its
 * summary), or the session's error state with its `lastError`. Null while
 * a turn runs, before anything was asked here, or once an answer landed
 * after the failure.
 */
export function sideQuestionFailure(
  threadId: ThreadId,
  thread: {
    readonly messages: ReadonlyArray<{
      readonly id: string;
      readonly role: string;
      readonly text: string;
      readonly streaming: boolean;
      readonly createdAt: string;
    }>;
    readonly activities: ReadonlyArray<{
      readonly tone: string;
      readonly summary: string;
      readonly payload: unknown;
      readonly createdAt: string;
    }>;
    readonly session: {
      readonly status: string;
      readonly activeTurnId: TurnId | null;
      readonly lastError: string | null;
    } | null;
  },
): SideQuestionFailure | null {
  if ((thread.session?.activeTurnId ?? null) !== null) return null;
  const asked = thread.messages.filter((message) => isSideQuestionMessage(threadId, message));
  const question = asked.findLast((message) => message.role === "user");
  if (!question) return null;
  const answeredAfter = (at: string) =>
    asked.some(
      (message) => message.role === "assistant" && !message.streaming && message.createdAt >= at,
    );
  const failed = thread.activities.findLast(
    (activity) => activity.tone === "error" && activity.createdAt >= question.createdAt,
  );
  if (failed) {
    if (answeredAfter(failed.createdAt)) return null;
    const payload =
      typeof failed.payload === "object" && failed.payload !== null
        ? (failed.payload as { readonly message?: unknown; readonly detail?: unknown })
        : null;
    return {
      text: asText(payload?.message) ?? asText(payload?.detail) ?? failed.summary,
      question: question.text,
    };
  }
  if (thread.session?.status === "error" && !answeredAfter(question.createdAt)) {
    return {
      text: thread.session.lastError ?? "The side question failed.",
      question: question.text,
    };
  }
  return null;
}
