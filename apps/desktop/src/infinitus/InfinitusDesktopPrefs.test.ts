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
    expect(decodeInfinitusDesktopPrefs("{}")).toEqual({
      quitInfinitusWithApp: false,
      captureGestureEnabled: false,
    });
    expect(decodeInfinitusDesktopPrefs('{"quitInfinitusWithApp":"yes"}')).toEqual(
      DEFAULT_INFINITUS_DESKTOP_PREFS,
    );
  });

  it("round-trips the knobs", () => {
    const prefs = { quitInfinitusWithApp: true, captureGestureEnabled: true };
    const encoded = encodeInfinitusDesktopPrefs(prefs);
    expect(encoded.endsWith("\n")).toBe(true);
    expect(decodeInfinitusDesktopPrefs(encoded)).toEqual(prefs);
  });

  it("reads a file from the build before the capture gesture", () => {
    expect(decodeInfinitusDesktopPrefs('{"quitInfinitusWithApp":true}')).toEqual({
      quitInfinitusWithApp: true,
      captureGestureEnabled: false,
    });
  });
});
