import type { InfinitusPref, InfinitusPrefs } from "@t3tools/contracts/infinitus";
import * as Equal from "effect/Equal";
import * as Schema from "effect/Schema";

/**
 * Turns the native app's preference catalog (`infinitusctl prefs`) into rows a
 * settings pane can render, and back into the `prefs set` command a write
 * sends. Pure on purpose: the pane picks controls and dispatches, this file
 * decides what each pref looks like, what a typed edit means, and which
 * optimistic writes are still in flight.
 */

/** Which control edits a pref. A pref with `choices` is always a select, no
    matter its type; its values are stringified for the DOM and parsed back by
    `parseControlInput`. */
export type PrefControl =
  | { kind: "switch"; value: boolean }
  | { kind: "select"; value: string; options: ReadonlyArray<{ value: string; label: string }> }
  | { kind: "number"; value: number; integer: boolean; min?: number; max?: number }
  | { kind: "text"; value: string };

export interface PrefRowModel {
  readonly key: string;
  readonly label: string;
  readonly description: string | null;
  readonly control: PrefControl;
  readonly isDefault: boolean;
  readonly requiresRestart: boolean;
  readonly section: string;
}

export interface PrefSectionModel {
  readonly slug: string;
  readonly name: string;
  readonly rows: ReadonlyArray<PrefRowModel>;
}

/**
 * User-facing wording for every key the native `PrefCatalog` lists today,
 * taken from the Mac Settings panes that own each pref so both surfaces read
 * the same. `choices` renames the values that are codes rather than words; a
 * key missing from here falls back to a humanised key, and a choice missing
 * from `choices` shows its own value.
 */
export const PREF_COPY: Readonly<
  Record<
    string,
    { label: string; description?: string; choices?: Readonly<Record<string, string>> }
  >
> = {
  // Display › Menu bar. The status item's own switch leads the section in the
  // catalog (#1184), and this map follows it so the two read in step.
  menu_bar_enabled: {
    label: "Show the icon in the menu bar",
    description:
      "Off, the icon stays hidden across relaunches. Infinitus keeps running in the background; this page and infinitusctl turn it back on.",
  },
  title_icon_only: { label: "Show only the icon" },
  show_account_name: { label: "Show the account name" },
  title_pct: {
    label: "Percentages",
    choices: { off: "None", "5h": "Session (5h)", "7d": "Weekly (7d)", both: "Both (5h · 7d)" },
  },
  title_reset: {
    label: "Reset time",
    description: "The refill of whichever limit is further from empty, session or weekly.",
    choices: { off: "None", countdown: "Countdown", clock: "Clock time" },
  },
  title_scoped: { label: "Show model limits" },
  title_remaining: { label: "Count what's left, not what's used" },
  menubar_themed: { label: "Follow the theme" },
  menubar_effects: {
    label: "Animate switches and burn",
    description: "Needs the theme on.",
  },
  refresh_interval: {
    label: "Refresh interval",
    description: "How often Infinitus asks for new usage numbers.",
    choices: { "30": "30 seconds", "60": "60 seconds", "300": "5 minutes" },
  },
  // Display › Popup.
  popup_layout: {
    label: "Popup layout",
    choices: { wide: "Wide rows", stacked: "Stacked cards", hstack: "Horizontal cards" },
  },
  popup_text_size: {
    label: "Popup text size",
    choices: { default: "Default", large: "Large", xlarge: "Extra large", huge: "Huge" },
  },
  popup_sort: {
    label: "Sort rows by",
    choices: { engine: "Engine order", headroom: "Headroom", candidates: "Candidates" },
  },
  compact_rows: {
    label: "Compact rows",
    description: "Each account on one line with icon-only controls.",
  },
  footer_actions_hidden: {
    label: "Hide the action buttons",
    description: "Everything they did stays in the menu bar icon's right-click menu.",
  },
  glass_focused: {
    label: "Transparency",
    description: "Higher is clearer, lower is frostier; one value for every state.",
  },
  // Themes.
  gamification_style: {
    label: "Theme",
    description: "A built-in theme's id, or one of your own from themes.json.",
    choices: {
      off: "Off — plain numbers",
      rpg: "RPG — HP/MP gauges + gold",
      movie: "Movie — reels & box office",
      hades: "Hades — blades & darkness",
      mgs: "Metal Gear — tactical espionage",
      agent: "AI Agentic — tokens & context",
      swe: "Classic SWE — hand-written, no AI",
      scifi: "Sci-Fi — warp cores & shields",
      west: "Wild West — six-guns & gold rush",
      cyber: "Cyberpunk — chrome & neon",
      gothic: "Gothic — candles & cathedrals",
      musical: "Musical — tempo & encores",
      earth: "Planet Earth — wild documentary",
      cosmo: "Cosmos — stars & black holes",
      ocean: "Ocean — tides & deep water",
    },
  },
  // Animations: the popup's launch choreography and the bars' pace fire. The
  // keys are the Mac's internal words ("intro", "burn"); the screen says what
  // each one does.
  intro_style: {
    label: "Popup entrance",
    description: "How the account rows arrive when the popup opens.",
    choices: {
      top: "Slide down from the top",
      bottom: "Slide up from the bottom",
      fade: "Fade in",
      rows: "One row at a time",
    },
  },
  intro_title: {
    label: "Title flourish",
    description: "How the Infinitus title lands after them.",
    choices: { zoom: "Zoom in", slam: "Slam down", spin: "Spin in", off: "None" },
  },
  intro_speed: {
    label: "Animation speed",
    description: "Multiplies every entrance animation; higher is faster.",
  },
  burn_style: {
    label: "Pace fire",
    description: "How a bar burns while its usage outruns the clock.",
    choices: {
      off: "Off",
      ember: "Ember",
      flame: "Flame",
      limit: "Limit break — RPG theme only, else ember",
    },
  },
  // Push.
  push_all_dead: { label: "All accounts are exhausted" },
  push_last_alive: { label: "The last alive account nears its limit" },
  push_revived: { label: "An account comes back" },
  revive_lead_minutes: { label: "Revive countdown lead (minutes)" },
  // Devices: the tunnel fronting this server's own port, which the "Pair a
  // phone" card below hands the QR when the phone is off the Wi‑Fi. The keys
  // are the Mac's (#572) and say "fork"; the screen never does (#823).
  fork_tunnel_enabled: {
    label: "Reach this server through a Cloudflare tunnel",
    description: "Lets a phone pair and connect from outside your network.",
  },
  fork_server_port: {
    label: "Server port",
    description: "The port this server listens on. Infinitus writes it at startup.",
  },
  fork_tunnel_hostname: {
    label: "Tunnel hostname",
    description:
      "A named tunnel's hostname, so the URL survives a restart. Empty takes a fresh quick-tunnel URL each time.",
  },
  // Engines.
  engine_swapd_enabled: { label: "swapd engine on (swaps the login under each provider's CLI)" },
  engine_cliproxy_enabled: { label: "CLIProxyAPI engine on (rotates behind its own endpoint)" },
  engine_9router_enabled: { label: "9Router engine on (rotates behind its own endpoint)" },
  // About.
  update_channel: {
    label: "Update channel",
    choices: { stable: "Stable", nightly: "Nightly" },
  },
  // Priority: thread priority mode (#616 hold, #743 interrupt). The verdict
  // itself is native's; these are the knobs it reads.
  priority_mode: {
    label: "Thread priority",
    description:
      "What happens to background threads (not pinned) while the fleet they spend on is low on headroom.",
    choices: {
      off: "Off — every thread runs",
      hold: "Hold — new turns wait for headroom",
      interrupt: "Interrupt — running turns pause too",
    },
  },
  priority_low_pct: {
    label: "Low above",
    description: "Usage of the binding window, in percent, at or above which headroom reads low.",
  },
  priority_abundant_pct: {
    label: "Abundant below",
    description:
      "Usage, in percent, at or below which headroom reads abundant again and waiting threads continue.",
  },
};

/** "push_all_dead" → "Push all dead", for a key the native app has added since
    this map was written. */
function humaniseKey(key: string): string {
  const words = key.split("_").filter((word) => word.length > 0);
  const first = words[0];
  if (first === undefined) return key;
  return [first.charAt(0).toUpperCase() + first.slice(1), ...words.slice(1)].join(" ");
}

/** `default` and `value` are JSON scalars the contract leaves `unknown`, so
    every read narrows by `type` and falls back the way the native catalog does:
    a value of the wrong type reads as the default. */
function boolOf(pref: InfinitusPref, raw: unknown): boolean {
  if (typeof raw === "boolean") return raw;
  return typeof pref.default === "boolean" ? pref.default : false;
}

function numberOf(pref: InfinitusPref, raw: unknown): number {
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  return typeof pref.default === "number" && Number.isFinite(pref.default) ? pref.default : 0;
}

function stringOf(pref: InfinitusPref, raw: unknown): string {
  if (typeof raw === "string") return raw;
  return typeof pref.default === "string" ? pref.default : "";
}

function typedValue(pref: InfinitusPref, raw: unknown): boolean | number | string {
  switch (pref.type) {
    case "bool":
      return boolOf(pref, raw);
    case "int":
    case "double":
      return numberOf(pref, raw);
    case "string":
      return stringOf(pref, raw);
  }
}

/** One choice as the catalog sends it: a bare value (`"rpg"`, `30`) or, for a
    list the native side names (#747), `{id, name}`. `value` is what is
    written; `name` is the catalog's label when it carries one. */
interface Choice {
  readonly value: string;
  readonly name: string | null;
}

function choiceOf(raw: unknown): Choice {
  if (raw !== null && typeof raw === "object" && "id" in raw) {
    const { id, name } = raw as { id: unknown; name?: unknown };
    return { value: String(id), name: typeof name === "string" && name !== "" ? name : null };
  }
  return { value: String(raw), name: null };
}

function choicesOf(pref: InfinitusPref): ReadonlyArray<Choice> | null {
  const choices = pref.choices;
  return choices == null || choices.length === 0 ? null : choices.map(choiceOf);
}

/** The catalog's bound when it is a finite number; null otherwise. */
function boundOf(raw: number | null | undefined): number | null {
  return typeof raw === "number" && Number.isFinite(raw) ? raw : null;
}

function controlFor(pref: InfinitusPref, raw: unknown): PrefControl {
  const choices = choicesOf(pref);
  if (choices !== null) {
    const labels = PREF_COPY[pref.key]?.choices;
    return {
      kind: "select",
      value: String(typedValue(pref, raw)),
      options: choices.map((choice) => ({
        value: choice.value,
        label: labels?.[choice.value] ?? choice.name ?? choice.value,
      })),
    };
  }
  switch (pref.type) {
    case "bool":
      return { kind: "switch", value: boolOf(pref, raw) };
    case "int":
    case "double": {
      const min = boundOf(pref.min);
      const max = boundOf(pref.max);
      return {
        kind: "number",
        value: numberOf(pref, raw),
        integer: pref.type === "int",
        ...(min === null ? {} : { min }),
        ...(max === null ? {} : { max }),
      };
    }
    case "string":
      return { kind: "text", value: stringOf(pref, raw) };
  }
}

function rowFor(pref: InfinitusPref): PrefRowModel {
  const copy = PREF_COPY[pref.key];
  return {
    key: pref.key,
    label: copy?.label ?? humaniseKey(pref.key),
    description: copy?.description ?? null,
    control: controlFor(pref, pref.value),
    isDefault: Equal.equals(pref.value, pref.default),
    requiresRestart: pref.effect === "restart",
    section: pref.section,
  };
}

/**
 * The catalog grouped into its sections, both in catalog order. `sectionSlugs`
 * keeps only those sections (still in catalog order); a section with no prefs
 * is left out, as is a pref whose `section` names none of them.
 */
export function buildPrefSections(
  prefs: InfinitusPrefs,
  sectionSlugs?: ReadonlyArray<string>,
): ReadonlyArray<PrefSectionModel> {
  const wanted = sectionSlugs === undefined ? null : new Set(sectionSlugs);
  const sections: Array<PrefSectionModel> = [];
  for (const section of prefs.sections) {
    if (wanted !== null && !wanted.has(section.slug)) continue;
    const rows = prefs.prefs.filter((pref) => pref.section === section.slug).map(rowFor);
    if (rows.length === 0) continue;
    sections.push({ slug: section.slug, name: section.name, rows });
  }
  return sections;
}

/** The control socket takes the new value as a JSON scalar, so it is encoded
    through a schema rather than hand-serialised. */
const PrefValueJson = Schema.fromJsonString(
  Schema.Union([Schema.Boolean, Schema.Finite, Schema.String]),
);
const encodePrefValue = Schema.encodeSync(PrefValueJson);

/** The `prefs set <key> <json>` command one edit sends. */
export function prefWriteArgs(
  pref: InfinitusPref,
  next: boolean | number | string,
): { command: "prefs"; args: readonly ["set", string, string] } {
  return { command: "prefs", args: ["set", pref.key, encodePrefValue(next)] };
}

/**
 * A control's raw string turned into the pref's own type, or the reason it is
 * not a value this pref can take. Rejection is the point: an int pref must not
 * accept "1.5" or "" (which `Number` reads as 0), and a pref with `choices`
 * must not accept anything outside them, nor a bounded number outside its
 * `min`/`max`.
 */
export function parseControlInput(
  pref: InfinitusPref,
  raw: string,
): { ok: true; value: boolean | number | string } | { ok: false; reason: string } {
  const trimmed = raw.trim();
  let value: boolean | number | string;
  switch (pref.type) {
    case "bool": {
      if (trimmed !== "true" && trimmed !== "false") {
        return { ok: false, reason: `Expected true or false, not "${raw}".` };
      }
      value = trimmed === "true";
      break;
    }
    case "int": {
      if (!/^-?\d+$/.test(trimmed)) {
        return { ok: false, reason: `Expected a whole number, not "${raw}".` };
      }
      value = Number(trimmed);
      break;
    }
    case "double": {
      const parsed = trimmed === "" ? Number.NaN : Number(trimmed);
      if (!Number.isFinite(parsed)) {
        return { ok: false, reason: `Expected a number, not "${raw}".` };
      }
      value = parsed;
      break;
    }
    case "string": {
      value = raw;
      break;
    }
  }
  const choices = choicesOf(pref);
  if (choices !== null && !choices.some((choice) => choice.value === String(value))) {
    return {
      ok: false,
      reason: `"${raw}" is not one of ${choices.map((choice) => choice.value).join(", ")}.`,
    };
  }
  if (typeof value === "number") {
    const min = boundOf(pref.min);
    const max = boundOf(pref.max);
    if ((min !== null && value < min) || (max !== null && value > max)) {
      return {
        ok: false,
        reason: `Expected a number between ${min ?? "−∞"} and ${max ?? "∞"}, not "${raw}".`,
      };
    }
  }
  return { ok: true, value };
}

/**
 * One section's in-flight writes. `pending` holds the value each key was last
 * set to and drops it when a snapshot reports that value, so a row shows the
 * edit right away without ever disagreeing with the app for long. `relaunching`
 * covers a restart-effect write: `sawUnavailable` is the extra bookkeeping that
 * makes it clear only after the socket has actually gone away and come back,
 * not on the snapshot that arrives before the app has quit.
 */
export type PrefWriteState = {
  readonly pending: ReadonlyMap<string, boolean | number | string>;
  readonly errors: ReadonlyMap<string, string>;
  readonly relaunching: boolean;
  readonly sawUnavailable: boolean;
};

export const initialPrefWriteState: PrefWriteState = {
  pending: new Map(),
  errors: new Map(),
  relaunching: false,
  sawUnavailable: false,
};

export type PrefWriteEvent =
  | { type: "submit"; key: string; value: boolean | number | string; requiresRestart: boolean }
  | { type: "failed"; key: string; error: string }
  /** The restart-effect write was refused, so the app never quit and nothing is
      waiting for the socket to come back. */
  | { type: "relaunchAborted" }
  | { type: "snapshot"; prefs?: InfinitusPrefs | undefined; available: boolean };

function confirmPending(
  pending: ReadonlyMap<string, boolean | number | string>,
  prefs: InfinitusPrefs | undefined,
): ReadonlyMap<string, boolean | number | string> {
  if (pending.size === 0 || prefs === undefined) return pending;
  const next = new Map(pending);
  for (const pref of prefs.prefs) {
    if (!next.has(pref.key)) continue;
    if (Equal.equals(typedValue(pref, pref.value), next.get(pref.key))) next.delete(pref.key);
  }
  return next.size === pending.size ? pending : next;
}

export function reducePrefWrite(state: PrefWriteState, event: PrefWriteEvent): PrefWriteState {
  switch (event.type) {
    case "submit": {
      const pending = new Map(state.pending);
      pending.set(event.key, event.value);
      const errors = new Map(state.errors);
      errors.delete(event.key);
      return {
        ...state,
        pending,
        errors,
        relaunching: state.relaunching || event.requiresRestart,
      };
    }
    case "failed": {
      const pending = new Map(state.pending);
      pending.delete(event.key);
      const errors = new Map(state.errors);
      errors.set(event.key, event.error);
      return { ...state, pending, errors };
    }
    case "relaunchAborted": {
      return { ...state, relaunching: false, sawUnavailable: false };
    }
    case "snapshot": {
      const sawUnavailable = state.relaunching && !event.available ? true : state.sawUnavailable;
      const relaunching = state.relaunching && !(sawUnavailable && event.available);
      return {
        pending: confirmPending(state.pending, event.prefs),
        errors: state.errors,
        relaunching,
        sawUnavailable: relaunching ? sawUnavailable : false,
      };
    }
  }
}

/** The value the pref falls back to, in the pref's own type: what a reset
    writes and what the "Default" hint names. */
export function defaultValue(pref: InfinitusPref): boolean | number | string {
  return typedValue(pref, pref.default);
}

/** What a row shows: the value an in-flight write set, else the snapshot's.
    `undefined` is not a pending value, so `get` doubles as the `has` check. */
export function displayValue(
  pref: InfinitusPref,
  state: PrefWriteState,
): boolean | number | string {
  const pending = state.pending.get(pref.key);
  return pending === undefined ? typedValue(pref, pref.value) : pending;
}
