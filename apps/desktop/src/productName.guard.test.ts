// @effect-diagnostics nodeBuiltinImport:off -- A guard test scanning this app's own source files, not runtime code.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import { assert, describe, it } from "@effect/vitest";

/**
 * Every "T3 Code" a user reads in apps/desktop goes through `PRODUCT_NAME`
 * (INFINITUS.md, #601). Comments are free to say it; a string that still does
 * is either on this list, with its reason, or a regression.
 */
const LITERAL_ALLOWED: ReadonlyArray<readonly [file: string, text: string]> = [
  // The installed upstream app's real userData directories, which the fork
  // must recognise and never adopt.
  ["app/DesktopEnvironment.ts", '"T3 Code (Dev)" : "T3 Code (Alpha)"'],
];

const SRC = NodeURL.fileURLToPath(new URL(".", import.meta.url));

function sourceFiles(dir: string): string[] {
  return NodeFS.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = NodePath.join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(full);
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
    assert.deepEqual(leftovers, []);
  });
});
