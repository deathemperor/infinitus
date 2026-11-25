#!/usr/bin/env node
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";

/**
 * Re-keys the translation catalogs after `infinitus-rename.ts` renamed their copy: a catalog
 * key is a hash of the English, so regenerating drops every renamed string's translation. This
 * regenerates each app's catalogs and gives a new key the translation its English had before.
 * Needs `vp i` first (the gt CLI). `docs/internals/infinitus-rename.md`.
 */

const GENERATE: Record<string, readonly [string, ...string[]]> = {
  "apps/web": ["node_modules/.bin/gt", "generate"],
  "apps/mobile": ["node_modules/.bin/gt", "generate"],
  "apps/desktop": [NodeProcess.execPath, "scripts/i18n-generate.mjs"],
};

type Catalog = Record<string, unknown>;
const readJson = (file: string): Catalog => JSON.parse(NodeFS.readFileSync(file, "utf8"));
const text = (value: unknown) => JSON.stringify(value);

/** Each translated string by its English, before the keys move. */
export function translationsByEnglish(
  english: Catalog,
  catalog: Catalog,
): ReadonlyMap<string, unknown> {
  const byEnglish = new Map<string, unknown>();
  for (const [key, source] of Object.entries(english)) {
    if (!Object.hasOwn(catalog, key) || text(catalog[key]) === text(source)) continue;
    byEnglish.set(text(source), catalog[key]);
  }
  return byEnglish;
}

/** Fills each key that still holds its English with the translation that English had. */
export function carryTranslations(
  english: Catalog,
  catalog: Catalog,
  byEnglish: ReadonlyMap<string, unknown>,
): Catalog {
  const out: Catalog = {};
  for (const [key, value] of Object.entries(catalog)) {
    const source = english[key];
    const untranslated = source !== undefined && text(value) === text(source);
    out[key] = untranslated ? (byEnglish.get(text(source)) ?? value) : value;
  }
  return out;
}

if (import.meta.main) {
  const root = NodeChildProcess.execFileSync("git", ["rev-parse", "--show-toplevel"], {
    cwd: NodeProcess.cwd(),
  })
    .toString("utf8")
    .trim();
  for (const [app, [command, ...args]] of Object.entries(GENERATE)) {
    const appDir = NodePath.join(root, app);
    const config = readJson(NodePath.join(appDir, "gt.config.json")) as {
      defaultLocale: string;
      locales: ReadonlyArray<string>;
      files: { gt: { output: string } };
    };
    const file = (locale: string) =>
      NodePath.join(appDir, config.files.gt.output.replace("[locale]", locale));
    const before = readJson(file(config.defaultLocale));
    const carried = new Map(
      config.locales.map((locale) => [
        locale,
        translationsByEnglish(before, readJson(file(locale))),
      ]),
    );
    NodeChildProcess.execFileSync(command, args, { cwd: appDir, stdio: "inherit" });
    const after = readJson(file(config.defaultLocale));
    for (const locale of config.locales) {
      const catalog = carryTranslations(after, readJson(file(locale)), carried.get(locale)!);
      NodeFS.writeFileSync(file(locale), `${JSON.stringify(catalog, null, 2)}\n`);
    }
    NodeProcess.stdout.write(`infinitus-rename-catalogs: ${app} re-keyed\n`);
  }
}
