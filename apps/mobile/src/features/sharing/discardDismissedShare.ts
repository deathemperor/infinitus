import type { IncomingSharePresentationTransition } from "./incoming-share-presentation";

/**
 * Fork: the new-task sheet closing over an unimported share declines it. Any navigation
 * away counts, a notification tap included: keeping it would replay the sheet on the next
 * cold launch. Called from `IncomingShareProvider.tsx`'s `presentPendingIncomingShare`.
 */
export function discardDismissedShare(
  transition: IncomingSharePresentationTransition,
  discardShare: (shareId: string) => Promise<void>,
): void {
  if (!transition.shareIdToDiscard) return;
  void discardShare(transition.shareIdToDiscard).catch((error) => {
    console.warn("[incoming-share] could not discard a dismissed share", error);
  });
}
