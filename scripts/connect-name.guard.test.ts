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
/** Lines that keep a bare "T3", with the reason. */
const LITERAL_ALLOWED: ReadonlyArray<readonly [file: string, text: string]> = [
  // The wordmark glyph itself (the work log's own-step icon keeps it, #601).
  ["apps/mobile/src/components/InfinitusWordmark.tsx", 'accessibilityLabel="T3"'],
  // A column default in the relay's live database; changing it is a migration.
  ["infra/relay/src/persistence/schema.ts", '.default("T3 Environment")'],
  // Byte-identical to upstream's `.github/triage/PLAYBOOK.md` (its test), which
  // upstream's own triage workflow reads; it names upstream's issue tracker.
  ["apps/server/src/cli/triagePrompt.ts", "T3 Code"],
  // The upstream attribution constants themselves: the licenses screens credit
  // the project this fork is built on, so these two must hold the real upstream
  // names. Every surface reads them instead of writing the literal, which is
  // what this guard is enforcing.
  ["packages/contracts/src/productName.ts", 'UPSTREAM_PRODUCT_NAME = "T3 Code"'],
  ["packages/contracts/src/productName.ts", 'UPSTREAM_PUBLISHER_NAME = "T3 Tools, Inc."'],
];

const ROOTS = [
  "apps/server/src",
  "apps/mobile/src",
  "packages/contracts/src",
  "packages/shared/src",
  "packages/client-runtime/src",
  "packages/ssh/src",
  "infra/relay/src",
];

/** A bare "T3" used as the product noun ("T3 Account", "Open T3"), #1368.
    Identifiers (`T3CODE_HOME`, `T3_THREAD_ID`, `t3code`) never match. */
const BARE_T3 = /\bT3\b(?![_A-Za-z0-9])/;

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
  it("routes every user-facing T3 Connect and bare T3 through the name constants", () => {
    const leftovers = ROOTS.flatMap((root) =>
      sourceFiles(NodePath.join(REPO, root)).flatMap((file) =>
        withoutComments(NodeFS.readFileSync(file, "utf8"))
          .split("\n")
          .filter((line) => line.includes("T3 Connect") || BARE_T3.test(line))
          .filter(
            (line) =>
              !LITERAL_ALLOWED.some(
                ([f, text]) => NodePath.relative(REPO, file) === f && line.includes(text),
              ),
          )
          .map((line) => `${NodePath.relative(REPO, file)}: ${line.trim()}`),
      ),
    );
    expect(leftovers).toEqual([]);
  });
});
