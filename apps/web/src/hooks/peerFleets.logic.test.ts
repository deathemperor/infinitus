import { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  fleetFingerprint,
  forwardable,
  peerCommandResult,
  peerMachines,
  peerSyncBody,
  peerSyncReply,
} from "./peerFleets.logic";

const mac = EnvironmentId.make("mac");
const studio = EnvironmentId.make("studio");
const plain = EnvironmentId.make("plain");

const fleet = (
  overrides: Partial<InfinitusSnapshot["fleets"][number]["accounts"][number]> = {},
) => ({
  key: "swapd/claude",
  engineID: "swapd",
  provider: "claude",
  capabilities: ["switch", "hold"],
  activeNumber: 1,
  accounts: [
    {
      number: 1,
      email: "one@example.com",
      active: true,
      isOrganization: false,
      usageStatus: "ok",
      usage: { fiveHour: { pct: 12.4, countdown: "2h 1m" }, sevenDay: { pct: 40.2 } },
      usageAgeSeconds: 30,
      usageFetchedAt: "2026-09-22T10:00:00Z",
      ...overrides,
    },
  ],
});

describe("peerMachines", () => {
  it("lists every other environment that runs Infinitus, with its connection", () => {
    const environments = [
      { environmentId: mac, label: "Mini Nova", connection: { phase: "connected" } },
      { environmentId: studio, label: "Studio", connection: { phase: "reconnecting" } },
      { environmentId: plain, label: "Plain server", connection: { phase: "connected" } },
    ];
    expect(peerMachines(environments, (id) => id !== plain, mac)).toEqual([
      { environmentId: studio, label: "Studio", connected: false },
    ]);
  });
});

describe("fleetFingerprint", () => {
  it("ignores the age and fetch stamps that move every poll", () => {
    const a = fleetFingerprint([fleet()]);
    const b = fleetFingerprint([
      fleet({ usageAgeSeconds: 90, usageFetchedAt: "2026-09-22T10:01:00Z" }),
    ]);
    expect(a).toBe(b);
  });

  it("changes when a row would", () => {
    const a = fleetFingerprint([fleet()]);
    expect(fleetFingerprint([fleet({ active: false })])).not.toBe(a);
    expect(fleetFingerprint([fleet({ disabled: true })])).not.toBe(a);
    expect(fleetFingerprint([fleet({ alias: "spare" })])).not.toBe(a);
    expect(
      fleetFingerprint([fleet({ usage: { fiveHour: { pct: 13.6 }, sevenDay: { pct: 40.2 } } })]),
    ).not.toBe(a);
    expect(fleetFingerprint([fleet({ resets: { available: 1, total: 1 } })])).not.toBe(a);
    expect(fleetFingerprint([fleet({ resets: { available: 0, total: 1 } })])).not.toBe(
      fleetFingerprint([fleet({ resets: { available: 1, total: 1 } })]),
    );
    // A fraction of a percent the bar cannot show is not a change.
    expect(
      fleetFingerprint([fleet({ usage: { fiveHour: { pct: 12.2 }, sevenDay: { pct: 40.4 } } })]),
    ).toBe(a);
    expect(fleetFingerprint(null)).toBe("");
  });
});

describe("peerSyncBody", () => {
  it("carries each machine's fleets, and nothing for one whose app is offline", () => {
    const machines = [
      { environmentId: studio, label: "Studio", connected: true },
      { environmentId: plain, label: "Quiet", connected: true },
      { environmentId: mac, label: "Away", connected: false },
    ];
    const snapshots = new Map<EnvironmentId, InfinitusSnapshot | null>([
      [studio, { available: true, fleets: [fleet()], commands: [] }],
      [plain, { available: false, fleets: [], commands: [] }],
    ]);
    const body = peerSyncBody(machines, snapshots, [{ id: "c1", ok: true }]);
    expect(
      body.machines.map((machine) => [
        machine.id,
        machine.connected,
        machine.fleets?.length ?? null,
      ]),
    ).toEqual([
      ["studio", true, 1],
      ["plain", false, null],
      ["mac", false, null],
    ]);
    expect(body.results).toEqual([{ id: "c1", ok: true }]);
  });
});

describe("peerSyncReply", () => {
  it("reads the queued commands and drops a reply it cannot", () => {
    expect(
      peerSyncReply({
        commands: [
          {
            id: "c1",
            machine: "studio",
            command: "switch",
            args: ["swapd/claude", "2"],
            options: {},
          },
        ],
      }),
    ).toEqual([
      { id: "c1", machine: "studio", command: "switch", args: ["swapd/claude", "2"], options: {} },
    ]);
    expect(peerSyncReply({ commands: "nope" })).toEqual([]);
    expect(peerSyncReply(null)).toEqual([]);
  });
});

describe("forwardable", () => {
  it("lets row actions through and nothing that adds, signs in or restarts", () => {
    const command = (name: string) => ({
      id: "c",
      machine: "studio",
      command: name,
      args: [],
      options: {},
    });
    for (const name of [
      "switch",
      "hold",
      "unhold",
      "prefer",
      "auto-ignite",
      "rename",
      "remove",
      "rotate",
      "reset",
    ]) {
      expect(forwardable(command(name))).toBe(true);
    }
    for (const name of [
      "add",
      "signin-begin",
      "signin-code",
      "engine",
      "quit",
      "peer-sync",
      "prefs-set",
    ]) {
      expect(forwardable(command(name))).toBe(false);
    }
  });
});

describe("peerCommandResult", () => {
  it("keeps the machine's own words on a failure", () => {
    const command = { id: "c1", machine: "studio", command: "remove", args: [], options: {} };
    expect(peerCommandResult(command, { ok: true })).toEqual({ id: "c1", ok: true });
    expect(peerCommandResult(command, { ok: false, error: "no account #9" })).toEqual({
      id: "c1",
      ok: false,
      error: "no account #9",
    });
  });
});
