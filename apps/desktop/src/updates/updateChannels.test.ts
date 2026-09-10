import { describe, expect, it } from "vite-plus/test";

import {
  isInfinitusDesktopVersion,
  resolveDefaultDesktopUpdateChannel,
  resolveEffectiveDesktopUpdateChannel,
} from "./updateChannels.ts";

describe("resolveDefaultDesktopUpdateChannel", () => {
  it("gives each build its own channel", () => {
    expect(resolveDefaultDesktopUpdateChannel("0.0.40")).toBe("latest");
    expect(resolveDefaultDesktopUpdateChannel("0.0.40-nightly.20260910.7")).toBe("nightly");
    expect(resolveDefaultDesktopUpdateChannel("0.0.40-infinitus.20260910.7")).toBe("infinitus");
  });

  it("only treats a dated, numbered suffix as an Infinitus build", () => {
    expect(isInfinitusDesktopVersion("0.0.40-infinitus.20260910.7")).toBe(true);
    expect(isInfinitusDesktopVersion("0.0.40-infinitus.7")).toBe(false);
    expect(isInfinitusDesktopVersion("0.0.40-alpha.2")).toBe(false);
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
    expect(resolveEffectiveDesktopUpdateChannel("0.0.40", "latest")).toBe("latest");
    expect(resolveEffectiveDesktopUpdateChannel("0.0.40-nightly.20260910.7", "latest")).toBe(
      "latest",
    );
  });
});
