import type { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";

import { prefWriteArgs } from "../components/settings/infinitus/prefsForm.logic";

/**
 * The prefs that travel between machines: the popup's look, the title, the
 * pushes. The Mac's retired iCloud sync list carried forward (`sort_headroom`
 * became `popup_sort`), with the animations and `push_revived` that were
 * added after it joined. Per-machine state stays home: the status item's
 * own switches, the ports, the engines, the priority knobs, and the two sync
 * switches themselves. `settingsSync.logic.test.ts` checks every key against
 * the Mac's catalog, so a retired key fails there instead of being sent to
 * every machine as an unknown pref.
 */
export const SYNCED_PREF_KEYS: ReadonlyArray<string> = [
  "show_account_name",
  "title_pct",
  "title_scoped",
  "title_remaining",
  "title_reset",
  "title_icon_only",
  "refresh_interval",
  "popup_layout",
  "popup_text_size",
  "popup_sort",
  "compact_rows",
  "footer_actions_hidden",
  "glass_focused",
  "gamification_style",
  "intro_style",
  "intro_title",
  "intro_speed",
  "burn_style",
  "push_all_dead",
  "push_last_alive",
  "push_revived",
  "revive_lead_minutes",
];
const SYNCED = new Set(SYNCED_PREF_KEYS);

export type PrefScalar = boolean | number | string;

/** The two Devices switches, read off the primary Mac's prefs. */
export interface SyncSwitches {
  readonly settings: boolean;
  readonly names: boolean;
}
export const SYNC_OFF: SyncSwitches = { settings: false, names: false };

export function syncSwitches(snapshot: InfinitusSnapshot | null): SyncSwitches {
  if (snapshot?.available !== true || snapshot.prefs === undefined) return SYNC_OFF;
  const rows = snapshot.prefs.prefs;
  const on = (key: string) => rows.find((pref) => pref.key === key)?.value === true;
  return { settings: on("sync_settings"), names: on("sync_account_names") };
}

export function switchesEqual(a: SyncSwitches, b: SyncSwitches): boolean {
  return a.settings === b.settings && a.names === b.names;
}

/** One machine's synced state as the desktop compares it: the synced prefs
    by key, and the account names by `provider/email` (an empty string where
    an account wears none, so a clear travels like a name does). */
export interface SyncDoc {
  readonly prefs: Readonly<Record<string, PrefScalar>>;
  readonly names: Readonly<Record<string, string>>;
}
export const EMPTY_DOC: SyncDoc = { prefs: {}, names: {} };

export interface SyncMachine {
  readonly environmentId: EnvironmentId;
  readonly connected: boolean;
}

/** Every environment that runs Infinitus, the primary included: the sync is
    symmetric, a change on any machine reaches every other. */
export function syncMachines(
  environments: ReadonlyArray<{
    readonly environmentId: EnvironmentId;
    readonly connection: { readonly phase: string };
  }>,
  runsInfinitus: (environmentId: EnvironmentId) => boolean,
): ReadonlyArray<SyncMachine> {
  return environments
    .filter((environment) => runsInfinitus(environment.environmentId))
    .map((environment) => ({
      environmentId: environment.environmentId,
      connected: environment.connection.phase === "connected",
    }));
}

export function nameKey(provider: string, email: string): string {
  return `${provider}/${email}`;
}

function isScalar(value: unknown): value is PrefScalar {
  return typeof value === "boolean" || typeof value === "number" || typeof value === "string";
}

/** What one snapshot says of the synced state; only the parts a switch has
    on. Names come from the fleets that can rename, and an account without an
    email has no identity across machines, so it stays out. Null while the
    app is not answering. */
export function syncDoc(
  snapshot: InfinitusSnapshot | null,
  switches: SyncSwitches,
): SyncDoc | null {
  if (snapshot?.available !== true) return null;
  const prefs: Record<string, PrefScalar> = {};
  if (switches.settings && snapshot.prefs !== undefined) {
    for (const pref of snapshot.prefs.prefs) {
      if (SYNCED.has(pref.key) && isScalar(pref.value)) prefs[pref.key] = pref.value;
    }
  }
  const names: Record<string, string> = {};
  if (switches.names) {
    for (const fleet of snapshot.fleets) {
      if (!fleet.capabilities.includes("rename")) continue;
      for (const account of fleet.accounts) {
        if (account.email === "") continue;
        names[nameKey(fleet.provider, account.email)] = account.alias ?? "";
      }
    }
  }
  return { prefs, names };
}

/**
 * The shared doc after one observation of a machine. A key counts as written
 * by that machine only when its value differs from BOTH what was last
 * observed there AND the shared value: that one rule keeps the echo of our
 * own push, a snapshot taken mid-push, and a write the machine refused from
 * reading as edits. A key seen for the first time (a machine's first sight,
 * a new account) joins only where the shared doc has nothing, so a newcomer
 * never overrides what the others agree on. Returns `shared` itself when
 * nothing changed.
 */
export function adopt(shared: SyncDoc, observed: SyncDoc | null, current: SyncDoc): SyncDoc {
  const prefs = adoptPart(shared.prefs, observed?.prefs ?? null, current.prefs);
  const names = adoptPart(shared.names, observed?.names ?? null, current.names);
  return prefs === shared.prefs && names === shared.names ? shared : { prefs, names };
}

function adoptPart<V extends PrefScalar>(
  shared: Readonly<Record<string, V>>,
  observed: Readonly<Record<string, V>> | null,
  current: Readonly<Record<string, V>>,
): Readonly<Record<string, V>> {
  let next: Record<string, V> | null = null;
  for (const [key, value] of Object.entries(current)) {
    const before = observed?.[key];
    const written =
      before === undefined ? !(key in shared) : value !== before && value !== shared[key];
    if (!written) continue;
    next ??= { ...shared };
    next[key] = value;
  }
  return next ?? shared;
}

export interface SyncCommand {
  readonly command: string;
  readonly args: ReadonlyArray<string>;
}

/** The commands that bring one machine to the shared doc: a `prefs set` per
    pref the machine knows and holds differently, a `rename` per account whose
    name differs. A pref the machine's catalog lacks is left alone. */
export function alignCommands(
  shared: SyncDoc,
  snapshot: InfinitusSnapshot,
  switches: SyncSwitches,
): ReadonlyArray<SyncCommand> {
  const commands: Array<SyncCommand> = [];
  if (switches.settings && snapshot.prefs !== undefined) {
    for (const pref of snapshot.prefs.prefs) {
      const wanted = shared.prefs[pref.key];
      if (wanted === undefined || wanted === pref.value) continue;
      commands.push(prefWriteArgs(pref, wanted));
    }
  }
  if (switches.names) {
    for (const fleet of snapshot.fleets) {
      if (!fleet.capabilities.includes("rename")) continue;
      for (const account of fleet.accounts) {
        if (account.email === "") continue;
        const wanted = shared.names[nameKey(fleet.provider, account.email)];
        if (wanted === undefined || wanted === (account.alias ?? "")) continue;
        commands.push({ command: "rename", args: [fleet.key, String(account.number), wanted] });
      }
    }
  }
  return commands;
}

/**
 * One desktop's sync state, as `observe` and `alignPass` advance it. Kept
 * immutable so a test can replay two desktops over the same machines: every
 * Mac's desktop may run this loop, and the rules have to converge with two of
 * them pushing.
 */
export interface SyncState {
  readonly switches: SyncSwitches;
  /** The primary's switches have been read once; a later change is a flip. */
  readonly switchesRead: boolean;
  /** Since a flip: a machine's first sight is aligned to the doc, not just
      baselined. Off at startup, so a desktop coming up with a stale primary
      never pushes that staleness over the others — with two desktops each
      aligning on sight from a different seed, the machines would take turns
      adopting what the other desktop just pushed, forever. */
  readonly alignOnSight: boolean;
  readonly shared: SyncDoc;
  readonly version: number;
  readonly seeded: boolean;
  readonly observed: ReadonlyMap<EnvironmentId, SyncDoc>;
  readonly pushed: ReadonlyMap<EnvironmentId, number>;
}

export const INITIAL_SYNC_STATE: SyncState = {
  switches: SYNC_OFF,
  switchesRead: false,
  alignOnSight: false,
  shared: EMPTY_DOC,
  version: 0,
  seeded: false,
  observed: new Map(),
  pushed: new Map(),
};

function without<K, V>(map: ReadonlyMap<K, V>, key: K): ReadonlyMap<K, V> {
  if (!map.has(key)) return map;
  const next = new Map(map);
  next.delete(key);
  return next;
}

function withEntry<K, V>(map: ReadonlyMap<K, V>, key: K, value: V): ReadonlyMap<K, V> {
  const next = new Map(map);
  next.set(key, value);
  return next;
}

/** A machine left the list; its return is a first sight again. */
export function forget(state: SyncState, environmentId: EnvironmentId): SyncState {
  const observed = without(state.observed, environmentId);
  const pushed = without(state.pushed, environmentId);
  return observed === state.observed && pushed === state.pushed
    ? state
    : { ...state, observed, pushed };
}

/**
 * One machine's snapshot arriving. The primary's carries the switches: the
 * first read only records them, a later change starts over (the primary
 * seeds again, and every machine's next sight aligns it). A machine's first
 * sight, and a machine coming back, is a baseline: its edits travel from
 * here on, but what it shows now is not pushed over the others' — unless a
 * flip asked for that.
 */
export function observe(
  state: SyncState,
  environmentId: EnvironmentId,
  isPrimary: boolean,
  snapshot: InfinitusSnapshot | null,
): SyncState {
  let next = state;
  // A primary whose app is away keeps its last known switches: a relaunch
  // of the menu bar app is not a flip.
  if (isPrimary && snapshot?.available === true) {
    const switches = syncSwitches(snapshot);
    if (!next.switchesRead) {
      next = { ...next, switches, switchesRead: true };
    } else if (!switchesEqual(switches, next.switches)) {
      next = {
        ...INITIAL_SYNC_STATE,
        switches,
        switchesRead: true,
        alignOnSight: true,
        version: next.version + 1,
      };
    }
  }
  const on = next.switches;
  if (!on.settings && !on.names) return next;
  const doc = syncDoc(snapshot, on);
  if (doc === null) return forget(next, environmentId);
  // The primary seeds the shared doc; the others wait for it.
  if (!next.seeded) {
    if (!isPrimary) return next;
    next = { ...next, seeded: true };
  }
  const before = next.observed.get(environmentId) ?? null;
  const shared = adopt(next.shared, before, doc);
  const version = shared === next.shared ? next.version : next.version + 1;
  const pushed =
    before === null && !next.alignOnSight
      ? withEntry(next.pushed, environmentId, version)
      : next.pushed;
  return {
    ...next,
    shared,
    version,
    observed: withEntry(next.observed, environmentId, doc),
    pushed,
  };
}

export interface AlignWork {
  readonly environmentId: EnvironmentId;
  readonly commands: ReadonlyArray<SyncCommand>;
}

/** One pass: every connected machine not yet aligned to this version of the
    doc, with the commands that bring it there. Marked before the commands
    run, so a write a machine refuses is not retried until the doc moves. */
export function alignPass(
  state: SyncState,
  machines: ReadonlyArray<SyncMachine>,
  snapshots: ReadonlyMap<EnvironmentId, InfinitusSnapshot | null>,
): { readonly state: SyncState; readonly work: ReadonlyArray<AlignWork> } {
  const on = state.switches;
  if (!on.settings && !on.names) return { state, work: [] };
  let pushed = state.pushed;
  const work: Array<AlignWork> = [];
  for (const machine of machines) {
    if (!machine.connected || pushed.get(machine.environmentId) === state.version) continue;
    const snapshot = snapshots.get(machine.environmentId);
    if (snapshot?.available !== true || !state.observed.has(machine.environmentId)) continue;
    pushed = withEntry(pushed, machine.environmentId, state.version);
    const commands = alignCommands(state.shared, snapshot, on);
    if (commands.length > 0) work.push({ environmentId: machine.environmentId, commands });
  }
  return { state: pushed === state.pushed ? state : { ...state, pushed }, work };
}
