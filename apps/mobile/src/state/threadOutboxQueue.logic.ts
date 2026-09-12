import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import type { CommandId, MessageId, ModelSelection, QueueId, ThreadId } from "@t3tools/contracts";
import { AsyncResult } from "effect/unstable/reactivity";

import type { PreparedTurnAttachments } from "../lib/attachmentUpload";
import type { ThreadOutboxDeliveryAction } from "./thread-outbox-model";

/**
 * The phone's copy of the desktop composer's queue-vs-steer rule (#270 F,
 * #807): a follow-up queued for an existing thread waits while that thread's
 * turn runs (`starting` / `running`) or while the server holds or has paused
 * it, instead of steering the running turn. Creations are untouched — there
 * is no turn to steer — and so is every action but `send`. `steer` is the
 * upstream behaviour: the send goes into the running turn. A held thread
 * waits in either mode — a steer never bypasses the server's hold.
 */
export type OutboxQueueMode = "queue" | "steer";

export function queueBehindRunningTurn(input: {
  readonly action: ThreadOutboxDeliveryAction;
  readonly isCreation: boolean;
  readonly threadBusy: boolean;
  readonly threadHeld: boolean;
  readonly mode: OutboxQueueMode;
}): ThreadOutboxDeliveryAction {
  if (input.action !== "send" || input.isCreation) return input.action;
  if (input.threadHeld) return "wait";
  if (input.mode === "steer") return "send";
  return input.threadBusy ? "wait" : "send";
}

/** This phone's mode from its preferences (`infinitusComposerSendMode`,
    the desktop's "Sending while a turn runs"): queue unless the store has
    loaded a `steer`, so a message drained before the store is read waits
    rather than steers. */
export function outboxQueueMode(
  preferences: AsyncResult.AsyncResult<
    { readonly infinitusComposerSendMode?: OutboxQueueMode },
    unknown
  >,
): OutboxQueueMode {
  return AsyncResult.isSuccess(preferences) &&
    preferences.value.infinitusComposerSendMode === "steer"
    ? "steer"
    : "queue";
}

export const COMPOSER_SEND_MODE_LABELS: Record<OutboxQueueMode, string> = {
  queue: "Queue until it finishes",
  steer: "Send into the running turn",
};

/** Whether the server's hold list names the thread: a start waiting for
    headroom, a turn paused, or a turn stopped on a usage limit — every kind
    keeps the follow-up queued, as the desktop's hold banner does. Null holds
    (no list yet, or an environment without Infinitus) hold nothing. */
export function isThreadHeld(
  holds: ReadonlyArray<InfinitusHeldThread> | null,
  threadId: ThreadId,
): boolean {
  return holds !== null && holds.some((entry) => entry.threadId === threadId);
}

/** `ThreadOutboxDeliveryAction` plus the fork's fourth outcome. */
export type ThreadOutboxDelivery = ThreadOutboxDeliveryAction | "queue";

/**
 * Fork (#812): where a follow-up goes. A send `queueBehindRunningTurn` would
 * make wait is instead handed to the server's queue (`thread.turn.queue`,
 * #806) when the server advertises `turnQueue` — the row then starts once
 * the thread is idle whether or not the phone is still open, and shows in
 * the thread's queue card. Servers without the capability keep the wait.
 */
export function resolveThreadOutboxDelivery(
  input: Parameters<typeof queueBehindRunningTurn>[0] & { readonly serverQueues: boolean },
): ThreadOutboxDelivery {
  const action = queueBehindRunningTurn(input);
  return action === "wait" && input.action === "send" && input.serverQueues ? "queue" : action;
}

/**
 * The `thread.turn.queue` an outbox message becomes: the outbox's command id
 * (the server's dedupe key), a fresh queue id per attempt, the prepared
 * attachments, the model the send resolved. Runtime and interaction mode
 * are not on the row — the settings sync before it put them on the thread.
 */
export function queueTurnCommandInput(input: {
  readonly message: {
    readonly commandId: CommandId;
    readonly threadId: ThreadId;
    readonly messageId: MessageId;
    readonly text: string;
    readonly createdAt: string;
  };
  readonly attachments: PreparedTurnAttachments["attachments"];
  readonly modelSelection: ModelSelection;
  readonly queueId: QueueId;
}) {
  return {
    commandId: input.message.commandId,
    threadId: input.message.threadId,
    queueId: input.queueId,
    message: {
      messageId: input.message.messageId,
      role: "user" as const,
      text: input.message.text,
      attachments: input.attachments,
    },
    modelSelection: input.modelSelection,
    createdAt: input.message.createdAt,
  };
}
