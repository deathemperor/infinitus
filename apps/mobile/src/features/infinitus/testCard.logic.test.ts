import { describe, expect, it, vi } from "vite-plus/test";

import {
  TEST_CARD_STALE_MS,
  TEST_CARD_STATE,
  type TestCardFactory,
  testCardLabel,
  testCardState,
  toggleTestCard,
} from "./testCard.logic";

describe("TEST_CARD_STATE", () => {
  it("is upstream's aggregate card shape with a row per ranked phase", () => {
    expect(TEST_CARD_STATE.activeCount).toBe(2);
    expect(TEST_CARD_STATE.activities.map((row) => row.phase)).toEqual([
      "waiting_for_approval",
      "running",
      "completed",
    ]);
    for (const row of TEST_CARD_STATE.activities) {
      expect(row.threadTitle.length).toBeGreaterThan(0);
      expect(row.deepLink.startsWith("/")).toBe(true);
    }
  });
});

describe("testCardState", () => {
  it("dates the working row against the press so its timer starts near zero", () => {
    const now = new Date("2026-09-12T00:00:00Z");
    const rows = testCardState(now).activities;

    const working = rows.find((row) => row.phase === "running");
    expect(working?.startedAt).toBe("2026-09-11T23:58:30.000Z");
    for (const row of rows.filter((candidate) => candidate.phase !== "running")) {
      expect(row.startedAt).toBeUndefined();
    }
  });
});

describe("testCardLabel", () => {
  it("offers a start with no live card and an end otherwise", () => {
    expect(testCardLabel(0)).toBe("Show a test card");
    expect(testCardLabel(1)).toBe("End the thread card");
    expect(testCardLabel(3)).toBe("End 3 thread cards");
  });
});

describe("toggleTestCard", () => {
  const now = new Date("2026-09-12T00:00:00Z");

  it("starts the test card, stale two minutes on, when nothing is live", async () => {
    const start = vi.fn();
    const factory: TestCardFactory = { start, getInstances: () => [] };

    await expect(toggleTestCard(factory, now)).resolves.toEqual({ action: "started" });
    expect(start).toHaveBeenCalledWith(
      testCardState(now),
      undefined,
      new Date(now.getTime() + TEST_CARD_STALE_MS),
    );
  });

  it("ends every live card at once instead of starting another", async () => {
    const end = vi.fn(() => Promise.resolve());
    const factory: TestCardFactory = { start: vi.fn(), getInstances: () => [{ end }, { end }] };

    await expect(toggleTestCard(factory, now)).resolves.toEqual({ action: "ended", count: 2 });
    expect(end).toHaveBeenCalledTimes(2);
    expect(end).toHaveBeenCalledWith("immediate");
    expect(factory.start).not.toHaveBeenCalled();
  });

  it("reports ActivityKit's refusal as the outcome", async () => {
    const factory: TestCardFactory = {
      start: () => {
        throw new Error("Live Activities are not supported or disabled");
      },
      getInstances: () => [],
    };

    await expect(toggleTestCard(factory, now)).resolves.toEqual({
      action: "failed",
      message: "Live Activities are not supported or disabled",
    });
  });
});
