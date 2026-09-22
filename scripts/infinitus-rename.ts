#!/usr/bin/env node
// @effect-diagnostics nodeBuiltinImport:off - A plain CLI rewriting the tree; no Effect runtime here.
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";

/**
 * The identifier codemod (#1368 slice C): every T3 name the fork owns
 * outright becomes an Infinitus one, by one idempotent table, so the
 * rename is a script run and not a hand edit — and so every upstream sync
 * can re-run it. The merge rule that makes this cheap: on each sync,
 * branch from `upstream/main`, run this script THERE, commit, then merge
 * that branch into `main`. Both sides then carry the same names and the
 * merge's conflicts collapse to real changes. Never "take upstream's file
 * and re-run": that drops the fork's registration-point edits in the file.
 * Narrative and the compat-read list: `docs/internals/infinitus-rename.md`.
 *
 * What the table covers is the issue's "safe to rename outright" set:
 * names nothing outside this tree persists or reads. Everything a user's
 * disk, an installed unit, a shipped build or an external service holds
 * (`T3CODE_*` env vars, `t3code:` storage keys, the `t3` binary, the
 * `t3-code` MCP id, service labels, wire formats) is NOT here: those take a
 * legacy read at each site, one slice each (#1368 C–E), never a blind
 * rewrite. Nor are the server's `t3/…` service tags: the Effect language
 * service's `deterministicKeys` rule derives them from the package name,
 * so they rename with `apps/server`'s `t3` package (slice D). `--check` fails while any old name is still in the tree, which
 * is the guard once the rename has landed.
 *
 *   node scripts/infinitus-rename.ts            rewrite and `git mv` in place
 *   node scripts/infinitus-rename.ts --dry-run  list what would change
 *   node scripts/infinitus-rename.ts --check    exit 1 while an old name remains
 */

export interface Rename {
  /** What the entry renames, for the report. */
  readonly what: string;
  readonly pattern: RegExp;
  readonly replacement: string;
  /** Repository-relative path prefix the entry is confined to; everywhere when absent. */
  readonly within?: string;
  /** Prose: a match opening or inside quotes or backticks, or after "real"/"upstream's", is a literal and stays. */
  readonly prose?: true;
}

/**
 * Ordered: an earlier entry's output must never match a later entry's
 * pattern, and no entry's output may match its own — the test checks both,
 * which is what makes a second run a no-op.
 */
export const RENAMES: ReadonlyArray<Rename> = [
  {
    what: "workspace package scope (@t3tools/* → @infinitus/*: names, imports, filters, lockfile)",
    pattern: /@t3tools\//g,
    replacement: "@infinitus/",
  },
  {
    what: "CSS custom properties --t3-* (theme palette, the desktop's preview annotations)",
    pattern: /--t3-(?=[a-z])/g,
    replacement: "--infinitus-",
  },
  {
    what: "Tailwind font utilities font-t3-*",
    pattern: /\bfont-t3-(?=[a-z])/g,
    replacement: "font-infinitus-",
  },
  {
    what: "the wordmark component (T3Wordmark)",
    // Not T3Mark: that is T3's own artwork, which the upstream mobile
    // variants keep (`withWidgetLogoAsset.cjs`, #1188).
    pattern: /\bT3Wordmark\b/g,
    replacement: "InfinitusWordmark",
  },
  {
    what: "the Connect surfaces (T3Connect*, useT3ConnectAuthPrompt, Configured…T3Connect*)",
    // No leading \b: the name sits inside compounds (ConfiguredT3ConnectSidebarAvatar).
    pattern: /(use)?T3Connect(?=[A-Z])/g,
    replacement: "$1InfinitusConnect",
  },
  {
    what: "Expo autolinking's gradle project names, derived from the package scope (':t3tools-* → ':infinitus-*)",
    pattern: /':t3tools-/g,
    replacement: "':infinitus-",
  },
  {
    what: "the product name's article in the docs (a T3 Code theme → an Infinitus theme)",
    // Upstream hard-wraps its prose, so the name can straddle a line
    // ("T3\nCode installs"): the break survives, the orphaned "Code " goes.
    // A wrap straight before punctuation ("T3\nCode.") is not handled and
    // leaves a "Code" `--check` cannot see; read the sync's docs diff.
    pattern: /\b([Aa])(\s+)T3(?:[ \t]+Code\b|(\n)Code[ \t])/g,
    replacement: "$1n$2Infinitus$3",
    within: "docs/",
    prose: true,
  },
  {
    what: "the product name in the docs (T3 Code)",
    // Prose, so confined to docs: upstream owns most of those pages and
    // every sync brings its wording back. The literals stay (`prose`): the
    // installed app's `T3 Code (Alpha)`, "Built on T3 Code", "the real T3
    // Code", "upstream's T3 Code" — sentences about the other product.
    pattern: /\bT3(?:[ \t]+Code\b|(\n)Code[ \t])/g,
    replacement: "Infinitus$1",
    within: "docs/",
    prose: true,
  },
  {
    what: "a bare T3's article in the user guides (a T3 theme → an Infinitus theme)",
    pattern: /\b([Aa])(\s+)T3(?! Tools\b)(?![_A-Za-z0-9])/g,
    replacement: "$1n$2Infinitus",
    within: "docs/user/",
    prose: true,
  },
  {
    what: "a bare T3 as the product noun in the user guides",
    // Only the user guides: in docs/internals a bare T3 is as often
    // upstream's (its glyph, mark, Clerk instance) as the product, and the
    // publisher, T3 Tools, Inc., stays everywhere.
    pattern: /\bT3(?! Tools\b)(?![_A-Za-z0-9])/g,
    replacement: "Infinitus",
    within: "docs/user/",
    prose: true,
  },
];

/**
 * Files whose names carry an identifier the table renames; the identifier
 * rule above rewrites the imports, this moves the file. Paths are
 * repository-relative; the test checks each destination exists on `main`
 * (an entry outlives its file otherwise).
 */
export const FILE_RENAMES: ReadonlyArray<readonly [from: string, to: string]> = [
  ["apps/web/src/components/T3Wordmark.tsx", "apps/web/src/components/InfinitusWordmark.tsx"],
  ["apps/mobile/src/components/T3Wordmark.tsx", "apps/mobile/src/components/InfinitusWordmark.tsx"],
  [
    "apps/web/src/components/clerk/T3ConnectSidebarSignIn.tsx",
    "apps/web/src/components/clerk/InfinitusConnectSidebarSignIn.tsx",
  ],
  [
    "apps/web/src/components/clerk/T3ConnectUserProfilePage.tsx",
    "apps/web/src/components/clerk/InfinitusConnectUserProfilePage.tsx",
  ],
  [
    "apps/web/src/components/clerk/T3ConnectUserProfilePage.test.tsx",
    "apps/web/src/components/clerk/InfinitusConnectUserProfilePage.test.tsx",
  ],
  [
    "apps/web/src/components/clerk/useT3ConnectAuthPrompt.tsx",
    "apps/web/src/components/clerk/useInfinitusConnectAuthPrompt.tsx",
  ],
  [
    "apps/mobile/src/features/cloud/T3ConnectProfilePage.tsx",
    "apps/mobile/src/features/cloud/InfinitusConnectProfilePage.tsx",
  ],
];

/**
 * Left alone, by path prefix: vendored references, and this script's own
 * tests and page (they quote the old names). The mobile native modules
 * under `modules/t3-*` keep their directory names (upstream-variant ids)
 * but their package names and imports are `@t3tools/*` like everything
 * else's, so they are rewritten.
 */
export const EXCLUDED_PREFIXES: ReadonlyArray<string> = [
  ".repos/",
  "scripts/infinitus-rename.ts",
  "scripts/infinitus-rename.test.ts",
  "docs/internals/infinitus-rename.md",
];

const TEXT_EXTENSIONS = new Set([
  ".ts",
  ".tsx",
  ".mts",
  ".cts",
  ".js",
  ".mjs",
  ".cjs",
  ".json",
  ".jsonc",
  ".yaml",
  ".yml",
  ".md",
  ".mdx",
  ".css",
  ".html",
  ".svg",
  ".swift",
  ".kt",
  ".sh",
  ".toml",
  ".txt",
  ".gradle",
]);

export function isCandidate(path: string): boolean {
  if (EXCLUDED_PREFIXES.some((prefix) => path.startsWith(prefix))) return false;
  const base = NodePath.basename(path);
  if (base === "pnpm-lock.yaml") return true;
  return TEXT_EXTENSIONS.has(NodePath.extname(base));
}

function appliesTo(rename: Rename, path: string | undefined): boolean {
  return rename.within === undefined || (path?.startsWith(rename.within) ?? false);
}

/** A prose entry's match that is quoted, code-formatted, or named as the other product. */
function isLiteralMention(text: string, offset: number): boolean {
  const before = text.slice(text.lastIndexOf("\n", offset - 1) + 1, offset);
  const odd = (mark: string) => before.split(mark).length % 2 === 0;
  return odd('"') || odd("`") || /["`]$|\b(?:real|upstream's)\s$/.test(before);
}

function skips(rename: Rename, text: string, offset: number): boolean {
  return rename.prose === true && isLiteralMention(text, offset);
}

/** One pass of the table over one file's text; `path` admits the entries confined to it. */
export function applyRenames(text: string, path?: string): string {
  let out = text;
  for (const rename of RENAMES) {
    if (!appliesTo(rename, path)) continue;
    out = out.replace(rename.pattern, (...args: Array<unknown>) => {
      const match = args[0] as string;
      const offset = args.at(-2) as number;
      const groups = args.slice(1, -2) as Array<string | undefined>;
      if (skips(rename, out, offset)) return match;
      return rename.replacement.replace(/\$(\d)/g, (_, n: string) => groups[Number(n) - 1] ?? "");
    });
  }
  return out;
}

/** Which entries still match, for `--check`'s report. */
export function remainingRenames(text: string, path?: string): ReadonlyArray<Rename> {
  return RENAMES.filter(
    (rename) =>
      appliesTo(rename, path) &&
      [...text.matchAll(rename.pattern)].some((m) => !skips(rename, text, m.index)),
  );
}

function trackedFiles(root: string): ReadonlyArray<string> {
  return NodeChildProcess.execFileSync("git", ["ls-files", "-z"], {
    cwd: root,
    maxBuffer: 64 * 1024 * 1024,
  })
    .toString("utf8")
    .split("\0")
    .filter((path) => path.length > 0);
}

export function run(input: {
  readonly root: string;
  readonly mode: "apply" | "dry-run" | "check";
}): { readonly changed: ReadonlyArray<string>; readonly moved: ReadonlyArray<string> } {
  const changed: string[] = [];
  const moved: string[] = [];
  for (const path of trackedFiles(input.root)) {
    if (!isCandidate(path)) continue;
    const absolute = NodePath.join(input.root, path);
    if (!NodeFS.existsSync(absolute)) continue;
    const before = NodeFS.readFileSync(absolute, "utf8");
    if (input.mode === "check") {
      const remaining = remainingRenames(before, path);
      if (remaining.length > 0) {
        changed.push(`${path}: ${remaining.map((rename) => rename.what).join("; ")}`);
      }
      continue;
    }
    const after = applyRenames(before, path);
    if (after === before) continue;
    changed.push(path);
    if (input.mode === "apply") NodeFS.writeFileSync(absolute, after);
  }
  for (const [from, to] of FILE_RENAMES) {
    const exists = NodeFS.existsSync(NodePath.join(input.root, from));
    if (input.mode === "check") {
      if (exists) changed.push(`${from}: file rename pending → ${to}`);
      continue;
    }
    if (!exists) continue;
    moved.push(`${from} → ${to}`);
    if (input.mode === "apply") {
      NodeChildProcess.execFileSync("git", ["mv", from, to], { cwd: input.root });
    }
  }
  return { changed, moved };
}

if (import.meta.main) {
  // The tree the shell stands in, not the script's own: the sync workflow
  // runs a copy of this file from /tmp against upstream's checkout.
  const root = NodeChildProcess.execFileSync("git", ["rev-parse", "--show-toplevel"], {
    cwd: NodeProcess.cwd(),
  })
    .toString("utf8")
    .trim();
  const mode = NodeProcess.argv.includes("--check")
    ? "check"
    : NodeProcess.argv.includes("--dry-run")
      ? "dry-run"
      : "apply";
  const result = run({ root, mode });
  for (const line of [...result.changed, ...result.moved]) NodeProcess.stdout.write(`${line}\n`);
  if (mode === "check") {
    NodeProcess.stdout.write(
      result.changed.length === 0
        ? "infinitus-rename: no old identifier remains\n"
        : `infinitus-rename: ${result.changed.length} file(s) still carry an old identifier\n`,
    );
    if (result.changed.length > 0) NodeProcess.exit(1);
  } else {
    NodeProcess.stdout.write(
      `infinitus-rename (${mode}): ${result.changed.length} file(s), ${result.moved.length} move(s)\n`,
    );
  }
}
