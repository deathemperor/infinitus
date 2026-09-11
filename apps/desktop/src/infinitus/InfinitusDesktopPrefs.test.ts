import { describe, expect, it } from "vite-plus/test";

import {
  DEFAULT_INFINITUS_DESKTOP_PREFS,
  decodeInfinitusDesktopPrefs,
  encodeInfinitusDesktopPrefs,
} from "./InfinitusDesktopPrefs.ts";

describe("InfinitusDesktopPrefs codec", () => {
  it("defaults when there is no file, an unreadable one, or a missing key", () => {
    expect(decodeInfinitusDesktopPrefs(null)).toEqual(DEFAULT_INFINITUS_DESKTOP_PREFS);
    expect(decodeInfinitusDesktopPrefs("not json")).toEqual(DEFAULT_INFINITUS_DESKTOP_PREFS);
    expect(decodeInfinitusDesktopPrefs("{}")).toEqual({ quitInfinitusWithApp: false });
    expect(decodeInfinitusDesktopPrefs('{"quitInfinitusWithApp":"yes"}')).toEqual(
      DEFAULT_INFINITUS_DESKTOP_PREFS,
    );
  });

  it("round-trips the knob", () => {
    const encoded = encodeInfinitusDesktopPrefs({ quitInfinitusWithApp: true });
    expect(encoded.endsWith("\n")).toBe(true);
    expect(decodeInfinitusDesktopPrefs(encoded)).toEqual({ quitInfinitusWithApp: true });
  });
});
