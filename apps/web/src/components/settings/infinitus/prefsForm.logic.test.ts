import type { InfinitusPref, InfinitusPrefs } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  PREF_COPY,
  buildPrefSections,
  defaultValue,
  displayValue,
  initialPrefWriteState,
  parseControlInput,
  prefWriteArgs,
  reducePrefWrite,
  type PrefControl,
  type PrefRowModel,
  type PrefSectionModel,
  type PrefWriteEvent,
  type PrefWriteState,
} from "./prefsForm.logic";

const pref = (
  over: Partial<InfinitusPref> & Pick<InfinitusPref, "key" | "type">,
): InfinitusPref => ({
  default: over.default ?? null,
  value: over.value ?? over.default ?? null,
  section: "display",
  effect: "live",
  ...over,
});

const flag = pref({ key: "compact_rows", type: "bool", default: false, value: true });
const lead = pref({ key: "revive_lead_minutes", type: "int", default: 10, value: 25 });
const glass = pref({ key: "glass_focused", type: "double", default: 0.7, value: 0.4 });
const theme = pref({ key: "gamification_style", type: "string", default: "off", value: "rpg" });
const layout = pref({
  key: "popup_layout",
  type: "string",
  default: "wide",
  value: "stacked",
  choices: ["wide", "stacked", "hstack"],
});
const interval = pref({
  key: "refresh_interval",
  type: "int",
  default: 60,
  value: 300,
  choices: [30, 60, 300],
});

const catalog = (
  sections: ReadonlyArray<{ slug: string; name: string }>,
  prefs: ReadonlyArray<InfinitusPref>,
): InfinitusPrefs => ({ sections, prefs });

const displaySection = { slug: "display", name: "Display" };
const pushSection = { slug: "push", name: "Push" };

const rowOf = (prefs: InfinitusPrefs, key: string): PrefRowModel => {
  const row = buildPrefSections(prefs)
    .flatMap((section) => section.rows)
    .find((candidate) => candidate.key === key);
  if (row === undefined) throw new Error(`no row for ${key}`);
  return row;
};

describe("buildPrefSections controls", () => {
  it("gives a bool a switch, an int and a double a number, a free string a text box", () => {
    const prefs = catalog([displaySection], [flag, lead, glass, theme]);
    const controls: ReadonlyArray<PrefControl> =
      buildPrefSections(prefs)[0]?.rows.map((row) => row.control) ?? [];

    expect(controls).toEqual([
      { kind: "switch", value: true },
      { kind: "number", value: 25, integer: true },
      { kind: "number", value: 0.4, integer: false },
      { kind: "text", value: "rpg" },
    ]);
  });

  it("gives any pref with choices a select whose options carry the copy map's labels", () => {
    const row = rowOf(catalog([displaySection], [layout]), "popup_layout");

    expect(row.control).toEqual({
      kind: "select",
      value: "stacked",
      options: [
        { value: "wide", label: "Wide rows" },
        { value: "stacked", label: "Stacked cards" },
        { value: "hstack", label: "Horizontal cards" },
      ],
    });
  });

  it("stringifies an int pref's choices and parses the picked option back to a number", () => {
    const row = rowOf(catalog([displaySection], [interval]), "refresh_interval");

    expect(row.control).toEqual({
      kind: "select",
      value: "300",
      options: [
        { value: "30", label: "30 seconds" },
        { value: "60", label: "60 seconds" },
        { value: "300", label: "5 minutes" },
      ],
    });
    expect(parseControlInput(interval, "30")).toEqual({ ok: true, value: 30 });
  });

  it("labels a choice by its own value when the copy map has no name for it", () => {
    const extended = pref({
      key: "popup_layout",
      type: "string",
      default: "wide",
      value: "wide",
      choices: ["wide", "grid"],
    });
    const row = rowOf(catalog([displaySection], [extended]), "popup_layout");

    expect(row.control).toEqual({
      kind: "select",
      value: "wide",
      options: [
        { value: "wide", label: "Wide rows" },
        { value: "grid", label: "grid" },
      ],
    });
  });

  it("humanises a key the copy map does not know and leaves it without a description", () => {
    const unknown = pref({ key: "push_all_dead", type: "bool", default: true, value: true });
    const invented = pref({ key: "brand_new_knob", type: "bool", default: false, value: false });
    const prefs = catalog(
      [pushSection],
      [
        { ...unknown, section: "push" },
        { ...invented, section: "push" },
      ],
    );

    const rows = buildPrefSections(prefs)[0]?.rows ?? [];
    expect(rows.map((row) => [row.label, row.description])).toEqual([
      [PREF_COPY.push_all_dead?.label, null],
      ["Brand new knob", null],
    ]);
    expect(PREF_COPY.brand_new_knob).toBeUndefined();
  });

  it("marks a row default only when the value equals the default, and flags restart effects", () => {
    const untouched = pref({ key: "compact_rows", type: "bool", default: false, value: false });
    const engine = pref({
      key: "engine_swapd_enabled",
      type: "bool",
      default: false,
      value: true,
      effect: "restart",
    });
    const rows =
      buildPrefSections(catalog([displaySection], [untouched, flag, engine]))[0]?.rows ?? [];

    expect(rows.map((row) => [row.isDefault, row.requiresRestart])).toEqual([
      [true, false],
      [false, false],
      [false, true],
    ]);
  });

  it("reads a value of the wrong type as the default, the way the native catalog does", () => {
    const stale = pref({ key: "revive_lead_minutes", type: "int", default: 10, value: "ten" });

    expect(rowOf(catalog([displaySection], [stale]), "revive_lead_minutes").control).toEqual({
      kind: "number",
      value: 10,
      integer: true,
    });
  });
});

describe("buildPrefSections grouping", () => {
  const prefs = catalog(
    [displaySection, pushSection, { slug: "about", name: "About" }],
    [flag, { ...lead, section: "push" }, layout],
  );

  it("keeps catalog order for sections and for the rows inside them", () => {
    const sections: ReadonlyArray<PrefSectionModel> = buildPrefSections(prefs);

    expect(sections.map((section) => [section.slug, section.rows.map((row) => row.key)])).toEqual([
      ["display", ["compact_rows", "popup_layout"]],
      ["push", ["revive_lead_minutes"]],
    ]);
  });

  it("omits a section with no prefs", () => {
    expect(buildPrefSections(prefs).map((section) => section.slug)).not.toContain("about");
  });

  it("filters to the given slugs, still in catalog order", () => {
    expect(buildPrefSections(prefs, ["push", "display"]).map((section) => section.slug)).toEqual([
      "display",
      "push",
    ]);
    expect(buildPrefSections(prefs, ["push"]).map((section) => section.slug)).toEqual(["push"]);
    expect(buildPrefSections(prefs, [])).toEqual([]);
  });

  it("drops a pref whose section is not in the catalog", () => {
    const orphan = catalog([displaySection], [flag, { ...lead, section: "nowhere" }]);

    expect(buildPrefSections(orphan)[0]?.rows.map((row) => row.key)).toEqual(["compact_rows"]);
  });
});

describe("prefWriteArgs", () => {
  it("JSON-encodes the new value for each pref type", () => {
    expect(prefWriteArgs(flag, false)).toEqual({
      command: "prefs",
      args: ["set", "compact_rows", "false"],
    });
    expect(prefWriteArgs(lead, 60)).toEqual({
      command: "prefs",
      args: ["set", "revive_lead_minutes", "60"],
    });
    expect(prefWriteArgs(glass, 0.5)).toEqual({
      command: "prefs",
      args: ["set", "glass_focused", "0.5"],
    });
    expect(prefWriteArgs(layout, "stacked")).toEqual({
      command: "prefs",
      args: ["set", "popup_layout", '"stacked"'],
    });
  });
});

describe("parseControlInput", () => {
  it("takes only true and false for a bool", () => {
    expect(parseControlInput(flag, "true")).toEqual({ ok: true, value: true });
    expect(parseControlInput(flag, " false ")).toEqual({ ok: true, value: false });
    expect(parseControlInput(flag, "yes").ok).toBe(false);
    expect(parseControlInput(flag, "1").ok).toBe(false);
  });

  it("takes only whole numbers for an int", () => {
    expect(parseControlInput(lead, "42")).toEqual({ ok: true, value: 42 });
    expect(parseControlInput(lead, "-3")).toEqual({ ok: true, value: -3 });
    expect(parseControlInput(lead, "1.5").ok).toBe(false);
    expect(parseControlInput(lead, "0x10").ok).toBe(false);
    expect(parseControlInput(lead, "").ok).toBe(false);
  });

  it("takes any finite number for a double", () => {
    expect(parseControlInput(glass, "0.35")).toEqual({ ok: true, value: 0.35 });
    expect(parseControlInput(glass, "1")).toEqual({ ok: true, value: 1 });
    expect(parseControlInput(glass, "").ok).toBe(false);
    expect(parseControlInput(glass, "Infinity").ok).toBe(false);
    expect(parseControlInput(glass, "frosty").ok).toBe(false);
  });

  it("takes any string when the pref has no choices", () => {
    expect(parseControlInput(theme, "synthwave")).toEqual({ ok: true, value: "synthwave" });
    expect(parseControlInput(theme, "")).toEqual({ ok: true, value: "" });
  });

  it("renders {id, name} choices by name and writes the id (#747)", () => {
    const style = pref({
      key: "gamification_style",
      section: "themes",
      type: "string",
      default: "off",
      value: "hades",
      choices: [
        { id: "off", name: "Off" },
        { id: "rpg", name: "RPG" },
        { id: "hades", name: "Hades" },
        { id: "custom-1", name: "My theme" },
        { id: "bare" },
      ],
    });
    const row = rowOf(catalog([{ slug: "themes", name: "Themes" }], [style]), "gamification_style");

    // The web's own copy still wins for built-ins it describes; the catalog's
    // name labels the rest (custom themes), and a nameless id labels itself.
    expect(row.control).toEqual({
      kind: "select",
      value: "hades",
      options: [
        { value: "off", label: "Off — plain numbers" },
        { value: "rpg", label: "RPG — HP/MP gauges + gold" },
        { value: "hades", label: "Hades — blades & darkness" },
        { value: "custom-1", label: "My theme" },
        { value: "bare", label: "bare" },
      ],
    });
    expect(parseControlInput(style, "custom-1")).toEqual({ ok: true, value: "custom-1" });
    expect(parseControlInput(style, "Hades").ok).toBe(false);
  });

  it("carries a bounded number's range and refuses a value outside it (#747)", () => {
    const speed = pref({
      key: "intro_speed",
      section: "animations",
      type: "double",
      default: 1,
      value: 1.5,
      min: 0.4,
      max: 2,
    });
    const row = rowOf(
      catalog([{ slug: "animations", name: "Animations" }], [speed]),
      "intro_speed",
    );

    expect(row.control).toEqual({ kind: "number", value: 1.5, integer: false, min: 0.4, max: 2 });
    expect(parseControlInput(speed, "0.4")).toEqual({ ok: true, value: 0.4 });
    expect(parseControlInput(speed, "2")).toEqual({ ok: true, value: 2 });
    expect(parseControlInput(speed, "2.5").ok).toBe(false);
    expect(parseControlInput(speed, "0").ok).toBe(false);
    // An unbounded int keeps the old control shape.
    expect(rowOf(catalog([displaySection], [lead]), "revive_lead_minutes").control).toEqual({
      kind: "number",
      value: 25,
      integer: true,
    });
  });

  it("rejects a value outside the choices and names them in the reason", () => {
    const rejected = parseControlInput(layout, "grid");

    expect(rejected.ok).toBe(false);
    expect(rejected.ok === false ? rejected.reason : "").toContain("wide, stacked, hstack");
    expect(parseControlInput(interval, "45").ok).toBe(false);
    expect(parseControlInput(interval, "60")).toEqual({ ok: true, value: 60 });
  });
});

describe("reducePrefWrite", () => {
  const submit = (
    key: string,
    value: boolean | number | string,
    requiresRestart = false,
  ): PrefWriteEvent => ({ type: "submit", key, value, requiresRestart });
  const snapshot = (prefs?: InfinitusPrefs, available = true): PrefWriteEvent => ({
    type: "snapshot",
    prefs,
    available,
  });
  const run = (events: ReadonlyArray<PrefWriteEvent>): PrefWriteState =>
    events.reduce(reducePrefWrite, initialPrefWriteState);

  it("holds a submitted value pending until a snapshot reports it", () => {
    const submitted = run([submit("compact_rows", false)]);
    expect(submitted.pending.get("compact_rows")).toBe(false);

    const stillOld = reducePrefWrite(submitted, snapshot(catalog([displaySection], [flag])));
    expect(stillOld.pending.get("compact_rows")).toBe(false);

    const confirmed = reducePrefWrite(
      stillOld,
      snapshot(catalog([displaySection], [{ ...flag, value: false }])),
    );
    expect(confirmed.pending.size).toBe(0);
    expect(confirmed.errors.size).toBe(0);
  });

  it("drops the pending value and records the error when a write fails", () => {
    const failed = run([
      submit("revive_lead_minutes", 60),
      { type: "failed", key: "revive_lead_minutes", error: "unknown key" },
    ]);

    expect(failed.pending.size).toBe(0);
    expect(failed.errors.get("revive_lead_minutes")).toBe("unknown key");
  });

  it("clears a key's error when it is submitted again", () => {
    const retried = run([
      submit("revive_lead_minutes", 60),
      { type: "failed", key: "revive_lead_minutes", error: "unknown key" },
      submit("revive_lead_minutes", 30),
    ]);

    expect(retried.errors.size).toBe(0);
    expect(retried.pending.get("revive_lead_minutes")).toBe(30);
  });

  it("stays relaunching until the socket has gone away and come back", () => {
    const submitted = run([submit("engine_swapd_enabled", true, true)]);
    expect(submitted.relaunching).toBe(true);

    // The app has not quit yet, so the snapshot that still answers proves nothing.
    const beforeQuit = reducePrefWrite(submitted, snapshot(catalog([], [])));
    expect(beforeQuit.relaunching).toBe(true);

    const goneAway = reducePrefWrite(beforeQuit, snapshot(undefined, false));
    expect(goneAway.relaunching).toBe(true);

    const back = reducePrefWrite(goneAway, snapshot(catalog([], []), true));
    expect(back.relaunching).toBe(false);
    expect(back.sawUnavailable).toBe(false);
  });

  it("does not go relaunching for a live write, and ignores an outage while none is pending", () => {
    const live = run([submit("compact_rows", false), snapshot(undefined, false)]);
    expect(live.relaunching).toBe(false);
    expect(live.sawUnavailable).toBe(false);

    // The earlier outage must not settle the next restart write on its own.
    const restart = reducePrefWrite(
      reducePrefWrite(live, submit("engine_swapd_enabled", true, true)),
      snapshot(catalog([], []), true),
    );
    expect(restart.relaunching).toBe(true);
  });

  it("stops waiting for a relaunch the app refused to start", () => {
    const refused = run([
      submit("engine_swapd_enabled", false, true),
      { type: "failed", key: "engine_swapd_enabled", error: "swapd is not installed" },
      { type: "relaunchAborted" },
    ]);

    expect(refused.relaunching).toBe(false);
    expect(refused.sawUnavailable).toBe(false);
    expect(refused.pending.size).toBe(0);
    // The refusal itself still has to be readable under the row.
    expect(refused.errors.get("engine_swapd_enabled")).toBe("swapd is not installed");
  });
});

describe("defaultValue", () => {
  it("reads the fallback in the pref's own type", () => {
    expect(defaultValue(flag)).toBe(false);
    expect(defaultValue(lead)).toBe(10);
    expect(defaultValue(glass)).toBe(0.7);
    expect(defaultValue(layout)).toBe("wide");
  });

  it("falls back the way the catalog does when the default is the wrong type", () => {
    expect(defaultValue(pref({ key: "compact_rows", type: "bool", default: "yes" }))).toBe(false);
    expect(defaultValue(pref({ key: "revive_lead_minutes", type: "int", default: null }))).toBe(0);
  });
});

describe("displayValue", () => {
  it("prefers a pending value over the snapshot's, including a falsy one", () => {
    const pendingOff = reducePrefWrite(initialPrefWriteState, {
      type: "submit",
      key: "compact_rows",
      value: false,
      requiresRestart: false,
    });

    expect(displayValue(flag, initialPrefWriteState)).toBe(true);
    expect(displayValue(flag, pendingOff)).toBe(false);
  });

  it("falls back to the snapshot's value for a key with nothing in flight", () => {
    expect(displayValue(lead, initialPrefWriteState)).toBe(25);
    expect(displayValue(theme, initialPrefWriteState)).toBe("rpg");
  });
});
