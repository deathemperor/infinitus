import { describe, expect, it } from "vite-plus/test";

import {
  isInfinitusDesktopVersion,
  isNightlyDesktopVersion,
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

  // The four shapes a version takes (#1042): a plain one, the line's
  // prerelease, this repo's nightly, an upstream nightly. Only the first
  // prerelease id decides — the repo's nightly carries `-nightly.` too.
  it.each([
    ["0.5.0", "infinitus"],
    ["0.5.0-alpha.7", "infinitus"],
    ["0.5.0-alpha.7-infinitus-nightly.20260913.42", "infinitus-nightly"],
    ["0.5.0-infinitus-nightly.20260913.42", "infinitus-nightly"],
    ["0.0.41-nightly.20260913.1", "nightly"],
  ] as const)("defaults %s to the %s track", (version, channel) => {
    expect(resolveDefaultDesktopUpdateChannel(version)).toBe(channel);
  });

  it("calls everything but an upstream nightly an Infinitus build", () => {
    expect(isInfinitusDesktopVersion("0.5.0-alpha.1")).toBe(true);
    expect(isInfinitusDesktopVersion("0.0.40-infinitus.20260910.7")).toBe(true);
    expect(isInfinitusDesktopVersion("0.0.40-alpha.2")).toBe(true);
    expect(isInfinitusDesktopVersion("0.0.40-nightly.20260910.7")).toBe(false);
    expect(isInfinitusDesktopVersion("0.5.0-alpha.7-infinitus-nightly.20260913.42")).toBe(true);
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

  it("reads the rolling nightly release on the infinitus-nightly track (#1042)", () => {
    // The generic provider at releases/download/nightly: the manifest is
    // `infinitus-nightly-mac.yml` whatever the version, downgrades on.
    expect(
      resolveElectronUpdaterFeed(
        "0.5.0-alpha.7-infinitus-nightly.20260913.42",
        "infinitus-nightly",
      ),
    ).toEqual({ channel: "infinitus-nightly", allowPrerelease: true, allowDowngrade: true });
    expect(resolveElectronUpdaterFeed("0.5.0-alpha.7", "infinitus-nightly")).toEqual({
      channel: "infinitus-nightly",
      allowPrerelease: true,
      allowDowngrade: true,
    });
  });

  it("lets a nightly build go back to its line's release, which semver ranks lower", () => {
    expect(
      resolveElectronUpdaterFeed("0.5.0-alpha.7-infinitus-nightly.20260913.42", "infinitus"),
    ).toEqual({ channel: "alpha", allowPrerelease: true, allowDowngrade: true });
    expect(resolveElectronUpdaterFeed("0.5.0-infinitus-nightly.20260913.42", "infinitus")).toEqual({
      channel: "latest",
      allowPrerelease: false,
      allowDowngrade: true,
    });
  });

  // Upstream's preview train (#11372), merged in: a preview brands as a
  // nightly but follows no feed, so upstream defaults it to `latest`. Here it
  // defaults to `infinitus` instead — this repo never defaults to `latest`,
  // upstream's stable channel — and the strict nightly check keeps an
  // upstream preview off the nightly track all the same.
  it("brands an upstream preview as a nightly without putting it on that track", () => {
    expect(isNightlyDesktopVersion("0.0.41-preview.20260911.7")).toBe(true);
    expect(resolveDefaultDesktopUpdateChannel("0.0.41-preview.20260911.7")).toBe("infinitus");
    expect(resolveDefaultDesktopUpdateChannel("0.0.41-nightly.20260911.7")).toBe("nightly");
  });

  // The fork reached upstream's rule independently (#924): the id has to be
  // the FIRST one, or this repo's own `…-alpha.7-infinitus-nightly.…` would
  // read as an upstream build.
  it("only matches the first prerelease identifier", () => {
    expect(isNightlyDesktopVersion("1.2.3-foo-preview.20260911.1")).toBe(false);
    expect(isNightlyDesktopVersion("1.2.3")).toBe(false);
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
