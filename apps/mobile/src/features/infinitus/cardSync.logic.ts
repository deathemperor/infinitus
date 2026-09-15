/**
 * The thread-card bridge's re-scan (#1265). expo-widgets hands the app no
 * activity-state event, so the bridge learns that a card ended by scanning
 * `getInstances()` again — which native filters to the active and stale
 * cards, a stale card being still on screen and updatable, so its token
 * stays with the Mac. A card the Mac keeps sending updates to after it ended
 * is the bug: APNs answers 200 into nothing and the push-to-start token is
 * never used again.
 */
export interface CardSync {
  /** Cards the bridge watches that are no longer live: their listeners go. */
  readonly gone: ReadonlyArray<string>;
  /** Live cards the bridge does not watch yet. */
  readonly added: ReadonlyArray<string>;
  /** Withdraw the `agent-activity` registration: no card is live and the
      Mac's slot has not been cleared during this empty stretch. A launch with
      no card counts — the card a reinstall replaced was never offered by this
      process, yet its token sits on the Mac; the Mac answers a forget of an
      empty slot with `forgotten: false`, a no-op. */
  readonly withdraw: boolean;
}

export function syncWatchedCards(input: {
  readonly watched: ReadonlySet<string>;
  readonly live: ReadonlyArray<string>;
  /** The slot was already withdrawn since the last card token was offered. */
  readonly slotCleared: boolean;
}): CardSync {
  const live = new Set(input.live);
  return {
    gone: [...input.watched].filter((id) => !live.has(id)),
    added: input.live.filter((id) => !input.watched.has(id)),
    withdraw: input.live.length === 0 && !input.slotCleared,
  };
}
