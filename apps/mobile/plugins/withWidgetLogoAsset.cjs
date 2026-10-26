"use strict";

// Precede expo-widgets so its reverse-ordered mods create and wipe the target before assets are added.

const path = require("path");
const fs = require("fs");
const { withDangerousMod, withXcodeProject } = require("expo/config-plugins");
const { addWidgetAssetCatalog } = require("./lib/addWidgetAssetCatalog.cjs");

const TARGET_NAME = "ExpoWidgetsTarget";
const CATALOG_NAME = "Assets.xcassets";
const IMAGE_SET = "T3Mark.imageset";
const SVG_NAME = "T3Mark.svg";

// The fork's builds carry the Infinitus twin loop, the upstream variants the
// T3 mark — they build the real T3 Code side by side. Only the artwork copied
// in changes: the catalog entry keeps the name AgentActivity.tsx asks for, and
// both marks are drawn at the 3:2 the widget frames them at, so neither is
// stretched and the widget file stays upstream's.
const SOURCE_BY_VARIANT = { infinitus: "InfinitusMark.svg" };

const CATALOG_CONTENTS = JSON.stringify({ info: { author: "expo", version: 1 } }, null, 2) + "\n";
const IMAGE_SET_CONTENTS =
  JSON.stringify(
    {
      images: [{ idiom: "universal", filename: SVG_NAME }],
      info: { author: "expo", version: 1 },
      properties: {
        "preserves-vector-representation": true,
        "template-rendering-intent": "template",
      },
    },
    null,
    2,
  ) + "\n";

function withAssetFiles(config) {
  return withDangerousMod(config, [
    "ios",
    (cfg) => {
      const sourceName = SOURCE_BY_VARIANT[cfg.extra?.appVariant] ?? SVG_NAME;
      const source = path.join(cfg.modRequest.projectRoot, "assets", "widget", sourceName);
      const catalogDir = path.join(cfg.modRequest.platformProjectRoot, TARGET_NAME, CATALOG_NAME);
      const imageSetDir = path.join(catalogDir, IMAGE_SET);
      fs.mkdirSync(imageSetDir, { recursive: true });
      fs.writeFileSync(path.join(catalogDir, "Contents.json"), CATALOG_CONTENTS);
      fs.writeFileSync(path.join(imageSetDir, "Contents.json"), IMAGE_SET_CONTENTS);
      fs.copyFileSync(source, path.join(imageSetDir, SVG_NAME));
      return cfg;
    },
  ]);
}

function withAssetWiring(config) {
  return withXcodeProject(config, (cfg) => {
    addWidgetAssetCatalog(cfg.modResults, { targetName: TARGET_NAME });
    return cfg;
  });
}

module.exports = function withWidgetLogoAsset(config) {
  return withAssetWiring(withAssetFiles(config));
};
