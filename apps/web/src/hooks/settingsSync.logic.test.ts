// @effect-diagnostics nodeBuiltinImport:off -- One guard reads the Mac app's own catalog source, not runtime code.
import * as NodeFS from "node:fs";
import * as NodeURL from "node:url";
import { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusPref, InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  adopt,
  alignCommands,
  alignPass,
  EMPTY_DOC,
  INITIAL_SYNC_STATE,
  observe,
  SYNC_OFF,
  SYNCED_PREF_KEYS,
  syncDoc,
  syncMachines,
  syncSwitches,
  type SyncState,
} from "./settingsSync.logic";

const ON = { settings: true, names: true };

const pref = (key: string, value: boolean | number | string): InfinitusPref => ({
  key,
  type: typeof value === "boolean" ? "bool" : typeof value === "number" ? "int" : "string",
  default: value,
  value,
  section: "display",
  effect: "live",
});

const account = (
  number: number,
  email: string,
  alias?: string,
): InfinitusSnapshot["fleets"][number]["accounts"][number] => ({
  number,
  email,
  active: number === 1,
  isOrganization: false,
  usageStatus: "ok",
  ...(alias === undefined ? {} : { alias }),
});

const fleet = (
  accounts: ReadonlyArray<InfinitusSnapshot["fleets"][number]["accounts"][number]>,
  overrides: Partial<InfinitusSnapshot["fleets"][number]> = {},
): InfinitusSnapshot["fleets"][number] => ({
  key: "swapd/claude",
  engineID: "swapd",
  provider: "claude",
  capabilities: ["switch", "rename"],
  accounts,
  ...overrides,
});

const snapshot = (
  prefs: ReadonlyArray<InfinitusPref>,
  fleets: ReadonlyArray<InfinitusSnapshot["fleets"][number]> = [],
): InfinitusSnapshot => ({
  available: true,
  fleets,
  prefs: { sections: [], prefs },
  commands: [],
});

describe("SYNCED_PREF_KEYS", () => {
  it("names only keys the Mac's catalog declares, and never the sync switches", () => {
    const source = NodeFS.readFileSync(
      NodeURL.fileURLToPath(
        new URL("../../../mac/Sources/InfinitusCore/PrefCatalog.swift", import.meta.url),
      ),
      "utf8",
    );
    const catalog = new Set([...source.matchAll(/\bEntry\("([a-z0-9_]+)"/g)].map((m) => m[1]));
    expect(catalog.size).toBeGreaterThan(30);
    expect(SYNCED_PREF_KEYS.filter((key) => !catalog.has(key))).toEqual([]);
    expect(SYNCED_PREF_KEYS).not.toContain("sync_settings");
    expect(SYNCED_PREF_KEYS).not.toContain("sync_account_names");
  });
});

describe("syncSwitches", () => {
  it("reads the primary's two switches, off when absent or the app is away", () => {
    expect(syncSwitches(null)).toEqual(SYNC_OFF);
    expect(syncSwitches({ available: false, fleets: [], commands: [] })).toEqual(SYNC_OFF);
    expect(syncSwitches(snapshot([pref("sync_settings", true)]))).toEqual({
      settings: true,
      names: false,
    });
  });
});

describe("syncMachines", () => {
  it("keeps every Infinitus environment, the primary included", () => {
    const mac = EnvironmentId.make("mac");
    const plain = EnvironmentId.make("plain");
    const studio = EnvironmentId.make("studio");
    const environments = [
      { environmentId: mac, connection: { phase: "connected" } },
      { environmentId: plain, connection: { phase: "connected" } },
      { environmentId: studio, connection: { phase: "reconnecting" } },
    ];
    expect(syncMachines(environments, (id) => id !== plain)).toEqual([
      { environmentId: mac, connected: true },
      { environmentId: studio, connected: false },
    ]);
  });
});

describe("syncDoc", () => {
  it("takes the synced prefs and the names of accounts that can be renamed", () => {
    const doc = syncDoc(
      snapshot(
        [pref("compact_rows", true), pref("fork_server_port", 4000), pref("sync_settings", true)],
        [
          fleet([account(1, "a@x.io", "Dragon"), account(2, "b@x.io"), account(3, "")]),
          fleet([account(1, "c@x.io", "Owl")], {
            key: "9router/claude",
            engineID: "9router",
            capabilities: ["switch"],
          }),
        ],
      ),
      ON,
    );
    expect(doc).toEqual({
      prefs: { compact_rows: true },
      names: { "claude/a@x.io": "Dragon", "claude/b@x.io": "" },
    });
  });

  it("leaves out the part whose switch is off, and is null while the app is away", () => {
    const full = snapshot([pref("compact_rows", true)], [fleet([account(1, "a@x.io", "Dragon")])]);
    expect(syncDoc(full, { settings: true, names: false })).toEqual({
      prefs: { compact_rows: true },
      names: {},
    });
    expect(syncDoc(full, { settings: false, names: true })).toEqual({
      prefs: {},
      names: { "claude/a@x.io": "Dragon" },
    });
    expect(syncDoc({ available: false, fleets: [], commands: [] }, ON)).toBeNull();
  });
});

describe("adopt", () => {
  const shared = { prefs: { compact_rows: true }, names: { "claude/a@x.io": "Dragon" } };

  it("seeds an empty doc from the first machine seen", () => {
    expect(adopt(EMPTY_DOC, null, shared)).toEqual(shared);
  });

  it("lets a newcomer add what the doc lacks but not override what it has", () => {
    const next = adopt(shared, null, {
      prefs: { compact_rows: false, title_scoped: true },
      names: { "claude/b@x.io": "Owl" },
    });
    expect(next).toEqual({
      prefs: { compact_rows: true, title_scoped: true },
      names: { "claude/a@x.io": "Dragon", "claude/b@x.io": "Owl" },
    });
  });

  it("takes an edit: a value unlike both the last seen and the shared one", () => {
    const observed = { prefs: { compact_rows: true }, names: { "claude/a@x.io": "Dragon" } };
    const next = adopt(shared, observed, {
      prefs: { compact_rows: false },
      names: { "claude/a@x.io": "" },
    });
    expect(next).toEqual({ prefs: { compact_rows: false }, names: { "claude/a@x.io": "" } });
  });

  it("ignores the echo of a push and a write the machine refused", () => {
    // Echo: the machine now shows the shared value it was just sent.
    const behind = { prefs: { compact_rows: false }, names: { "claude/a@x.io": "Wyrm" } };
    expect(adopt(shared, behind, shared)).toBe(shared);
    // Refusal: the machine still shows what it showed before the push.
    expect(adopt(shared, behind, behind)).toBe(shared);
  });
});

describe("alignCommands", () => {
  it("writes each differing pref the machine knows and renames each differing account", () => {
    const shared = {
      prefs: { compact_rows: true, popup_layout: "wide", glass_focused: 0.5 },
      names: { "claude/a@x.io": "Dragon", "claude/b@x.io": "", "codex/z@x.io": "Elsewhere" },
    };
    const target = snapshot(
      [pref("compact_rows", false), pref("popup_layout", "wide")],
      [
        fleet([account(1, "a@x.io", "Wyrm"), account(2, "b@x.io", "Old"), account(3, "n@x.io")]),
        fleet([account(1, "z@x.io")], {
          key: "9router/codex",
          provider: "codex",
          capabilities: [],
        }),
      ],
    );
    expect(alignCommands(shared, target, ON)).toEqual([
      { command: "prefs", args: ["set", "compact_rows", "true"] },
      { command: "rename", args: ["swapd/claude", "1", "Dragon"] },
      { command: "rename", args: ["swapd/claude", "2", ""] },
    ]);
    expect(alignCommands(shared, target, { settings: true, names: false })).toHaveLength(1);
    expect(alignCommands(shared, target, { settings: false, names: true })).toHaveLength(2);
  });

  it("encodes a string pref as JSON, the shape `prefs set` reads", () => {
    const shared = { prefs: { popup_layout: "wide" }, names: {} };
    expect(alignCommands(shared, snapshot([pref("popup_layout", "tall")]), ON)).toEqual([
      { command: "prefs", args: ["set", "popup_layout", '"wide"'] },
    ]);
  });
});

/**
 * Two desktops over the same two Macs, each with the other Mac's desktop
 * running the same loop. The world is what each Mac shows; a desktop's pass
 * writes into it the way `prefs set` would.
 */
describe("two desktops", () => {
  const mac1 = EnvironmentId.make("mac1");
  const mac2 = EnvironmentId.make("mac2");
  const machines = [
    { environmentId: mac1, connected: true },
    { environmentId: mac2, connected: true },
  ];
  type World = Record<string, { layout: string; sync: boolean }>;
  const worldSnapshot = (world: World, id: string) =>
    snapshot([pref("popup_layout", world[id]!.layout), pref("sync_settings", world[id]!.sync)]);

  class Desktop {
    state: SyncState = INITIAL_SYNC_STATE;
    writes = 0;
    constructor(readonly primary: EnvironmentId) {}
    /** One poll of both Macs, then one pass, its writes applied at once. */
    round(world: World) {
      const snapshots = new Map<EnvironmentId, InfinitusSnapshot | null>();
      for (const id of [mac1, mac2]) {
        const snap = worldSnapshot(world, id);
        snapshots.set(id, snap);
        this.state = observe(this.state, id, id === this.primary, snap);
      }
      const pass = alignPass(this.state, machines, snapshots);
      this.state = pass.state;
      for (const work of pass.work) {
        for (const command of work.commands) {
          expect(command.command).toBe("prefs");
          expect(command.args[1]).toBe("popup_layout");
          world[work.environmentId]!.layout = JSON.parse(command.args[2]!) as string;
          this.writes += 1;
        }
      }
    }
  }

  const rounds = (world: World, desktops: ReadonlyArray<Desktop>, count: number) => {
    for (let i = 0; i < count; i += 1) for (const desktop of desktops) desktop.round(world);
  };

  it("baselines at startup: machines that already differ stay as they are, quietly", () => {
    const world: World = {
      mac1: { layout: "wide", sync: true },
      mac2: { layout: "tall", sync: true },
    };
    const desktops = [new Desktop(mac1), new Desktop(mac2)];
    rounds(world, desktops, 6);
    expect(world.mac1!.layout).toBe("wide");
    expect(world.mac2!.layout).toBe("tall");
    expect(desktops.map((d) => d.writes)).toEqual([0, 0]);
  });

  it("carries an edit on either Mac to the other with one write, then settles", () => {
    const world: World = {
      mac1: { layout: "wide", sync: true },
      mac2: { layout: "tall", sync: true },
    };
    const desktops = [new Desktop(mac1), new Desktop(mac2)];
    rounds(world, desktops, 2);
    world.mac2!.layout = "compact";
    rounds(world, desktops, 6);
    expect(world.mac1!.layout).toBe("compact");
    expect(world.mac2!.layout).toBe("compact");
    expect(desktops[0]!.writes + desktops[1]!.writes).toBe(1);
  });

  it("a flip on the primary aligns the other Mac to it, and nothing after", () => {
    const world: World = {
      mac1: { layout: "wide", sync: false },
      mac2: { layout: "tall", sync: true },
    };
    const desktops = [new Desktop(mac1), new Desktop(mac2)];
    rounds(world, desktops, 2);
    world.mac1!.sync = true;
    rounds(world, desktops, 6);
    expect(world.mac2!.layout).toBe("wide");
    expect(desktops.map((d) => d.writes)).toEqual([1, 0]);
  });

  it("keeps the switches through the primary's app relaunching", () => {
    const desktop = new Desktop(mac1);
    const world: World = {
      mac1: { layout: "wide", sync: true },
      mac2: { layout: "wide", sync: true },
    };
    desktop.round(world);
    const away = observe(desktop.state, mac1, true, { available: false, fleets: [], commands: [] });
    expect(away.switches).toEqual({ settings: true, names: false });
    expect(away.alignOnSight).toBe(false);
  });
});
