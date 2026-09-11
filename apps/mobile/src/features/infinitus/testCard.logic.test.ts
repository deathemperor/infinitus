import { InfinitusWorkingActivityState } from "@t3tools/contracts/infinitus";
import * as Schema from "effect/Schema";
import { describe, expect, it, vi } from "vite-plus/test";

import {
  TEST_CARD_STALE_MS,
  TEST_CARD_STATE,
  type TestCardFactory,
  testCardLabel,
  toggleTestCard,
} from "./testCard.logic";

const decodeState = Schema.decodeUnknownSync(InfinitusWorkingActivityState);

describe("TEST_CARD_STATE", () => {
  it("is a valid working card state, every optional field set", () => {
    expect(() => decodeState(TEST_CARD_STATE)).not.toThrow();
    expect(TEST_CARD_STATE.windows.length).toBeGreaterThan(1);
    expect(TEST_CARD_STATE.tokensPerMinute).not.toBeNull();
  });
});

describe("testCardLabel", () => {
  it("offers a start with no live card and an end otherwise", () => {
    expect(testCardLabel(0)).toBe("Show a test card");
    expect(testCardLabel(1)).toBe("End the working card");
    expect(testCardLabel(3)).toBe("End 3 working cards");
  });
});

describe("toggleTestCard", () => {
  const now = new Date("2026-09-12T00:00:00Z");

  it("starts the test card, stale two minutes on, when nothing is live", async () => {
    const start = vi.fn();
    const factory: TestCardFactory = { start, getInstances: () => [] };

    await expect(toggleTestCard(factory, now)).resolves.toEqual({ action: "started" });
    expect(start).toHaveBeenCalledWith(
      TEST_CARD_STATE,
      undefined,
      new Date(now.getTime() + TEST_CARD_STALE_MS),
    );
  });

  it("ends every live card at once instead of starting another", async () => {
    const end = vi.fn(() => Promise.resolve());
    const factory: TestCardFactory = {
      start: vi.fn(),
      getInstances: () => [{ end }, { end }],
    };

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
