import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import type { ThreadId } from "@t3tools/contracts";

import type { ThreadOutboxDeliveryAction } from "./thread-outbox-model";

/**
 * The phone's copy of the desktop composer's queue-vs-steer rule (#270 F,
 * #807): a follow-up queued for an existing thread waits while that thread's
 * turn runs (`starting` / `running`) or while the server holds or has paused
 * it, instead of steering the running turn. Creations are untouched — there
 * is no turn to steer — and so is every action but `send`. `steer` is the
 * upstream behaviour, kept for when the phone grows the desktop's setting.
 */
export type OutboxQueueMode = "queue" | "steer";

export function queueBehindRunningTurn(input: {
  readonly action: ThreadOutboxDeliveryAction;
  readonly isCreation: boolean;
  readonly threadBusy: boolean;
  readonly threadHeld: boolean;
  readonly mode: OutboxQueueMode;
}): ThreadOutboxDeliveryAction {
  if (input.action !== "send" || input.isCreation || input.mode === "steer") return input.action;
  return input.threadBusy || input.threadHeld ? "wait" : "send";
}

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
