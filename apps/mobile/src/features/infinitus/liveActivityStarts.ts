import { Atom } from "effect/unstable/reactivity";

import { appAtomRegistry } from "../../state/atom-registry";

/**
 * Bumped after this app starts or ends a Live Activity itself (the test card,
 * #845, #1047, #1265), so `InfinitusThreadCardBridge` re-scans the live cards:
 * a new card's token goes to the Mac, and a card ended with none left has its
 * token withdrawn. Without it the bridge only scans at mount and on the next
 * foreground — the app is already active when Settings acts.
 */
export const localLiveActivityStartsAtom = Atom.make(0).pipe(Atom.keepAlive);

export function noteLocalLiveActivityChange(): void {
  appAtomRegistry.set(
    localLiveActivityStartsAtom,
    appAtomRegistry.get(localLiveActivityStartsAtom) + 1,
  );
}
