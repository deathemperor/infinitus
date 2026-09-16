// @effect-diagnostics nodeBuiltinImport:off -- A guard test scanning the repository's source files, not runtime code.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import { describe, expect, it } from "vite-plus/test";

/**
 * The relay feature is `CONNECT_NAME` ("Infinitus Connect") on every surface
 * (#1368 slice A). The web and desktop `productName.guard.test.ts` cover
 * their own trees; this one covers the server, the phone, the shared
 * packages and the relay, where no product-name guard existed. Comments are
 * free to say "T3 Connect"; a string that still does is a regression.
 */
const ROOTS = [
  "apps/server/src",
  "apps/mobile/src",
  "packages/contracts/src",
  "packages/shared/src",
  "packages/client-runtime/src",
  "packages/ssh/src",
  "infra/relay/src",
];

const REPO = NodeURL.fileURLToPath(new URL("..", import.meta.url));

function sourceFiles(dir: string): string[] {
  if (!NodeFS.existsSync(dir)) return [];
  return NodeFS.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = NodePath.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "test" ? [] : sourceFiles(full);
    return /\.tsx?$/.test(entry.name) && !entry.name.includes(".test.") ? [full] : [];
  });
}

function withoutComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
}

describe("connect name", () => {
  it("routes every user-facing T3 Connect through CONNECT_NAME", () => {
    const leftovers = ROOTS.flatMap((root) =>
      sourceFiles(NodePath.join(REPO, root)).flatMap((file) =>
        withoutComments(NodeFS.readFileSync(file, "utf8"))
          .split("\n")
          .filter((line) => line.includes("T3 Connect"))
          .map((line) => `${NodePath.relative(REPO, file)}: ${line.trim()}`),
      ),
    );
    expect(leftovers).toEqual([]);
  });
});
