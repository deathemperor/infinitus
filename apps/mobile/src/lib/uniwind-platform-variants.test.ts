import { describe, expect, it, vi } from "vite-plus/test";
import * as NodeURL from "node:url";

// uniwind's sources import through its own `@/` alias, which this workspace
// does not resolve; the two modules the CSS processor pulls in are small.
vi.mock("@/common/consts", () => ({
  Platform: {
    Android: "android",
    iOS: "ios",
    Web: "web",
    Native: "native",
    TV: "tv",
    AndroidTV: "android-tv",
    AppleTV: "apple-tv",
  },
  UNIWIND_PLATFORM_VARIABLES: "__uniwind-platform-",
  UNIWIND_THEME_VARIABLES: "__uniwind-theme-",
  StyleDependency: { Variables: 9 },
  Orientation: { Portrait: "portrait", Landscape: "landscape" },
  ColorScheme: { Light: "light", Dark: "dark" },
}));
vi.mock("@/common/utils", () => ({
  isDefined: (value: unknown) => value !== undefined && value !== null,
  arrayEquals: (a: Array<unknown>, b: Array<unknown>) =>
    a.length === b.length && a.every((v, i) => v === b[i]),
}));

const loadProcessor = async () => {
  const modulePath = NodeURL.fileURLToPath(
    new URL("../../node_modules/uniwind/src/bundler/css-processor/processor.ts", import.meta.url),
  );
  const { ProcessorBuilder } = (await import(/* @vite-ignore */ modulePath)) as {
    ProcessorBuilder: new (config: { themes: Array<string> }) => {
      transform(css: string): void;
      stylesheets: Record<string, Array<{ platform: string | null }>>;
    };
  };
  return new ProcessorBuilder({ themes: ["light", "dark"] });
};

// The repo's uniwind patch (patches/uniwind@1.11.0.patch): Tailwind puts every
// `android:` utility into one `@media android` block, and uniwind reset its
// per-rule config after each child, so only the block's first rule kept the
// platform and the rest applied on iOS too. The Settings cards vanished that
// way (`android:bg-transparent` on the section card).
describe("uniwind platform variants (patched)", () => {
  it("keeps the platform on every rule of a media block", async () => {
    const processor = await loadProcessor();
    processor.transform(`
      @media android {
        .android\\:min-h-14 { min-height: 56px; }
        .android\\:bg-transparent { background-color: transparent; }
      }
      @media ios {
        .ios\\:pt-\\[72px\\] { padding-top: 72px; }
      }
      .bg-card { background-color: red; }
    `);
    const platformOf = (className: string) => processor.stylesheets[className]?.[0]?.platform;
    expect(platformOf("android:min-h-14")).toBe("android");
    expect(platformOf("android:bg-transparent")).toBe("android");
    expect(platformOf("ios:pt-[72px]")).toBe("ios");
    expect(platformOf("bg-card")).toBeNull();
  });
});
