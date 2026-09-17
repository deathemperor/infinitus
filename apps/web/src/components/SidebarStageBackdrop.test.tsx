import { describe, expect, it } from "vite-plus/test";
import { renderToStaticMarkup } from "react-dom/server";

import { STAGE_ART_SCENES } from "../themePalette";
import {
  resolveEnvironmentIdentificationPillLabel,
  resolveSidebarStageBackdropVariant,
  StageBackdropArt,
} from "./SidebarStageBackdrop";

describe("SidebarStageBackdrop", () => {
  it("resolves stage artwork only when enabled", () => {
    expect(resolveSidebarStageBackdropVariant("Dev")).toBe("dev");
    expect(resolveSidebarStageBackdropVariant("Nightly")).toBe("nightly");
    expect(resolveSidebarStageBackdropVariant("Dev", false)).toBeNull();
    // Fork: the release track draws the night sky; only an unknown stage is bare.
    expect(resolveSidebarStageBackdropVariant("Alpha")).toBe("nightly");
    expect(resolveSidebarStageBackdropVariant("Latest")).toBeNull();
  });

  it("lets a theme's scene replace the stage default", () => {
    expect(resolveSidebarStageBackdropVariant("Alpha", true, "nebula")).toBe("nebula");
    expect(resolveSidebarStageBackdropVariant("Nightly", true, "tide")).toBe("tide");
    // A theme's scene overrides the blueprint too, so dev builds are themed.
    expect(resolveSidebarStageBackdropVariant("Dev", true, "dawn")).toBe("dawn");
    // The stage still decides whether any artwork draws.
    expect(resolveSidebarStageBackdropVariant("Latest", true, "nebula")).toBeNull();
    expect(resolveSidebarStageBackdropVariant("Alpha", false, "nebula")).toBeNull();
  });

  it("resolves supported environment pill labels", () => {
    expect(resolveEnvironmentIdentificationPillLabel("Dev")).toBe("Dev");
    expect(resolveEnvironmentIdentificationPillLabel("nightly")).toBe("Nightly");
    expect(resolveEnvironmentIdentificationPillLabel("Latest")).toBeNull();
    expect(resolveEnvironmentIdentificationPillLabel("Alpha")).toBe("Alpha");
  });

  it.each(STAGE_ART_SCENES)(
    "uses unique SVG definition ids when %s artwork is rendered more than once",
    (variant) => {
      const markup = renderToStaticMarkup(
        <>
          <StageBackdropArt variant={variant} />
          <StageBackdropArt variant={variant} />
        </>,
      );
      const ids = Array.from(markup.matchAll(/\sid="([^"]+)"/g), (match) => match[1]);

      expect(ids.length).toBeGreaterThan(0);
      expect(new Set(ids).size).toBe(ids.length);
    },
  );
});
