import type {
  MessageId,
  OrchestrationCheckpointSummary,
  OrchestrationThread,
} from "@t3tools/contracts";

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
