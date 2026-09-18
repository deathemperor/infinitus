import { describe, expect, it } from "vite-plus/test";

import { resolveMobileBrandMarkVariant, resolveMobileStageLabel } from "./mobileBranding";

describe("resolveMobileBrandMarkVariant", () => {
  it("draws the fork's own mark for the infinitus build", () => {
    // Regression: this fell through to "prod" — upstream's T3 mark — which put
    // the T3 logo beside the Infinitus wordmark on every loading screen.
    expect(resolveMobileBrandMarkVariant("infinitus")).toBe("infinitus");
  });

  it.each([
    ["development", "development"],
    ["preview", "preview"],
    ["production", "prod"],
  ])("keeps upstream's mark for the %s build", (appVariant, expected) => {
    expect(resolveMobileBrandMarkVariant(appVariant)).toBe(expected);
  });

  it.each([undefined, null, "", "unknown"])(
    "falls back to the production mark for %s",
    (appVariant) => {
      expect(resolveMobileBrandMarkVariant(appVariant)).toBe("prod");
    },
  );
});

describe("resolveMobileStageLabel", () => {
  it.each([
    ["infinitus", "Alpha"],
    ["production", "Alpha"],
    ["development", "Dev"],
    ["preview", "Nightly"],
    [undefined, "Alpha"],
  ])("labels the %s build %s", (appVariant, expected) => {
    expect(resolveMobileStageLabel(appVariant)).toBe(expected);
  });
});
