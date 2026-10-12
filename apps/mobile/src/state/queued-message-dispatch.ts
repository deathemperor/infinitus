import type { MessageId } from "@infinitus/contracts";
import { Atom } from "effect/reactivity";

import { appAtomRegistry } from "./atom-registry";

/**
 * The queued message the outbox drain is delivering, and how far it got
 * (#1501). `uploading` covers everything before the send RPC: settings sync
 * and the attachment transfers. The user may still edit or delete the message
 * then; `reclaimQueuedMessageFromDispatch` aborts the transfer and the drain
 * abandons the attempt. Once `sending`, the turn may already be the server's,
 * so neither control is offered until the drain finishes.
 */
export type DispatchingQueuedMessage = {
  readonly messageId: MessageId;
  readonly phase: "uploading" | "sending";
};

export const dispatchingQueuedMessageAtom = Atom.make<DispatchingQueuedMessage | null>(null).pipe(
  Atom.keepAlive,
  Atom.withLabel("mobile:thread-outbox:dispatching-message"),
);

let uploadAbort: AbortController | null = null;

/** The drain holds one dispatch at a time; the signal aborts its upload phase. */
export function beginDispatchingQueuedMessage(messageId: MessageId): AbortSignal {
  uploadAbort = new AbortController();
  appAtomRegistry.set(dispatchingQueuedMessageAtom, { messageId, phase: "uploading" });
  return uploadAbort.signal;
}

/**
 * Flips the dispatch to `sending`, false when the upload phase was already
 * aborted so the drain abandons instead of sending a message being reclaimed.
 * Nothing may await between the caller's last upload-phase step and this call.
 */
export function markDispatchingQueuedMessageSending(messageId: MessageId): boolean {
  const current = appAtomRegistry.get(dispatchingQueuedMessageAtom);
  if (current?.messageId !== messageId || uploadAbort?.signal.aborted) {
    return false;
  }
  appAtomRegistry.set(dispatchingQueuedMessageAtom, { messageId, phase: "sending" });
  return true;
}

export function finishDispatchingQueuedMessage(messageId: MessageId): void {
  const current = appAtomRegistry.get(dispatchingQueuedMessageAtom);
  if (current?.messageId !== messageId) {
    return;
  }
  uploadAbort = null;
  appAtomRegistry.set(dispatchingQueuedMessageAtom, null);
}

/**
 * Whether the user may take a queued message back (edit or delete) right now.
 * An upload in flight is aborted; a send in flight refuses.
 */
export function reclaimQueuedMessageFromDispatch(messageId: MessageId): boolean {
  const current = appAtomRegistry.get(dispatchingQueuedMessageAtom);
  if (current?.messageId !== messageId) {
    return true;
  }
  if (current.phase === "sending") {
    return false;
  }
  uploadAbort?.abort();
  return true;
}
