import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

import {
  InfinitusControlReply,
  InfinitusForecast,
  InfinitusFleet,
  InfinitusManifest,
  InfinitusSession,
  InfinitusStatus,
} from "./infinitus.ts";

const decodeReply = Schema.decodeUnknownSync(InfinitusControlReply);
const decodeStatus = Schema.decodeUnknownSync(InfinitusStatus);
const decodeFleet = Schema.decodeUnknownSync(InfinitusFleet);
const decodeForecast = Schema.decodeUnknownSync(InfinitusForecast);
const decodeSession = Schema.decodeUnknownSync(InfinitusSession);
const decodeManifest = Schema.decodeUnknownSync(InfinitusManifest);

const status = {
  version: "0.4.3",
  sha: "abc1234",
  socket: "/Users/dev/Library/Application Support/Infinitus/control/control.sock",
  badge: "none",
  playground: false,
  signInRunning: false,
  engines: {
    cswap: { enabled: true, registered: true },
    cliproxy: { enabled: false, registered: false, keyPresent: false },
  },
} as const;

const fleet = {
  key: "cswap/claude",
  engineID: "cswap",
  provider: "claude",
  capabilities: ["switch", "rotate", "rename"],
  activeNumber: 1,
  nextCandidate: 2,
  candidateOrder: [1, 2],
  nextRecovery: { number: 2, at: "2026-09-10T14:00:00Z" },
  accounts: [
    {
      number: 1,
      alias: "Alpha",
      email: "alpha@example.com",
      plan: "max20",
      active: true,
      preferred: true,
      isOrganization: false,
      usage: { fiveHour: { pct: 12 } },
      usageStatus: "fresh",
      usageAgeSeconds: 30,
      usageFetchedAt: "2026-09-10T09:00:00Z",
    },
    {
      number: 2,
      alias: "Beta",
      email: "beta@example.com",
      plan: "pro",
      active: false,
      preferred: false,
      isOrganization: true,
      organizationName: "Example Org",
      organizationUuid: "00000000-0000-4000-8000-000000000001",
      usage: null,
      usageStatus: "stale",
    },
  ],
} as const;

describe("InfinitusStatus", () => {
  it("decodes a status reply and its per-engine key presence", () => {
    const decoded = decodeStatus(status);

    expect(decoded.socket).toBe(status.socket);
    expect(decoded.engines.cswap?.keyPresent).toBeUndefined();
    expect(decoded.engines.cliproxy?.keyPresent).toBe(false);
  });

  it("tolerates a field a newer native build added", () => {
    const decoded = decodeStatus({ ...status, tunnelRunning: true });

    expect(decoded.version).toBe("0.4.3");
    expect(decoded.badge).toBe("none");
  });

  it("rejects a status whose playground flag is not a boolean", () => {
    expect(() => decodeStatus({ ...status, playground: "yes" })).toThrow();
  });
});

describe("InfinitusFleet", () => {
  it("decodes a fleet with two accounts, keeping opaque usage as sent", () => {
    const decoded = decodeFleet(fleet);

    expect(decoded.accounts).toHaveLength(2);
    expect(decoded.accounts[0]?.usage).toEqual({ fiveHour: { pct: 12 } });
    expect(decoded.accounts[1]?.organizationName).toBe("Example Org");
    expect(decoded.caveat).toBeUndefined();
    expect(decoded.nextRecovery).toEqual({ number: 2, at: "2026-09-10T14:00:00Z" });
  });

  it("decodes an account from an engine with no alias, plan, star or usage", () => {
    const decoded = decodeFleet({
      ...fleet,
      accounts: [
        {
          number: 1,
          email: "gamma@example.com",
          organizationName: "",
          organizationUuid: "",
          isOrganization: false,
          active: false,
          usageStatus: "unknown",
        },
      ],
    });

    expect(decoded.accounts[0]?.alias).toBeUndefined();
    expect(decoded.accounts[0]?.plan).toBeUndefined();
    expect(decoded.accounts[0]?.preferred).toBeUndefined();
    expect(decoded.accounts[0]?.usage).toBeUndefined();
  });

  it("tolerates an unknown key on an account", () => {
    const decoded = decodeFleet({
      ...fleet,
      accounts: [{ ...fleet.accounts[0], subscriptionKind: "team" }],
    });

    expect(decoded.accounts[0]?.email).toBe("alpha@example.com");
  });
});

describe("InfinitusForecast", () => {
  it("keeps the forecast's top-level keys and leaves the lines opaque", () => {
    const decoded = decodeForecast({
      forecast: {
        accounts: [{ number: 1, email: "alpha@example.com", windows: [] }],
        active: { number: 1 },
        allDeadAt: 1789000000,
        basis: "measured",
        computedAt: 1788999000,
        drainOrder: [1, 2],
      },
    });

    expect(decoded.forecast?.drainOrder).toEqual([1, 2]);
    expect(decoded.forecast?.basis).toBe("measured");
  });

  it("decodes the null forecast the app sends when it has nothing to project", () => {
    expect(decodeForecast({ forecast: null }).forecast).toBeNull();
  });

  it("decodes a forecast with no active account and no measurable pace", () => {
    const decoded = decodeForecast({ forecast: { computedAt: 1788999000, basis: "no pace yet" } });

    expect(decoded.forecast?.active).toBeUndefined();
    expect(decoded.forecast?.allDeadAt).toBeUndefined();
    expect(decoded.forecast?.basis).toBe("no pace yet");
  });
});

describe("InfinitusSession", () => {
  it("decodes a session with only the keys the app always sends", () => {
    const decoded = decodeSession({ pid: 4242, cwd: "/Users/dev/code/app", kind: "claude" });

    expect(decoded.name).toBeUndefined();
    expect(decoded.status).toBeUndefined();
    expect(decoded.cwd).toBe("/Users/dev/code/app");
  });

  it("accepts the explicit nulls the sessions reply writes for absent fields", () => {
    const decoded = decodeSession({
      pid: 4242,
      name: null,
      cwd: "/Users/dev/code/app",
      status: null,
      kind: "claude",
      profile: null,
      permissionMode: null,
    });

    expect(decoded.name).toBeNull();
    expect(decoded.permissionMode).toBeNull();
  });

  it("decodes a fully described session", () => {
    const decoded = decodeSession({
      pid: 4243,
      name: "docs sweep",
      cwd: "/Users/dev/code/app",
      status: "waiting",
      kind: "claude",
      permissionMode: "acceptEdits",
      profile: "review",
    });

    expect(decoded.permissionMode).toBe("acceptEdits");
    expect(decoded.profile).toBe("review");
  });

  it("rejects a session whose pid arrived as a string", () => {
    expect(() => decodeSession({ pid: "4242", cwd: "/Users/dev", kind: "claude" })).toThrow();
  });
});

describe("InfinitusManifest", () => {
  it("decodes the command table, including the effects beyond read and write", () => {
    const decoded = decodeManifest({
      schemaVersion: 1,
      commands: [
        {
          name: "manifest",
          args: [],
          options: [],
          effect: "read",
          summary: "This table as JSON, plus schemaVersion.",
          replyShape: "{schemaVersion, commands:[ControlCommand]}",
        },
        {
          name: "remove",
          args: ["<fleet>", "<n>"],
          options: ["--yes"],
          effect: "destructive",
          requires: "remove",
          summary: "Delete the credential from the engine.",
          replyShape: "{fleet}",
        },
        {
          name: "engine",
          args: ["cswap|swapd|cliproxy|9router", "on|off"],
          options: [],
          effect: "restart",
          summary: "Turn an engine on or off; the app relaunches.",
          replyShape: "{restarting:true}",
        },
      ],
    });

    expect(decoded.commands.map((command) => command.effect)).toEqual([
      "read",
      "destructive",
      "restart",
    ]);
    expect(decoded.commands[1]?.requires).toBe("remove");
    expect(decoded.commands[0]?.requires).toBeUndefined();
  });
});

describe("InfinitusControlReply", () => {
  it("reads a failure reply's message", () => {
    const decoded = decodeReply({
      schemaVersion: 1,
      ok: false,
      error: "no fleet named cswap/gemini",
      restarting: false,
    });

    expect(decoded.ok).toBe(false);
    expect(decoded.error).toBe("no fleet named cswap/gemini");
    expect(decoded.result).toBeUndefined();
  });

  it("treats a missing restarting flag as not restarting", () => {
    expect(decodeReply({ schemaVersion: 1, ok: true, result: { shown: true } }).restarting).toBe(
      false,
    );
  });

  it("carries a restart through", () => {
    expect(
      decodeReply({ schemaVersion: 1, ok: true, result: { restarting: true }, restarting: true })
        .restarting,
    ).toBe(true);
  });

  it("keeps a null result, which is a value and not an absent one", () => {
    expect(decodeReply({ schemaVersion: 1, ok: true, result: null }).result).toBeNull();
  });

  it("rejects a reply whose ok flag is not a boolean", () => {
    expect(() => decodeReply({ schemaVersion: 1, ok: "true" })).toThrow();
  });
});
