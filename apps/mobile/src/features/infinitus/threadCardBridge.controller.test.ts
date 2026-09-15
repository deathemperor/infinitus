import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

import type { LiveActivityTokenKind } from "./liveActivity.logic";
import { retryDelayMs } from "./pushRetry.logic";
import {
  type LiveCard,
  startThreadCardBridge,
  type ThreadCardBridgeDeps,
} from "./threadCardBridge.controller";

/** A card as the bridge sees it: an id and a token it hands over on request. */
function card(id: string, token: string | null = `tok-${id}`): LiveCard {
  return {
    getId: () => id,
    getPushToken: () => Promise.resolve(token),
    addPushTokenListener: () => ({ remove: vi.fn() }),
  };
}

/** The bridge's world: every trigger a handle, every send and forget scripted. */
function harness(input: {
  readonly cards?: ReadonlyArray<LiveCard>;
  readonly connected?: boolean;
  /** What each send answers, in order; the last answer repeats. */
  readonly sends?: ReadonlyArray<boolean>;
  readonly forgets?: ReadonlyArray<boolean>;
}) {
  const sent: Array<{ kind: LiveActivityTokenKind; token: string; at: number }> = [];
  const forgets: Array<number> = [];
  const sendAnswers = [...(input.sends ?? [true])];
  const forgetAnswers = [...(input.forgets ?? [true])];
  const next = (answers: boolean[]) => (answers.length > 1 ? answers.shift()! : answers[0]!);
  let connected = input.connected ?? true;
  let cards = input.cards ?? [];
  let startListener: ((event: { readonly activityPushToStartToken: string }) => void) | null = null;
  let appStateListener: ((state: string) => void) | null = null;
  let activityListener:
    | ((event: { readonly activityId: string; readonly state: string }) => void)
    | null = null;
  let localListener: (() => void) | null = null;
  const instancesRead = vi.fn(() => cards);
  const notes = { watching: vi.fn(), withdrawn: vi.fn() };
  const deps: ThreadCardBridgeDeps = {
    makeSend: () => async (kind, token) => {
      sent.push({ kind, token, at: Date.now() });
      return next(sendAnswers);
    },
    forgetCardToken: async () => {
      forgets.push(Date.now());
      return next(forgetAnswers);
    },
    getInstances: instancesRead,
    addPushToStartTokenListener: (listener) => {
      startListener = listener;
      return { remove: vi.fn() };
    },
    addAppStateListener: (listener) => {
      appStateListener = listener;
      return { remove: vi.fn() };
    },
    addActivityUpdateListener: (listener) => {
      activityListener = listener;
      return { remove: vi.fn() };
    },
    subscribeLocalChanges: (listener) => {
      localListener = listener;
      return () => undefined;
    },
    isConnected: () => connected,
    now: () => new Date(),
    notes,
  };
  const bridge = startThreadCardBridge(deps);
  return {
    bridge,
    sent,
    forgets,
    notes,
    instancesRead,
    vendStartToken: (token: string) => startListener?.({ activityPushToStartToken: token }),
    appState: (state: string) => appStateListener?.(state),
    activityUpdate: (activityId: string, state: string) =>
      activityListener?.({ activityId, state }),
    localChange: () => localListener?.(),
    setConnected: (value: boolean) => {
      connected = value;
    },
    setCards: (value: ReadonlyArray<LiveCard>) => {
      cards = value;
    },
  };
}

/** Lets the pending sends settle without moving the clock. */
const settle = () => vi.advanceTimersByTimeAsync(0);

describe("startThreadCardBridge — the re-send timer (#941)", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-15T04:00:00Z"));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("re-sends a token whose first send failed after the first delay, while the Mac is reachable", async () => {
    const h = harness({ sends: [false, true] });
    h.vendStartToken("start-1");
    await settle();
    expect(h.sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(retryDelayMs(1) - 1);
    expect(h.sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(h.sent).toHaveLength(2);
    expect(h.sent[1]).toMatchObject({ kind: "agent-activity-start", token: "start-1" });
    expect(h.sent[1]!.at - h.sent[0]!.at).toBe(retryDelayMs(1));
    h.bridge.stop();
  });

  it("stops the timer once the token landed", async () => {
    const h = harness({ sends: [false, true] });
    h.vendStartToken("start-1");
    await settle();
    await vi.advanceTimersByTimeAsync(retryDelayMs(1));
    expect(h.sent).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(retryDelayMs(2) * 4);
    expect(h.sent).toHaveLength(2);
    h.bridge.stop();
  });

  it("schedules nothing while the Mac is unreachable; the connect and the foreground send at once", async () => {
    const h = harness({ connected: false, sends: [false, false, false, true] });
    h.vendStartToken("start-1");
    await settle();
    expect(h.sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(retryDelayMs(1) * 10);
    expect(h.sent).toHaveLength(1);
    h.setConnected(true);
    h.bridge.retry();
    await settle();
    expect(h.sent).toHaveLength(2);
    expect(h.sent[1]!.at).toBe(h.sent[0]!.at + retryDelayMs(1) * 10);
    h.appState("active");
    await settle();
    expect(h.sent).toHaveLength(3);
    h.bridge.stop();
  });

  it("sends nothing after stop and lets the diagnostics know it left", async () => {
    const h = harness({ sends: [false] });
    h.vendStartToken("start-1");
    await settle();
    expect(h.notes.watching).toHaveBeenLastCalledWith(expect.any(Date));
    h.bridge.stop();
    expect(h.notes.watching).toHaveBeenLastCalledWith(null);
    await vi.advanceTimersByTimeAsync(retryDelayMs(1) * 2);
    expect(h.sent).toHaveLength(1);
  });
});

describe("startThreadCardBridge — the re-scan (#1267)", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("re-reads the live cards once per foreground transition", async () => {
    const h = harness({ cards: [card("a")] });
    expect(h.instancesRead).toHaveBeenCalledTimes(1);
    h.appState("active");
    h.appState("active");
    h.appState("background");
    h.appState("inactive");
    expect(h.instancesRead).toHaveBeenCalledTimes(3);
    h.localChange();
    expect(h.instancesRead).toHaveBeenCalledTimes(4);
    h.bridge.stop();
  });

  it("hands a live card's token over and withdraws nothing while it lives", async () => {
    const h = harness({ cards: [card("a")] });
    await settle();
    expect(h.sent).toEqual([expect.objectContaining({ kind: "agent-activity", token: "tok-a" })]);
    h.appState("active");
    await settle();
    expect(h.forgets).toHaveLength(0);
    h.bridge.stop();
  });

  it("withdraws the card token once no card is live, once per empty stretch", async () => {
    const h = harness({ cards: [] });
    await settle();
    expect(h.forgets).toHaveLength(1);
    expect(h.notes.withdrawn).toHaveBeenCalledTimes(1);
    h.appState("active");
    h.localChange();
    await settle();
    expect(h.forgets).toHaveLength(1);
    h.setCards([card("b")]);
    h.localChange();
    await settle();
    expect(h.sent).toEqual([expect.objectContaining({ kind: "agent-activity", token: "tok-b" })]);
    h.setCards([]);
    h.localChange();
    await settle();
    expect(h.forgets).toHaveLength(2);
    h.bridge.stop();
  });

  it("retries a withdrawal the Mac did not take, and records only the one that landed", async () => {
    const h = harness({ cards: [], forgets: [false, true] });
    await settle();
    expect(h.forgets).toHaveLength(1);
    expect(h.notes.withdrawn).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(retryDelayMs(1));
    expect(h.forgets).toHaveLength(2);
    expect(h.notes.withdrawn).toHaveBeenCalledTimes(1);
    h.bridge.stop();
  });

  it("offers a card's token the moment iOS reports it started, app in the background (#1277)", async () => {
    const h = harness({ cards: [] });
    await settle();
    expect(h.forgets).toHaveLength(1);
    h.setCards([card("p")]);
    h.activityUpdate("p", "started");
    await settle();
    expect(h.instancesRead).toHaveBeenCalledTimes(2);
    expect(h.sent).toEqual([expect.objectContaining({ kind: "agent-activity", token: "tok-p" })]);
    h.setCards([]);
    h.activityUpdate("p", "ended");
    await settle();
    expect(h.forgets).toHaveLength(2);
    h.bridge.stop();
  });
});
