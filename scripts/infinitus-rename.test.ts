// @effect-diagnostics nodeBuiltinImport:off -- A guard test reading the repository's own files, not runtime code.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import { describe, expect, it } from "vite-plus/test";

import {
  applyRenames,
  FILE_RENAMES,
  isCandidate,
  remainingRenames,
  RENAMES,
} from "./infinitus-rename.ts";

const REPO = NodeURL.fileURLToPath(new URL("..", import.meta.url));

/** One line per table entry, each carrying its old name at least once. */
const SAMPLE = [
  'import { PRODUCT_NAME } from "@t3tools/shared/productName";',
  "  --t3-primary: oklch(0.488 0.217 264); color: var(--t3-primary-foreground);",
  '<span className="font-t3-mono text-sm">',
  "import { T3Wordmark } from './T3Wordmark';",
  "import { useT3ConnectAuthPrompt } from './useT3ConnectAuthPrompt'; <T3ConnectSidebarSignIn />",
  "return <ConfiguredT3ConnectSidebarAvatar />;",
  "  implementation project(':t3tools-mobile-markdown-text')",
].join("\n");

describe("infinitus-rename", () => {
  it("renames every entry of the table", () => {
    const out = applyRenames(SAMPLE);
    expect(out).toContain('"@infinitus/shared/productName"');
    expect(out).toContain("--infinitus-primary:");
    expect(out).toContain("var(--infinitus-primary-foreground)");
    expect(out).toContain("font-infinitus-mono");
    expect(out).toContain("InfinitusWordmark");
    expect(out).toContain("useInfinitusConnectAuthPrompt");
    expect(out).toContain("<InfinitusConnectSidebarSignIn />");
    expect(out).toContain("<ConfiguredInfinitusConnectSidebarAvatar />");
    expect(out).toContain("project(':infinitus-mobile-markdown-text')");
    expect(remainingRenames(out)).toEqual([]);
  });

  it("is idempotent: a second pass changes nothing", () => {
    const once = applyRenames(SAMPLE);
    expect(applyRenames(once)).toBe(once);
  });

  it("never lets one entry's output feed another's pattern", () => {
    // Each replacement, with its capture groups filled by a plausible value,
    // must match no pattern in the table — including its own.
    for (const rename of RENAMES) {
      const produced = rename.replacement.replace(/\$1/g, "Wordmark").replace(/\$\d/g, "X");
      for (const other of RENAMES) {
        other.pattern.lastIndex = 0;
        expect(other.pattern.test(`${produced}Sample`), `${rename.what} → ${other.what}`).toBe(
          false,
        );
      }
    }
  });

  it("rewrites the product name in the user guides, and nowhere else", () => {
    const guide = [
      "Press the shortcut and T3 Code attaches the image. Import a T3 Code theme.",
      "T3 checks the SDK; only T3-managed worktrees qualify. Sign in to T3 Connect.",
      "There is no npm package: `npx t3` installs upstream's T3 Code, not Infinitus.",
      "Set `T3CODE_TELEMETRY_ENABLED=false`; state lives in `~/.t3/userdata`. © T3 Tools, Inc.",
      "Agents drive the device through the command line. T3",
      "Code installs it on demand, and a",
      "T3 Code theme follows.",
    ].join("\n");
    const out = applyRenames(guide, "docs/user/telemetry.md");
    expect(out).toBe(
      [
        "Press the shortcut and Infinitus attaches the image. Import an Infinitus theme.",
        "Infinitus checks the SDK; only Infinitus-managed worktrees qualify. Sign in to Infinitus Connect.",
        "There is no npm package: `npx t3` installs upstream's T3 Code, not Infinitus.",
        "Set `T3CODE_TELEMETRY_ENABLED=false`; state lives in `~/.t3/userdata`. © T3 Tools, Inc.",
        "Agents drive the device through the command line. Infinitus",
        "installs it on demand, and an",
        "Infinitus theme follows.",
      ].join("\n"),
    );
    expect(applyRenames(out, "docs/user/telemetry.md")).toBe(out);
    expect(remainingRenames(out, "docs/user/telemetry.md")).toEqual([]);
    expect(applyRenames(guide, "docs/internals/glossary.md")).toBe(guide);
    expect(remainingRenames(guide, "docs/internals/glossary.md")).toEqual([]);
  });

  it("leaves the compat-read identifiers alone", () => {
    // The names a user's disk, a shipped build or an external service holds
    // (#1368's checklist) are not the table's to rewrite.
    const untouched = [
      'Config.string("T3CODE_HOME")',
      'localStorage.getItem("t3code:ui-state:v1")',
      'const DATABASE_NAME = "t3code:connection-runtime";',
      '{ "t3-code": { command: "npx", args: ["t3", "mcp"] } }',
      "com.t3tools.t3code.service",
      "t3-1.2.3-linux-x64.tar.gz",
      "t3-env:env-1",
      "t3-relay-dpop-access+jwt",
      "/.well-known/t3/environment",
      'scheme: "t3code"',
      'const T3_PROJECT_FILE_NAME = "infinitus.json";',
      "T3ProjectFile",
      "t3-chat-dark",
      '>()("t3/serverSettings/ServerSettingsService") {} // deterministicKeys: the package name',
      '<Image assetName="T3Mark" /> // T3\'s artwork, kept for the upstream variants',
    ].join("\n");
    expect(applyRenames(untouched)).toBe(untouched);
  });

  it("names files that exist, and moves them to a name their identifier rule produces", () => {
    for (const [from, to] of FILE_RENAMES) {
      expect(NodeFS.existsSync(NodePath.join(REPO, to)), to).toBe(true);
      expect(applyRenames(from)).toBe(to);
    }
  });

  it("skips vendored references, and rewrites the native modules' package names", () => {
    expect(isCandidate(".repos/effect-smol/README.md")).toBe(false);
    expect(isCandidate("apps/mobile/modules/t3-markdown-text/package.json")).toBe(true);
    expect(isCandidate("apps/web/src/components/InfinitusWordmark.tsx")).toBe(true);
    expect(isCandidate("pnpm-lock.yaml")).toBe(true);
    expect(isCandidate("apps/mobile/modules/t3-composer-editor/android/build.gradle")).toBe(true);
    expect(isCandidate("assets/icon.png")).toBe(false);
  });
});
