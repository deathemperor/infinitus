import { describe, expect, it } from "vite-plus/test";

import {
  isInfinitusDesktopVersion,
  resolveDefaultDesktopUpdateChannel,
  resolveEffectiveDesktopUpdateChannel,
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
