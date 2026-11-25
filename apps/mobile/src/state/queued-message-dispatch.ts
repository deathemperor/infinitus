import type { MessageId } from "@infinitus/contracts";
import { Atom } from "effect/reactivity";

import { appAtomRegistry } from "./atom-registry";

/**
 * How far the outbox got delivering a queued message (#1501). `uploading` (before the send
 * RPC) still allows edit or delete, which aborts the wait on its upload. Once `sending`, the
 * turn may already be the server's, so neither is offered.
 */
export type QueuedMessageDispatchPhase = "uploading" | "sending";

/** Messages being delivered now, at most one per thread (the head of its queue). */
export const dispatchingQueuedMessagesAtom = Atom.make<
  Readonly<Partial<Record<MessageId, QueuedMessageDispatchPhase>>>
>({}).pipe(Atom.keepAlive, Atom.withLabel("mobile:thread-outbox:dispatching-messages"));

const uploadAborts = new Map<MessageId, AbortController>();

function setPhase(messageId: MessageId, phase: QueuedMessageDispatchPhase | null): void {
  const { [messageId]: _previous, ...others } = appAtomRegistry.get(dispatchingQueuedMessagesAtom);
  appAtomRegistry.set(
    dispatchingQueuedMessagesAtom,
    phase === null ? others : { ...others, [messageId]: phase },
  );
}

/** Starts a message's dispatch; the signal aborts its upload phase. */
export function beginDispatchingQueuedMessage(messageId: MessageId): AbortSignal {
  const controller = new AbortController();
  uploadAborts.set(messageId, controller);
  setPhase(messageId, "uploading");
  return controller.signal;
}

/**
 * Flips the dispatch to `sending`, false when the upload phase was already
 * aborted so the delivery abandons instead of sending a message being reclaimed.
 * Nothing may await between the caller's last upload-phase step and this call.
 */
export function markDispatchingQueuedMessageSending(messageId: MessageId): boolean {
  const controller = uploadAborts.get(messageId);
  if (
    appAtomRegistry.get(dispatchingQueuedMessagesAtom)[messageId] === undefined ||
    controller === undefined ||
    controller.signal.aborted
  ) {
    return false;
  }
  setPhase(messageId, "sending");
  return true;
}

export function finishDispatchingQueuedMessage(messageId: MessageId): void {
  if (appAtomRegistry.get(dispatchingQueuedMessagesAtom)[messageId] === undefined) return;
  uploadAborts.delete(messageId);
  setPhase(messageId, null);
}

/**
 * Whether the user may take a queued message back (edit or delete) right now.
 * An upload in flight is aborted; a send in flight refuses.
 */
export function reclaimQueuedMessageFromDispatch(messageId: MessageId): boolean {
  const phase = appAtomRegistry.get(dispatchingQueuedMessagesAtom)[messageId];
  if (phase === undefined) return true;
  if (phase === "sending") return false;
  uploadAborts.get(messageId)?.abort();
  return true;
}
