#!/usr/bin/env node
// Folds apps/mac/changelog.d/*.md fragments and the `## Unreleased` block of
// apps/mac/CHANGELOG.md into a new `## <version>` section, leaving an empty
// Unreleased above it and deleting the fragments. Run at a release cut:
//
//   node scripts/fold-changelog.mjs 0.5.0-alpha.9
//
// A fragment is one file per PR, any name, each non-empty line
// `<Surface>: <one sentence>` where Surface is Mac, Desktop, Phone or Linux.
// Lines already sitting under `### <Surface>` in Unreleased are kept and the
// fragment lines are appended after them, so both conventions coexist.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

export const SURFACES = ["Mac", "Desktop", "Phone", "Linux"];

/** Pure: (changelog text, fragment texts, version) → { text, warnings }. */
export function foldChangelog(changelog, fragments, version) {
  const warnings = [];
  const marker = "## Unreleased\n";
  const start = changelog.indexOf(marker);
  if (start < 0) throw new Error("CHANGELOG.md has no '## Unreleased' section");
  const afterMarker = start + marker.length;
  const nextSection = changelog.indexOf("\n## ", afterMarker);
  const unreleased =
    nextSection < 0 ? changelog.slice(afterMarker) : changelog.slice(afterMarker, nextSection + 1);
  const tail = nextSection < 0 ? "" : changelog.slice(nextSection + 1);

  const bySurface = new Map(SURFACES.map((s) => [s, []]));
  const extra = [];
  let current = null;
  for (const rawLine of unreleased.split("\n")) {
    const line = rawLine.trimEnd();
    const heading = /^### (\w+)$/.exec(line);
    if (heading) {
      current = heading[1];
      if (!bySurface.has(current)) bySurface.set(current, []);
      continue;
    }
    if (line.length === 0) continue;
    if (current === null) extra.push(line);
    else bySurface.get(current).push(line);
  }
  for (const [name, text] of fragments) {
    for (const rawLine of text.split("\n")) {
      const line = rawLine.trim();
      if (line.length === 0) continue;
      const m = /^(\w+):\s*(.+)$/.exec(line);
      if (!m || !bySurface.has(m[1])) {
        warnings.push(`${name}: unrecognised line, kept under Desktop: ${line}`);
        bySurface.get("Desktop").push(`- ${line.replace(/^-\s*/, "")}`);
        continue;
      }
      const sentence = m[2].replace(/^-\s*/, "");
      bySurface.get(m[1]).push(`- ${sentence}`);
    }
  }

  let section = `## ${version}\n\n`;
  if (extra.length > 0) section += extra.join("\n") + "\n\n";
  const order = [...SURFACES, ...[...bySurface.keys()].filter((k) => !SURFACES.includes(k))];
  for (const surface of order) {
    const lines = bySurface.get(surface) ?? [];
    if (lines.length === 0) continue;
    section += `### ${surface}\n${lines.join("\n")}\n\n`;
  }
  if (section === `## ${version}\n\n`)
    throw new Error("nothing to release: Unreleased and changelog.d are both empty");

  const text = changelog.slice(0, afterMarker) + "\n\n" + section + tail;
  return { text, warnings };
}

export function readFragments(dir) {
  let names = [];
  try {
    names = NodeFS.readdirSync(dir)
      .filter((n) => n.endsWith(".md") && n !== "README.md")
      .sort();
  } catch {
    return [];
  }
  return names.map((n) => [n, NodeFS.readFileSync(NodePath.join(dir, n), "utf8")]);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const version = process.argv[2];
  if (!version || !/^\d+\.\d+\.\d+(-[\w.]+)?$/.test(version)) {
    console.error("usage: node scripts/fold-changelog.mjs <version>");
    process.exit(2);
  }
  const root = NodePath.resolve(NodePath.dirname(new URL(import.meta.url).pathname), "..");
  const changelogPath = NodePath.join(root, "apps/mac/CHANGELOG.md");
  const fragmentsDir = NodePath.join(root, "apps/mac/changelog.d");
  const fragments = readFragments(fragmentsDir);
  const { text, warnings } = foldChangelog(
    NodeFS.readFileSync(changelogPath, "utf8"),
    fragments,
    version,
  );
  NodeFS.writeFileSync(changelogPath, text);
  for (const [name] of fragments) NodeFS.unlinkSync(NodePath.join(fragmentsDir, name));
  for (const w of warnings) console.warn(w);
  console.log(`folded ${fragments.length} fragment(s) into ## ${version}`);
}
