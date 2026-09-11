// @effect-diagnostics nodeBuiltinImport:off -- A guard test scanning this app's own source files, not runtime code.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import { describe, expect, it } from "vite-plus/test";

/**
 * Every "T3 Code" a user reads in apps/web goes through `PRODUCT_NAME`
 * (INFINITUS.md, #601). Comments are free to say it; a string that still does
 * is either on this list, with its reason, or a regression.
 */
const LITERAL_ALLOWED: ReadonlyArray<readonly [file: string, text: string]> = [
  // Copied standalone into a bare temp root by bundledDev.test, so it cannot
  // import the constant; vite.config's productNamePlugin rewrites it at build.
  ["lib/bootError.ts", "T3 Code failed to start."],
  ["lib/bootError.ts", "T3 Code could not load."],
];

const SRC = NodeURL.fileURLToPath(new URL(".", import.meta.url));

function sourceFiles(dir: string): string[] {
  return NodeFS.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = NodePath.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "test" ? [] : sourceFiles(full);
    return /\.tsx?$/.test(entry.name) && !entry.name.includes(".test.") ? [full] : [];
  });
}

function withoutComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
}

describe("product name", () => {
  it("routes every user-facing T3 Code through PRODUCT_NAME", () => {
    const leftovers = sourceFiles(SRC).flatMap((file) => {
      const relative = NodePath.relative(SRC, file);
      return withoutComments(NodeFS.readFileSync(file, "utf8"))
        .split("\n")
        .filter((line) => line.includes("T3 Code"))
        .filter(
          (line) => !LITERAL_ALLOWED.some(([f, text]) => relative === f && line.includes(text)),
        )
        .map((line) => `${relative}: ${line.trim()}`);
    });
    expect(leftovers).toEqual([]);
  });
});
