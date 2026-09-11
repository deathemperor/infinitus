import { describe, expect, it } from "vite-plus/test";

import { newPinOrderKey, pinningSupport } from "./pinThread.logic";

describe("pinningSupport", () => {
  it("reads the two flags, absent meaning no", () => {
    expect(pinningSupport(undefined)).toEqual({ pin: false, reorder: false });
    expect(pinningSupport({ threadPinning: true })).toEqual({ pin: true, reorder: false });
    expect(pinningSupport({ threadPinning: true, threadPinReorder: true })).toEqual({
      pin: true,
      reorder: true,
    });
  });
});

describe("newPinOrderKey", () => {
  it("sorts ahead of the lowest keyed pin and ignores unpinned or keyless threads", () => {
    const key = newPinOrderKey([
      { pinnedAt: null, pinOrderKey: "c" },
      { pinnedAt: "2026-09-11T00:00:00.000Z", pinOrderKey: null },
      { pinnedAt: "2026-09-11T00:00:00.000Z", pinOrderKey: "t" },
      { pinnedAt: "2026-09-11T00:00:00.000Z", pinOrderKey: "m" },
    ]);
    expect(key).toBeDefined();
    expect(key! < "m").toBe(true);
  });

  it("still yields a key with no pinned thread around", () => {
    expect(typeof newPinOrderKey([])).toBe("string");
  });
});
