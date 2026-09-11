import { Atom } from "effect/unstable/reactivity";

import { appAtomRegistry } from "../../state/atom-registry";

/**
 * Bumped after this app starts a Live Activity itself (the test card, #845),
 * so `InfinitusLiveActivityBridge` re-scans the live cards and hands the new
 * card's update token to the Mac. Without it the bridge only scans at mount
 * and on the next foreground, and a card started from Settings — the app
 * already active — never registers a `working` token.
 */
export const localLiveActivityStartsAtom = Atom.make(0).pipe(Atom.keepAlive);

export function noteLocalLiveActivityStart(): void {
  appAtomRegistry.set(
    localLiveActivityStartsAtom,
    appAtomRegistry.get(localLiveActivityStartsAtom) + 1,
  );
}
