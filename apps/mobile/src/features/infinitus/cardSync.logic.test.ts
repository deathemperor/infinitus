import { describe, expect, it } from "vite-plus/test";

import { cardsToEnd, syncWatchedCards } from "./cardSync.logic";

describe("syncWatchedCards", () => {
  it("names the ended cards and the new ones", () => {
    const sync = syncWatchedCards({
      watched: new Set(["a", "b"]),
      live: ["b", "c"],
      slotCleared: false,
    });
    expect(sync.gone).toEqual(["a"]);
    expect(sync.added).toEqual(["c"]);
    expect(sync.withdraw).toBe(false);
  });

  it("withdraws the card token once no card is live, including at a launch with none", () => {
    expect(
      syncWatchedCards({ watched: new Set(["a"]), live: [], slotCleared: false }).withdraw,
    ).toBe(true);
    expect(syncWatchedCards({ watched: new Set(), live: [], slotCleared: false }).withdraw).toBe(
      true,
    );
  });

  it("withdraws once per empty stretch", () => {
    expect(syncWatchedCards({ watched: new Set(), live: [], slotCleared: true }).withdraw).toBe(
      false,
    );
  });

  it("keeps the token while a card is live, stale or not", () => {
    expect(
      syncWatchedCards({ watched: new Set(["a"]), live: ["a"], slotCleared: false }).withdraw,
    ).toBe(false);
  });
});

describe("cardsToEnd (#1277)", () => {
  it("keeps the card whose token the bridge holds and ends the rest", () => {
    expect(cardsToEnd({ live: ["a", "b", "c"], held: "b" })).toEqual({
      keep: "b",
      end: ["a", "c"],
    });
  });

  it("keeps the first listed card when none is held or the held one is gone", () => {
    expect(cardsToEnd({ live: ["a", "b"], held: null })).toEqual({ keep: "a", end: ["b"] });
    expect(cardsToEnd({ live: ["a", "b"], held: "z" })).toEqual({ keep: "a", end: ["b"] });
    expect(cardsToEnd({ live: ["a"], held: null })).toEqual({ keep: "a", end: [] });
    expect(cardsToEnd({ live: [], held: null })).toEqual({ keep: null, end: [] });
  });
});
