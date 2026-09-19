#!/usr/bin/env node

// Renders the Infinitus phone's splash artwork (fork). Run: `node scripts/export-infinitus-splash.ts`.
//
// The app icon is an opaque square (App Store icons carry no alpha), so shown
// as-is on the splash it sits as a hard-edged tile. iOS gets the icon under the
// home screen's rounded silhouette; Android 12+ masks its splash icon to a
// circle over the central two thirds of a 288dp canvas, so its image is the
// icon's gradient with the twin-loop mark kept inside that circle.

import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import sharp from "sharp";

const ASSETS_DIRECTORY = "apps/mobile/assets";
const ICON = "infinitus-ios-1024.png";
const IOS_SIZE = 1024;
// iOS's icon silhouette: corner radius ≈ 22.37% of the edge.
const IOS_CORNER_RADIUS = 229;
// 288dp at xxxhdpi, the full Android 12+ splash canvas.
const ANDROID_SIZE = 1152;
// Mark width as a fraction of the canvas: the mask circle's diameter is 2/3,
// and this keeps the 3:2 glyph's corners well inside it.
const ANDROID_MARK_FRACTION = 0.4;

class SplashRenderError extends Schema.TaggedError<SplashRenderError>()("SplashRenderError", {
  layer: Schema.String,
  cause: Schema.Defect(),
}) {}

const svg = (size: number, inner: string) =>
  Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">${inner}</svg>`,
  );

const render = (layer: string, run: () => Promise<Buffer>) =>
  Effect.tryPromise({ try: run, catch: (cause) => new SplashRenderError({ layer, cause }) });

const renderIos = (icon: string) =>
  render("ios-splash", () =>
    sharp(icon)
      .ensureAlpha()
      .composite([
        {
          input: svg(
            IOS_SIZE,
            `<rect width="${IOS_SIZE}" height="${IOS_SIZE}" rx="${IOS_CORNER_RADIUS}" fill="#fff"/>`,
          ),
          blend: "dest-in",
        },
      ])
      .png()
      .toBuffer(),
  );

// The icon's own gradient (sampled top-left, middle, bottom-right) with its
// glow behind the mark. The icon itself is not reused: its mark spans 60% of
// the canvas and the arrow would leave the mask circle.
const ANDROID_BACKGROUND = svg(
  ANDROID_SIZE,
  `<defs>
    <linearGradient id="l" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#3362e1"/><stop offset="0.5" stop-color="#2446a1"/><stop offset="1" stop-color="#091433"/>
    </linearGradient>
    <radialGradient id="r">
      <stop offset="0" stop-color="#8fb0e6" stop-opacity="0.55"/><stop offset="1" stop-color="#8fb0e6" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="${ANDROID_SIZE}" height="${ANDROID_SIZE}" fill="url(#l)"/>
  <circle cx="${ANDROID_SIZE / 2}" cy="${ANDROID_SIZE / 2}" r="${ANDROID_SIZE * 0.36}" fill="url(#r)"/>`,
);

const renderAndroid = (markSvg: string) =>
  render("android-splash", async () => {
    const mark = await sharp(Buffer.from(markSvg.replaceAll('fill="black"', 'fill="white"')), {
      density: 300,
    })
      .resize({ width: Math.round(ANDROID_SIZE * ANDROID_MARK_FRACTION) })
      .png()
      .toBuffer();
    return sharp(ANDROID_BACKGROUND)
      .composite([{ input: mark, gravity: "centre" }])
      .png()
      .toBuffer();
  });

const exportInfinitusSplash = Effect.gen(function* () {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const assets = path.resolve(import.meta.dirname, "..", ASSETS_DIRECTORY);
  const markSvg = yield* fs.readFileString(path.join(assets, "widget", "InfinitusMark.svg"));
  const outputs = [
    ["infinitus-splash-1024.png", yield* renderIos(path.join(assets, ICON))],
    ["android-splash-icon-infinitus.png", yield* renderAndroid(markSvg)],
  ] as const;
  for (const [name, contents] of outputs) {
    yield* fs.writeFile(path.join(assets, name), contents);
    yield* Console.log(`wrote ${ASSETS_DIRECTORY}/${name}`);
  }
});

if (import.meta.main) {
  exportInfinitusSplash.pipe(Effect.provide(NodeServices.layer), NodeRuntime.runMain);
}
