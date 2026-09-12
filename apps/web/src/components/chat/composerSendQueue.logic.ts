import {
  CommandId,
  EnvironmentId,
  MessageId,
  QueueId,
  ThreadId,
  type ChatFileAttachment,
  type OrchestrationQueuedTurn,
  type UploadChatImageAttachment,
} from "@t3tools/contracts";
import { pinOrderKeyBetween } from "@t3tools/client-runtime/state/thread-sort";
import { replaceComposerContextReferences } from "@t3tools/shared/composerContextReferences";

import { formatInlineContextReference } from "../../lib/composerContextReferences";

import type { PromptStashEntry } from "../../promptStashStore";

/**
 * Queue vs steer (#270 F, server-side since #806). A message sent while a
 * turn runs either goes now (steer: the provider folds it into the running
 * turn) or is queued on the server (`thread.turn.queue`), which starts it
 * once the thread is idle — whether or not this client is still open. The
 * rows under the composer are the thread's `queuedTurns`.
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
 * The row's text for the composer once its records were imported (#971): the
 * effort prefix comes off and every context link whose record was re-minted
 * under a fresh id points at that id (an `element` record comes back as a
 * preview annotation, as on a stash restore); a link the import left alone
 * stays byte for byte.
 */
export function restoredQueuedTurnText(
  text: string,
  rewrittenContextIds: ReadonlyMap<string, string>,
): string {
  return replaceComposerContextReferences(queuedTurnEditableText(text), (reference) => {
    const contextId = rewrittenContextIds.get(reference.contextId);
    return contextId
      ? formatInlineContextReference({
          ...reference,
          contextId,
          kind: reference.kind === "element" ? "preview-annotation" : reference.kind,
        })
      : reference.source;
  });
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
 * thread's rows (already in send order), or null when it is at that end.
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
    return pinOrderKeyBetween(rows[index - 2]?.orderKey ?? null, before.orderKey);
  }
  const after = rows[index + 1];
  if (!after) return null;
  return pinOrderKeyBetween(after.orderKey, rows[index + 2]?.orderKey ?? null);
}

// ---------------------------------------------------------------------------
// Legacy rows (#270 F): messages queued in the prompt stash before #806.
// `useLegacyQueueMigration` moves them to the server once.

/** The stash key a legacy queued entry carries in `queuedFor`. */
export function composerSendQueueKey(environmentId: EnvironmentId, threadId: ThreadId): string {
  return `${environmentId} ${threadId}`;
}

export function parseComposerSendQueueKey(
  key: string,
): { environmentId: EnvironmentId; threadId: ThreadId } | null {
  const separator = key.indexOf(" ");
  if (separator <= 0 || separator === key.length - 1) return null;
  return {
    environmentId: EnvironmentId.make(key.slice(0, separator)),
    threadId: ThreadId.make(key.slice(separator + 1)),
  };
}

export interface LegacyQueuedTurnCommand {
  readonly commandId: CommandId;
  readonly queueId: QueueId;
  readonly message: {
    readonly messageId: MessageId;
    readonly role: "user";
    readonly text: string;
    readonly attachments: ReadonlyArray<UploadChatImageAttachment | ChatFileAttachment>;
  };
}

/**
 * The `thread.turn.queue` a legacy entry becomes, or null while its images
 * are still being encoded. Both ids derive from the entry so two tabs
 * migrating the same stash converge: the server replays a used command id's
 * receipt, and re-queueing an existing queue id re-emits the row unchanged.
 * Images travel as the data URLs the stash kept (the same upload shape a
 * send uses); files as the pending uploads they already are.
 */
export function legacyQueuedEntryCommand(entry: PromptStashEntry): LegacyQueuedTurnCommand | null {
  if (entry.pendingImageCount) return null;
  const images: UploadChatImageAttachment[] = entry.attachments.map((attachment) => ({
    type: "image",
    name: attachment.name,
    mimeType: attachment.mimeType,
    sizeBytes: attachment.sizeBytes,
    dataUrl: attachment.dataUrl,
    ...(attachment.source ? { source: attachment.source } : {}),
  }));
  const files: ChatFileAttachment[] = (entry.files ?? []).map((file) => ({
    type: "file",
    id: file.attachmentId,
    name: file.name,
    mimeType: file.mimeType,
    sizeBytes: file.sizeBytes,
  }));
  return {
    commandId: CommandId.make(`stash-migrate:${entry.id}`),
    queueId: QueueId.make(entry.id),
    message: {
      messageId: MessageId.make(entry.id),
      role: "user",
      text: entry.prompt,
      attachments: [...images, ...files],
    },
  };
}
