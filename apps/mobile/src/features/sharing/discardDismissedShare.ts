import type { IncomingSharePresentationTransition } from "./incoming-share-presentation";

/**
 * Fork: the new-task sheet closing over an unimported share declines it. Any
 * navigation away counts, a notification tap included: nothing else surfaces
 * the inbox, so keeping the item would only replay the sheet on the next cold
 * launch. Called from `Stack.tsx`'s share effect with the provider's
 * `discardShare`.
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
