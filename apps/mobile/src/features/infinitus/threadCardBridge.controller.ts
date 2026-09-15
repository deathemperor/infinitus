import type { LiveActivityTokenKind } from "./liveActivity.logic";
import { cardsToEnd, syncWatchedCards } from "./cardSync.logic";
import { nextRetry, NO_RETRY } from "./pushRetry.logic";

/**
 * The thread-card bridge's body, outside React so its timers and triggers can
 * be exercised in a test (#941): `InfinitusThreadCardBridge` starts one per
 * enabled Mac and stops it on cleanup, handing in the real iOS, Mac and
 * diagnostics hooks. Behaviour is the bridge's as it stood in the hook — see
 * the bridge's doc comment for the rules (#1047, #941, #1265).
 */

export interface Subscription {
  remove(): void;
}

/** What the bridge needs of a running `AgentActivity` card. */
export interface LiveCard {
  getId(): string;
  getPushToken(): Promise<string | null>;
  addPushTokenListener(listener: (event: { readonly pushToken: string }) => void): Subscription;
  /** Ends the card; `"immediate"` takes it off the lock screen at once. */
  end(dismissalPolicy: "immediate"): Promise<void>;
}

export interface ThreadCardBridgeDeps {
  /** The sender for this bridge; `isCancelled` reads the bridge's stop. */
  readonly makeSend: (
    isCancelled: () => boolean,
  ) => (kind: LiveActivityTokenKind, token: string) => Promise<boolean>;
  /** Withdraws the `agent-activity` registration; answers whether it landed. */
  readonly forgetCardToken: () => Promise<boolean>;
  readonly getInstances: () => ReadonlyArray<LiveCard>;
  readonly addPushToStartTokenListener: (
    listener: (event: { readonly activityPushToStartToken: string }) => void,
  ) => Subscription;
  readonly addAppStateListener: (listener: (state: string) => void) => Subscription;
  /** A Live Activity of this app started or changed state (#1277): the card
      iOS starts from a push-to-start while the app is in the background is
      only ever seen here, so every event re-reads the live cards. */
  readonly addActivityUpdateListener: (
    listener: (event: { readonly activityId: string; readonly state: string }) => void,
  ) => Subscription;
  /** A local card start or end (the test card); answers the unsubscribe. */
  readonly subscribeLocalChanges: (listener: () => void) => () => void;
  readonly isConnected: () => boolean;
  readonly now: () => Date;
  readonly notes: {
    readonly watching: (since: Date | null) => void;
    readonly withdrawn: (at: Date) => void;
  };
}

export interface ThreadCardBridge {
  /** Send what is held, at once: the Mac became reachable. */
  readonly retry: () => void;
  readonly stop: () => void;
}

export function startThreadCardBridge(deps: ThreadCardBridgeDeps): ThreadCardBridge {
  let cancelled = false;
  const watched = new Map<string, Subscription>();
  const subscriptions: Array<Subscription> = [];
  const send = deps.makeSend(() => cancelled);
  /** The newest token iOS has handed over per kind, sent until it lands. */
  const latest = new Map<LiveActivityTokenKind, string>();
  /** No card is live and the Mac's card slot is still to be cleared. */
  let withdraw = false;
  /** The slot was cleared since the last card token was offered. */
  let slotCleared = false;
  /** The card whose token was last offered — the one the Mac can update. */
  let heldCard: string | null = null;
  let schedule = NO_RETRY;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let sending = false;
  let again = false;

  const clearTimer = () => {
    if (timer !== null) clearTimeout(timer);
    timer = null;
  };

  /** One round over every held token. Rounds never overlap: a second one
      asked for mid-flight waits, since a throttled repeat answers "on file"
      for a send whose failure has not been recorded yet, and would read as
      a landing that cancels the retry the failing round is about to set. */
  const flush = async (): Promise<void> => {
    if (sending) {
      again = true;
      return;
    }
    sending = true;
    clearTimer();
    try {
      const outcomes = await Promise.all([
        ...[...latest].map(([kind, token]) => send(kind, token)),
        ...(withdraw ? [forgetCard()] : []),
      ]);
      if (cancelled) return;
      schedule = nextRetry({
        attempt: schedule.attempt,
        landed: outcomes.every(Boolean),
        connected: deps.isConnected(),
      });
      if (schedule.delayMs !== null) timer = setTimeout(() => void flush(), schedule.delayMs);
    } finally {
      sending = false;
    }
    if (again && !cancelled) {
      again = false;
      await flush();
    }
  };

  /** The pending withdrawal, answered like a send: landed or not. A card
      token offered meanwhile has already dropped it, so a landing then is
      not recorded over the new card's registration. */
  const forgetCard = async (): Promise<boolean> => {
    const landed = await deps.forgetCardToken();
    if (!landed || cancelled || !withdraw) return landed;
    withdraw = false;
    slotCleared = true;
    deps.notes.withdrawn(deps.now());
    return true;
  };

  /** A token from iOS: a new one is a fresh chance, so the backoff resets. */
  const offer = (kind: LiveActivityTokenKind, token: string, from?: string) => {
    if (cancelled || latest.get(kind) === token) return;
    latest.set(kind, token);
    if (kind === "agent-activity") {
      withdraw = false;
      slotCleared = false;
      heldCard = from ?? heldCard;
    }
    schedule = NO_RETRY;
    void flush();
  };

  /** Re-reads the live cards: keeps one (#1277) and ends the others at once,
      watches the new one, lets the ended ones go, and queues the withdrawal
      when none is left. */
  const sync = () => {
    const all = deps.getInstances();
    const extra = cardsToEnd({ live: all.map((activity) => activity.getId()), held: heldCard });
    for (const activity of all) {
      if (extra.end.includes(activity.getId())) void activity.end("immediate").catch(() => {});
    }
    const live = all.filter((activity) => activity.getId() === extra.keep);
    const next = syncWatchedCards({
      watched: new Set(watched.keys()),
      live: live.map((activity) => activity.getId()),
      slotCleared,
    });
    for (const id of next.gone) {
      watched.get(id)?.remove();
      watched.delete(id);
    }
    for (const activity of live) {
      const id = activity.getId();
      if (!next.added.includes(id)) continue;
      watched.set(
        id,
        activity.addPushTokenListener((event) => offer("agent-activity", event.pushToken, id)),
      );
      void activity.getPushToken().then((token) => {
        if (token) offer("agent-activity", token, id);
      });
    }
    if (next.withdraw && !withdraw) {
      withdraw = true;
      latest.delete("agent-activity");
      schedule = NO_RETRY;
      void flush();
    }
  };

  const retry = () => {
    if (cancelled) return;
    schedule = NO_RETRY;
    void flush();
  };

  subscriptions.push(
    deps.addPushToStartTokenListener((event) =>
      offer("agent-activity-start", event.activityPushToStartToken),
    ),
  );
  sync();
  deps.notes.watching(deps.now());
  subscriptions.push(
    deps.addAppStateListener((state) => {
      if (state !== "active") return;
      sync();
      retry();
    }),
  );
  subscriptions.push(deps.addActivityUpdateListener(() => sync()));
  const unsubscribeLocal = deps.subscribeLocalChanges(sync);

  return {
    retry,
    stop: () => {
      cancelled = true;
      clearTimer();
      deps.notes.watching(null);
      unsubscribeLocal();
      for (const subscription of subscriptions) subscription.remove();
      for (const subscription of watched.values()) subscription.remove();
    },
  };
}
