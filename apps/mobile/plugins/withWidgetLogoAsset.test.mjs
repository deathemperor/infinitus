import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import withWidgetLogoAsset from "./withWidgetLogoAsset.cjs";

const projectRoot = NodePath.resolve(import.meta.dirname, "..");
const temporaries = [];

afterEach(() => {
  for (const dir of temporaries.splice(0)) NodeFS.rmSync(dir, { recursive: true, force: true });
});

/** Runs the plugin's dangerous mod into a throwaway ios/ directory. */
async function prebuild(appVariant) {
  const platformProjectRoot = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "widget-logo-"));
  temporaries.push(platformProjectRoot);
  const config = withWidgetLogoAsset({
    name: "Test",
    slug: "test",
    ...(appVariant === undefined ? {} : { extra: { appVariant } }),
  });
  await config.mods.ios.dangerous({
    ...config,
    modRequest: { platform: "ios", modName: "dangerous", projectRoot, platformProjectRoot },
    modResults: {},
  });
  return NodeFS.readFileSync(
    NodePath.join(
      platformProjectRoot,
      "ExpoWidgetsTarget",
      "Assets.xcassets",
      "T3Mark.imageset",
      "T3Mark.svg",
    ),
    "utf8",
  );
}

const aspectOf = (svg) => {
  const [, , width, height] = /viewBox="([^"]+)"/.exec(svg)[1].split(/\s+/).map(Number);
  return width / height;
};

describe("the widget's brand mark", () => {
  it("ships the Infinitus mark on the fork's build", async () => {
    const svg = await prebuild("infinitus");
    expect(svg).toBe(
      NodeFS.readFileSync(
        NodePath.join(projectRoot, "assets", "widget", "InfinitusMark.svg"),
        "utf8",
      ),
    );
  });

  it("leaves the upstream variants the T3 mark — they build the real T3 Code", async () => {
    for (const variant of ["development", "preview", "production", undefined]) {
      expect(await prebuild(variant)).toBe(
        NodeFS.readFileSync(NodePath.join(projectRoot, "assets", "widget", "T3Mark.svg"), "utf8"),
      );
    }
  });

  it("draws both marks at the 3:2 the widget frames them at, so neither is stretched", async () => {
    expect(aspectOf(await prebuild("infinitus"))).toBeCloseTo(1.5, 4);
    expect(aspectOf(await prebuild("production"))).toBeCloseTo(1.5, 4);
  });
});
