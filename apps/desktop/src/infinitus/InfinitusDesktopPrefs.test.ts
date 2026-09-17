import { describe, expect, it } from "vite-plus/test";

import {
  DEFAULT_INFINITUS_DESKTOP_PREFS,
  applyEngineSettings,
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
      engines: [],
    });
    expect(decodeInfinitusDesktopPrefs('{"quitInfinitusWithApp":"yes"}')).toEqual(
      DEFAULT_INFINITUS_DESKTOP_PREFS,
    );
  });

  it("round-trips the knobs", () => {
    const prefs = { quitInfinitusWithApp: true, captureGestureEnabled: true, engines: [] };
    const encoded = encodeInfinitusDesktopPrefs(prefs);
    expect(encoded.endsWith("\n")).toBe(true);
    expect(decodeInfinitusDesktopPrefs(encoded)).toEqual(prefs);
  });

  it("reads a file from the build before the capture gesture", () => {
    expect(decodeInfinitusDesktopPrefs('{"quitInfinitusWithApp":true}')).toEqual({
      quitInfinitusWithApp: true,
      captureGestureEnabled: false,
      engines: [],
    });
  });

  it("keeps an engine row a hand edit or a later build wrote", () => {
    expect(
      decodeInfinitusDesktopPrefs('{"engines":[{"key":"9router","managed":true,"command":null}]}')
        .engines,
    ).toEqual([{ key: "9router", managed: true, command: null }]);
  });
});

describe("engine settings", () => {
  it("adds a row for an engine that had none", () => {
    expect(applyEngineSettings([], { key: "9router", managed: true })).toEqual([
      { key: "9router", managed: true, command: null },
    ]);
  });

  it("leaves an absent field as it was", () => {
    const current = [{ key: "9router" as const, managed: true, command: "/bin/x" }];
    expect(applyEngineSettings(current, { key: "9router", managed: false })).toEqual([
      { key: "9router", managed: false, command: "/bin/x" },
    ]);
  });

  it("clears the override on an empty command, so detection takes over again", () => {
    const current = [{ key: "9router" as const, managed: true, command: "/bin/x" }];
    expect(applyEngineSettings(current, { key: "9router", command: "  " })).toEqual([
      { key: "9router", managed: true, command: null },
    ]);
  });

  it("leaves the other engines alone", () => {
    const current = [{ key: "cliproxy" as const, managed: true, command: null }];
    const next = applyEngineSettings(current, { key: "9router", managed: true });
    expect(next.map((entry) => entry.key).sort()).toEqual(["9router", "cliproxy"]);
  });
});
