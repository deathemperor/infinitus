// @effect-diagnostics nodeBuiltinImport:off -- A guard test reading the Mac app's own source file, not runtime code.
import * as NodeFS from "node:fs";
import * as NodeURL from "node:url";
import { describe, expect, it } from "vite-plus/test";
import { PREF_COPY } from "./prefsForm.logic";

/**
 * `PREF_COPY` and the Mac's `PrefCatalog` are one list seen from two sides, and
 * neither side fails loudly when they drift: a catalog key with no copy still
 * draws a row, labelled by `humaniseKey` with its raw choice codes in the
 * select ("Intro style" / "top"), and a copy entry with no catalog key draws
 * nothing at all. The visual pass checks one marker per route, so a regression
 * on any other row of the same page is invisible to it. This test is the check.
 *
 * The ordering rule it enforces (#1041, stated in #1068): a key's copy is
 * removed in the same PR that removes it from the catalog, never earlier.
 */

const CATALOG = NodeURL.fileURLToPath(
  new URL("../../../../../mac/Sources/InfinitusCore/PrefCatalog.swift", import.meta.url),
);

/** Every `Entry("<key>", …)` the catalog declares, in its own order. */
function catalogKeys(): ReadonlyArray<string> {
  const source = NodeFS.readFileSync(CATALOG, "utf8");
  return [...source.matchAll(/\bEntry\("([a-z0-9_]+)"/g)].map((match) => match[1] as string);
}

describe("PREF_COPY against the native catalog", () => {
  it("reads the catalog", () => {
    // A rename or a move of the Swift file must fail here, not silently pass
    // the two assertions below with an empty list.
    expect(catalogKeys().length).toBeGreaterThan(30);
  });

  it("gives every catalog key its own wording", () => {
    const uncovered = catalogKeys().filter((key) => PREF_COPY[key] === undefined);
    expect(uncovered).toEqual([]);
  });

  it("has no copy for a key the catalog dropped", () => {
    const known = new Set(catalogKeys());
    const orphans = Object.keys(PREF_COPY).filter((key) => !known.has(key));
    expect(orphans).toEqual([]);
  });

  it("names every choice of a key whose values are codes", () => {
    // A `choices` map that misses one of the catalog's values falls through to
    // the raw code in the select, which is the same defect one row down.
    const source = NodeFS.readFileSync(CATALOG, "utf8");
    const lists = new Map(
      [...source.matchAll(/let (introStyles|introTitles|burnStyles|priorityModes) = \[([^\]]+)\]/g)]
        .map(
          ([, name, body]) =>
            [
              name as string,
              [...(body as string).matchAll(/"([^"]+)"/g)].map((m) => m[1] as string),
            ] as const,
        )
        .filter(([, values]) => values.length > 0),
    );
    // One chunk per `Entry(` so a key is never paired with a later entry's list.
    const unnamed = source.split("Entry(").flatMap((chunk) => {
      const key = /^"([a-z0-9_]+)"/.exec(chunk)?.[1];
      const argument = /choices: strings\(([^)]*)\)/.exec(chunk)?.[1];
      if (key === undefined || argument === undefined) return [];
      const values =
        lists.get(argument.trim()) ??
        [...argument.matchAll(/"([^"]+)"/g)].map((match) => match[1] as string);
      if (values.length === 0) return [];
      const named = PREF_COPY[key]?.choices;
      return values
        .filter((value) => named?.[value] === undefined)
        .map((value) => `${key}.${value}`);
    });
    expect(unnamed).toEqual([]);
  });
});
