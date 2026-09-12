import { describe, expect, it } from "vite-plus/test";

import {
  isInfinitusDesktopVersion,
  resolveDefaultDesktopUpdateChannel,
  resolveEffectiveDesktopUpdateChannel,
  resolveElectronUpdaterFeed,
} from "./updateChannels.ts";

describe("resolveDefaultDesktopUpdateChannel", () => {
  it("defaults every build of this repo to the infinitus channel, an upstream nightly aside", () => {
    // One product, one version (#823): the channel is no longer read off a
    // dated suffix. `latest` is upstream's stable channel and never a default here.
    expect(resolveDefaultDesktopUpdateChannel("0.5.0-alpha.1")).toBe("infinitus");
    expect(resolveDefaultDesktopUpdateChannel("0.5.0")).toBe("infinitus");
    expect(resolveDefaultDesktopUpdateChannel("0.0.40-infinitus.20260910.7")).toBe("infinitus");
    expect(resolveDefaultDesktopUpdateChannel("0.0.40")).toBe("infinitus");
    expect(resolveDefaultDesktopUpdateChannel("0.0.40-nightly.20260910.7")).toBe("nightly");
  });

  it("calls everything but an upstream nightly an Infinitus build", () => {
    expect(isInfinitusDesktopVersion("0.5.0-alpha.1")).toBe(true);
    expect(isInfinitusDesktopVersion("0.0.40-infinitus.20260910.7")).toBe(true);
    expect(isInfinitusDesktopVersion("0.0.40-alpha.2")).toBe(true);
    expect(isInfinitusDesktopVersion("0.0.40-nightly.20260910.7")).toBe(false);
  });
});

describe("resolveEffectiveDesktopUpdateChannel", () => {
  it("keeps an Infinitus build off the stable channel a previous build persisted", () => {
    expect(resolveEffectiveDesktopUpdateChannel("0.0.40-infinitus.20260910.7", "latest")).toBe(
      "infinitus",
    );
  });

  it("leaves every other stored channel alone", () => {
    expect(resolveEffectiveDesktopUpdateChannel("0.0.40-infinitus.20260910.7", "nightly")).toBe(
      "nightly",
    );
    expect(resolveEffectiveDesktopUpdateChannel("0.0.40-infinitus.20260910.7", "infinitus")).toBe(
      "infinitus",
    );
    expect(resolveEffectiveDesktopUpdateChannel("0.5.0-alpha.1", "latest")).toBe("infinitus");
    expect(resolveEffectiveDesktopUpdateChannel("0.0.40-nightly.20260910.7", "latest")).toBe(
      "latest",
    );
  });
});

describe("resolveElectronUpdaterFeed", () => {
  // #924: electron-updater's GitHub provider takes a release only when the
  // tag's prerelease id equals the channel it was told, and names the
  // manifest after that id. So the channel it is told is the version's own
  // prerelease id, never the track's name.
  it("tells electron-updater the version's prerelease id on the infinitus track", () => {
    expect(resolveElectronUpdaterFeed("0.5.0-alpha.1", "infinitus")).toEqual({
      channel: "alpha",
      allowPrerelease: true,
      allowDowngrade: false,
    });
    expect(resolveElectronUpdaterFeed("0.6.0-beta.2", "infinitus")).toEqual({
      channel: "beta",
      allowPrerelease: true,
      allowDowngrade: false,
    });
    expect(resolveElectronUpdaterFeed("0.0.40-infinitus.20260911.23", "infinitus")).toEqual({
      channel: "infinitus",
      allowPrerelease: true,
      allowDowngrade: false,
    });
  });

  it("reads the stable feed for a plain version", () => {
    expect(resolveElectronUpdaterFeed("0.5.0", "infinitus")).toEqual({
      channel: "latest",
      allowPrerelease: false,
      allowDowngrade: false,
    });
  });

  it("keeps upstream's channels as they are", () => {
    expect(resolveElectronUpdaterFeed("0.0.40-nightly.20260911.7", "nightly")).toEqual({
      channel: "nightly",
      allowPrerelease: true,
      allowDowngrade: true,
    });
    expect(resolveElectronUpdaterFeed("0.0.40", "latest")).toEqual({
      channel: "latest",
      allowPrerelease: false,
      allowDowngrade: false,
    });
  });
});
