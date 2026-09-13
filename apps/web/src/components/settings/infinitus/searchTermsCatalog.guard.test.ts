// @effect-diagnostics nodeBuiltinImport:off -- A guard test reading the Mac app's own source file, not runtime code.
import * as NodeFS from "node:fs";
import * as NodeURL from "node:url";
import { describe, expect, it } from "vite-plus/test";
import { SETTINGS_SEARCH_ITEMS, type SettingsSearchItem } from "../settingsSearch";
import { PREF_COPY } from "./prefsForm.logic";

/**
 * A settings-search term is a promise: type the word, land on a page that has
 * the row you meant. The Infinitus pages draw their rows from the Mac's own
 * `PrefCatalog`, so a key the Mac retires takes its row away — and any term
 * that only that row justified becomes a word that navigates to a page which
 * no longer answers for it. Nothing fails when that happens: the item still
 * matches, the page still renders, the row is simply not there.
 *
 * That is how "waiting" and "aws sign-in" (`push_waiting`, `push_aws_login`)
 * and "live activity" (`live_activity_rate_seconds`) outlived their rows
 * through the sessions sweep (#1041). This test grounds every term of a
 * catalog-drawn page in that page's own sections — their keys, the Mac's
 * section names, and the wording `PREF_COPY` gives each row — so the next
 * retirement fails here instead of shipping a dead word.
 *
 * Companion to `prefCopyCatalog.guard.test.ts`, which grounds the wording.
 */

const CATALOG = NodeURL.fileURLToPath(
  new URL("../../../../../mac/Sources/InfinitusCore/PrefCatalog.swift", import.meta.url),
);

/** The catalog pages, by search-item id: the section slugs each route renders
    (`sectionSlugs`), which is what decides the rows a term can land on. Pages
    built from bespoke cards rather than the catalog — Slack, Lock, the Dock
    badge, Engines' status list — are not grounded by this rule. */
const CATALOG_PAGES: Readonly<Record<string, ReadonlyArray<string>>> = {
  "infinitus-preferences": ["display", "about"],
  "infinitus-themes": ["themes"],
  "infinitus-animations": ["animations"],
  "infinitus-sessions": ["priority", "sessions"],
  "infinitus-push": ["push"],
  "infinitus-devices": ["devices"],
};

/**
 * Words a page is searchable by for a reason other than one of its rows. Each
 * one is a synonym people type, or belongs to a fork card the route mounts
 * beside the prefs — never a leftover from a retired key, which is the whole
 * point of keeping the exception list short and written down.
 */
const ALIASES: Readonly<Record<string, ReadonlyArray<string>>> = {
  // "startup" and "threads": the Menu bar route's own cards (Threads, Slack,
  // This window) sit under the catalog sections.
  "infinitus-preferences": ["startup", "threads"],
  // What people call a theme list when they are looking for one.
  "infinitus-themes": ["picker", "look"],
  "infinitus-animations": ["motion"],
  // The row's old name, kept searchable for anyone who knew it as "session
  // priority": the Mac's section read "Sessions" until #1069 renamed it, and
  // the row itself is still there — this is a rename's synonym, not a term a
  // retired key left behind.
  "infinitus-sessions": ["session"],
  // Where these notifications land: the Mac posts them to the phone (#702).
  // The rows name the account event, never the device.
  "infinitus-push": ["phone"],
  // The route's "Pair a phone" card draws the code as a QR.
  "infinitus-devices": ["qr"],
};

/** Every `Entry("<key>", …, <section>)` the catalog declares, with its section. */
function catalogEntries(source: string): ReadonlyArray<readonly [string, string]> {
  return [
    ...source.matchAll(/Entry\("([a-z0-9_]+)",\s*\.\w+,\s*[^,]+(?:\([^)]*\))?,\s*([a-z]+)/g),
  ].map((match) => [match[1] as string, match[2] as string] as const);
}

/** The Mac's own name for each section slug ("push" → "Push"). */
function catalogSectionNames(source: string): ReadonlyMap<string, string> {
  return new Map(
    [...source.matchAll(/Section\(slug: "([a-z]+)", name: "([^"]+)"\)/g)].map(
      (match) => [match[1] as string, match[2] as string] as const,
    ),
  );
}

/** Loose enough that a term matches a row's wording in any inflection, strict
    enough that a word no row carries at all stands out. */
function stem(word: string): string {
  return word
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "")
    .replace(/s$/, "");
}

function vocabularyOf(text: string): ReadonlySet<string> {
  return new Set(
    text
      .split(/[^A-Za-z0-9]+/)
      .map(stem)
      .filter((word) => word.length > 2),
  );
}

/** Everything a row of these sections puts on screen: its key, its section's
    name, and the label, description and choice names `PREF_COPY` gives it. */
function pageVocabulary(
  source: string,
  slugs: ReadonlyArray<string>,
  title: string,
): ReadonlySet<string> {
  const names = catalogSectionNames(source);
  const keys = catalogEntries(source)
    .filter(([, slug]) => slugs.includes(slug))
    .map(([key]) => key);
  const copy = keys.flatMap((key) => {
    const entry = PREF_COPY[key];
    if (entry === undefined) return [];
    return [entry.label, entry.description ?? "", ...Object.values(entry.choices ?? {})];
  });
  return vocabularyOf(
    [
      title,
      ...slugs.map((slug) => names.get(slug) ?? ""),
      ...keys.map((key) => key.replace(/_/g, " ")),
      ...copy,
    ].join(" "),
  );
}

describe("Infinitus settings-search terms against the native catalog", () => {
  const source = NodeFS.readFileSync(CATALOG, "utf8");
  // The literal tuple's per-item types make `id` a union of literals and
  // `searchTerms` present only on the items that carry one; the interface is
  // what this test reads each item as.
  const items: ReadonlyArray<SettingsSearchItem> = SETTINGS_SEARCH_ITEMS;

  it("reads the catalog", () => {
    // A rename or a move of the Swift file must fail here, not quietly ground
    // every term against an empty vocabulary below.
    expect(catalogEntries(source).length).toBeGreaterThan(30);
  });

  it("indexes every catalog page", () => {
    // A page added to the fork without a search item, or an item renamed, must
    // not silently drop out of the grounding.
    const indexed = new Set(items.map((item) => item.id));
    expect(Object.keys(CATALOG_PAGES).filter((id) => !indexed.has(id))).toEqual([]);
  });

  it("grounds every term in a row the page still draws", () => {
    const dead = Object.entries(CATALOG_PAGES).flatMap(([id, slugs]) => {
      const item = items.find((candidate) => candidate.id === id);
      if (item === undefined) return [];
      const vocabulary = pageVocabulary(source, slugs, item.title);
      const allowed = new Set((ALIASES[id] ?? []).map(stem));
      return (item.searchTerms ?? [])
        .flatMap((terms) => terms.split(/\s+/))
        .filter((word) => word.length > 0)
        .filter((word) => !vocabulary.has(stem(word)) && !allowed.has(stem(word)))
        .map((word) => `${id}: ${word}`);
    });
    expect(dead).toEqual([]);
  });
});
