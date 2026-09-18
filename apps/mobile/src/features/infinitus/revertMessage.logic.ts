import type {
  MessageId,
  OrchestrationCheckpointSummary,
  OrchestrationMessageContext,
  OrchestrationThread,
} from "@infinitus/contracts";

import { reidentifyComposerContext, uploadedComposerContext } from "../../lib/composerContext";

/**
 * Fork (#269 item 13, #270 item 5): which checkpoint a message the user sent
 * reverts to — the web's `buildRevertTurnCountByUserMessageId`
 * (`MessagesTimeline.logic.ts`), kept local so neither app edits the other's
 * file. For each user message, the first assistant message after it that a
 * checkpoint names (`assistantMessageId`) gives the turn the message started;
 * the checkpoint BEFORE that turn is the state the message was sent into, so
 * the value is `checkpointTurnCount - 1` (never below 0). The walk stops at
 * the next user message. Checkpoints are taken whatever their status, as the
 * web does, so both surfaces name the same turn.
 */
export function revertTurnCountByUserMessageId(
  thread: Pick<OrchestrationThread, "messages"> & {
    readonly checkpoints: ReadonlyArray<
      Pick<OrchestrationCheckpointSummary, "checkpointTurnCount" | "assistantMessageId">
    >;
  },
): ReadonlyMap<MessageId, number> {
  const turnCountByAssistantMessageId = new Map<MessageId, number>();
  for (const checkpoint of thread.checkpoints) {
    if (checkpoint.assistantMessageId !== null) {
      turnCountByAssistantMessageId.set(
        checkpoint.assistantMessageId,
        checkpoint.checkpointTurnCount,
      );
    }
  }
  const byUserMessageId = new Map<MessageId, number>();
  const messages = thread.messages;
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index];
    if (message === undefined || message.role !== "user") continue;
    for (let nextIndex = index + 1; nextIndex < messages.length; nextIndex += 1) {
      const next = messages[nextIndex];
      if (next === undefined) continue;
      if (next.role === "user") break;
      const turnCount = turnCountByAssistantMessageId.get(next.id);
      if (turnCount === undefined) continue;
      byUserMessageId.set(message.id, Math.max(0, turnCount - 1));
      break;
    }
  }
  return byUserMessageId;
}

/** The web's wording (`ChatView.tsx`), so both surfaces ask the same thing. */
export const REVERT_WHILE_RUNNING = "Interrupt the current turn before reverting checkpoints.";

export function restoreFilesConfirmText(turnCount: number): string {
  return `Restore the files to checkpoint ${turnCount}? The chat stays as it is.`;
}

/** The two composer hand-back confirms, the web's lines: the first is the alert's title. */
export const REWIND_CHAT_CONFIRM = {
  title: "Rewind the chat to this message? Files stay as they are.",
  body: "Newer messages leave this thread; the workspace is untouched.\nYour prompt and attachments return to the composer.",
  button: "Rewind",
} as const;

export const EDIT_FROM_HERE_CONFIRM = {
  title: "Edit from here?",
  body: "Rewind files and chat to before this message.\nYour prompt and attachments return to the composer.",
  button: "Edit",
} as const;

export type RevertMenuAction = "files" | "restore-files" | "chat" | "fork";

/**
 * The menu's rows in the web's order: the two rollback modes need the
 * provider's rollback, the fork a fork point, and the two file modes an
 * isolated worktree (the server refuses to restore files into a shared
 * project directory, upstream #12306, as the web's menu hides them).
 */
export function revertMenuActions(gates: {
  readonly canRollback: boolean;
  readonly canRestoreFiles: boolean;
  readonly canFork: boolean;
}): ReadonlyArray<RevertMenuAction> {
  return [
    ...(gates.canRollback && gates.canRestoreFiles ? (["files"] as const) : []),
    ...(gates.canRestoreFiles ? (["restore-files"] as const) : []),
    ...(gates.canRollback ? (["chat"] as const) : []),
    ...(gates.canFork ? (["fork"] as const) : []),
  ];
}

const EFFORT_PREFIX = "Ultrathink:\n";
const REVIEW_COMMENT_BLOCK_PATTERN = /<review_comment\b[^>]*>[\s\S]*?<\/review_comment>/g;

/**
 * A reverted message's text as the user typed it, the web's
 * `recallableComposerPrompt` for what the phone sends: the effort prefix the
 * send added and the review comments appended after the text come off, so
 * the composer does not get another turn's context back as markup. Cuts at
 * the start of the trailing run of blocks, so a block typed earlier stays.
 */
export function revertedMessageEditableText(text: string): string {
  let prompt = text.trim();
  if (prompt.startsWith(EFFORT_PREFIX)) prompt = prompt.slice(EFFORT_PREFIX.length);
  let cut = prompt.length;
  for (const match of [...prompt.matchAll(REVIEW_COMMENT_BLOCK_PATTERN)].reverse()) {
    const blockEnd = match.index + match[0].length;
    if (prompt.slice(blockEnd, cut).trim().length > 0) break;
    cut = match.index;
  }
  return prompt.slice(0, cut).trim();
}

/**
 * The reverted message's text and context records for the composer, the
 * queue's `restoredQueuedTurn` (#971) for a message: fresh record ids with the
 * text's references rewritten, and a file or image record following its
 * attachment to the id the download gave it. Null for a message without
 * context, which stays a plain text append.
 */
export function restoredRevertedMessage(
  message: Pick<OrchestrationThread["messages"][number], "text" | "attachments" | "context">,
  attachments: ReadonlyArray<{ readonly id: string }>,
  createId: () => string,
): { text: string; context: OrchestrationMessageContext } | null {
  if (!message.context) return null;
  const fresh = reidentifyComposerContext(
    revertedMessageEditableText(message.text),
    message.context.records,
    createId,
  );
  const context = uploadedComposerContext(fresh.context, message.attachments ?? [], attachments);
  return context ? { text: fresh.text, context } : null;
}
