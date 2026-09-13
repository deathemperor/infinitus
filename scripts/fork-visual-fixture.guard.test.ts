// @effect-diagnostics nodeBuiltinImport:off -- A guard test reading the Mac app's own source files, not runtime code.
import * as NodeFS from "node:fs";

import { describe, expect, it } from "vite-plus/test";

/**
 * `fork-visual-fixture.data.json` is an `infinitusctl` capture: it plays the
 * Mac the visual pass renders against. A capture drifts silently. A command
 * it still claims after the Mac dropped it hands every capability gate in the
 * web a `true` no real build gives — the pane renders in CI and is gone on the
 * user's Mac — and a pref key it still carries draws a settings row the same
 * way, which is how the session-era rows stayed on screen in CI until #1122.
 *
 * The same ordering rule holds as for `PREF_COPY` (#1041, stated in #1068):
 * the fixture loses a verb or a key in the PR that removes it from the Mac.
 *
 * One direction only for commands: the fixture answers just the read verbs the
 * pass exercises, so a command the Mac has and the fixture omits is normal.
 * A command the fixture claims and the Mac lacks is the lie.
 */

const read = (path: string) => NodeFS.readFileSync(new URL(path, import.meta.url), "utf8");

const FIXTURE = JSON.parse(read("./fork-visual-fixture.data.json")) as {
  readonly manifest: { readonly commands: ReadonlyArray<{ readonly name: string }> };
  readonly prefs: {
    readonly sections: ReadonlyArray<{ readonly slug: string; readonly name: string }>;
    readonly prefs: ReadonlyArray<{ readonly key: string }>;
  };
};

/** Every `ControlCommand(name: "<verb>", …)` the Mac's table declares. */
function macCommands(): ReadonlyArray<string> {
  const source = read("../apps/mac/Sources/InfinitusCore/ControlProtocol.swift");
  return [...source.matchAll(/ControlCommand\(name: "([a-z0-9-]+)"/g)].map(
    (match) => match[1] as string,
  );
}

/** Every `Entry("<key>", …)` the Mac's preference catalog declares. */
function macPrefKeys(): ReadonlyArray<string> {
  const source = read("../apps/mac/Sources/InfinitusCore/PrefCatalog.swift");
  return [...source.matchAll(/\bEntry\("([a-z0-9_]+)"/g)].map((match) => match[1] as string);
}

/** Its sections, as `{slug, name}` in the order the catalog lists them. */
function macPrefSections(): ReadonlyArray<{ readonly slug: string; readonly name: string }> {
  const source = read("../apps/mac/Sources/InfinitusCore/PrefCatalog.swift");
  return [...source.matchAll(/Section\(slug: "([a-z]+)", name: "([^"]+)"\)/g)].map((match) => ({
    slug: match[1] as string,
    name: match[2] as string,
  }));
}

/** The verbs `answer()` in the fixture server has a case for. */
function fixtureAnswered(): ReadonlyArray<string> {
  const source = read("./fork-visual-fixture.mjs");
  return [...source.matchAll(/^\s{4}case "([a-z0-9-]+)":/gm)].map((match) => match[1] as string);
}

describe("the visual-pass fixture against the Mac's control protocol", () => {
  it("reads the Mac's sources", () => {
    // A rename or a move of either Swift file must fail here, not pass the
    // assertions below against an empty list.
    expect(macCommands().length).toBeGreaterThan(30);
    expect(macPrefKeys().length).toBeGreaterThan(30);
    expect(macPrefSections().length).toBeGreaterThan(3);
  });

  it("claims no command the Mac dropped", () => {
    const known = new Set(macCommands());
    const orphans = FIXTURE.manifest.commands
      .map((command) => command.name)
      .filter((name) => !known.has(name));
    expect(orphans).toEqual([]);
  });

  it("answers only commands it claims", () => {
    // A verb answered but unclaimed would keep working after the Mac drops it,
    // with nothing above to catch it.
    const claimed = new Set(FIXTURE.manifest.commands.map((command) => command.name));
    const unclaimed = fixtureAnswered().filter((verb) => !claimed.has(verb));
    expect(unclaimed).toEqual([]);
  });

  it("carries the catalog's preferences, no more and no less", () => {
    const fixtureKeys = FIXTURE.prefs.prefs.map((pref) => pref.key);
    const catalogKeys = macPrefKeys();
    expect(fixtureKeys.filter((key) => !catalogKeys.includes(key))).toEqual([]);
    expect(catalogKeys.filter((key) => !fixtureKeys.includes(key))).toEqual([]);
  });

  it("carries the catalog's sections, slug and name", () => {
    // The pages read the section by slug and print its name, so a retitle on
    // the Mac (#1069) lands here before a route goes blank in CI.
    expect([...FIXTURE.prefs.sections]).toEqual([...macPrefSections()]);
  });
});
