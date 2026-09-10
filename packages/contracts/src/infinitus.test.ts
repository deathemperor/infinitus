import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

import { ExecutionEnvironmentCapabilities } from "./environment.ts";
import {
  InfinitusActivityPushRegistration,
  InfinitusAwsLogins,
  InfinitusClientActivityReport,
  InfinitusCommandInput,
  InfinitusCommandResult,
  InfinitusControlReply,
  InfinitusCrashReport,
  InfinitusForecast,
  InfinitusFleet,
  InfinitusManifest,
  InfinitusPrefs,
  InfinitusRevivalActivityState,
  InfinitusSession,
  InfinitusSnapshot,
  InfinitusStatus,
  InfinitusWorkingActivityState,
} from "./infinitus.ts";

const decodeReply = Schema.decodeUnknownSync(InfinitusControlReply);
const decodeStatus = Schema.decodeUnknownSync(InfinitusStatus);
const decodeFleet = Schema.decodeUnknownSync(InfinitusFleet);
const decodeForecast = Schema.decodeUnknownSync(InfinitusForecast);
const decodeSession = Schema.decodeUnknownSync(InfinitusSession);
const decodeManifest = Schema.decodeUnknownSync(InfinitusManifest);
const decodePrefs = Schema.decodeUnknownSync(InfinitusPrefs);
const decodeSnapshot = Schema.decodeUnknownSync(InfinitusSnapshot);
const encodeSnapshot = Schema.encodeUnknownSync(InfinitusSnapshot);
const decodeEncodedSnapshot = Schema.decodeSync(InfinitusSnapshot);
const decodeCommandInput = Schema.decodeUnknownSync(InfinitusCommandInput);
const encodeCommandInput = Schema.encodeUnknownSync(InfinitusCommandInput);
const decodeCommandResult = Schema.decodeUnknownSync(InfinitusCommandResult);
const encodeCommandResult = Schema.encodeUnknownSync(InfinitusCommandResult);
const decodeCapabilities = Schema.decodeUnknownSync(ExecutionEnvironmentCapabilities);

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

  it("leaves the fork tunnel absent on a build before it", () => {
    expect(decodeStatus(status).forkTunnel).toBeUndefined();
  });

  it("decodes the fork tunnel, with its url only while up", () => {
    const up = decodeStatus({
      ...status,
      forkTunnel: {
        enabled: true,
        port: 3773,
        state: "up",
        url: "https://example-words.trycloudflare.com",
        hostname: "example-words.trycloudflare.com",
      },
    });
    expect(up.forkTunnel?.url).toBe("https://example-words.trycloudflare.com");

    const off = decodeStatus({
      ...status,
      forkTunnel: { enabled: false, port: 3773, state: "off" },
    });
    expect(off.forkTunnel?.state).toBe("off");
    expect(off.forkTunnel?.url).toBeUndefined();
  });

  it("keeps a tunnel state a newer build adds rather than dropping the status", () => {
    const decoded = decodeStatus({
      ...status,
      forkTunnel: { enabled: true, port: 3773, state: "reconnecting" },
    });
    expect(decoded.forkTunnel?.state).toBe("reconnecting");
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

describe("InfinitusPrefs", () => {
  it("decodes a catalog whose values are the scalars their type names", () => {
    const decoded = decodePrefs({
      sections: [
        { slug: "general", name: "General" },
        { slug: "popup", name: "Pop-out" },
      ],
      prefs: [
        {
          key: "launchAtLogin",
          type: "bool",
          default: false,
          value: true,
          section: "general",
          effect: "restart",
        },
        {
          key: "popupScale",
          type: "double",
          default: 1,
          value: 1.25,
          section: "popup",
          effect: "live",
        },
        {
          key: "badgeStyle",
          type: "string",
          default: "count",
          value: "dot",
          section: "popup",
          effect: "live",
          choices: ["count", "dot", "none"],
        },
      ],
    });

    expect(decoded.sections.map((section) => section.slug)).toEqual(["general", "popup"]);
    expect(decoded.prefs[0]?.value).toBe(true);
    expect(decoded.prefs[1]?.default).toBe(1);
    expect(decoded.prefs[2]?.choices).toEqual(["count", "dot", "none"]);
    // A pref that takes any value omits the key rather than sending [].
    expect(decoded.prefs[0]?.choices).toBeUndefined();
  });

  it("accepts a null choices list, which older builds send instead of omitting", () => {
    const decoded = decodePrefs({
      sections: [],
      prefs: [
        {
          key: "pollSeconds",
          type: "int",
          default: 30,
          value: 30,
          section: "general",
          effect: "live",
          choices: null,
        },
      ],
    });

    expect(decoded.prefs[0]?.choices).toBeNull();
  });

  it("rejects a pref whose type is not one of the four kinds", () => {
    expect(() =>
      decodePrefs({
        sections: [],
        prefs: [
          { key: "x", type: "date", default: 0, value: 0, section: "general", effect: "live" },
        ],
      }),
    ).toThrow();
  });
});

describe("InfinitusSnapshot", () => {
  it("expresses an unreachable app: no fields, empty lists, a reason", () => {
    const decoded = decodeSnapshot({
      available: false,
      unavailableReason: "ENOENT",
      fleets: [],
      sessions: [],
      commands: [],
    });

    expect(decoded.available).toBe(false);
    expect(decoded.unavailableReason).toBe("ENOENT");
    expect(decoded.status).toBeUndefined();
    expect(decoded.forecast).toBeUndefined();
    expect(decoded.prefs).toBeUndefined();
  });

  it("round-trips a reachable snapshot with prefs through the wire", () => {
    const snapshot = decodeSnapshot({
      available: true,
      status,
      fleets: [fleet],
      sessions: [],
      prefs: { sections: [{ slug: "general", name: "General" }], prefs: [] },
      commands: [],
    });

    expect(decodeEncodedSnapshot(encodeSnapshot(snapshot))).toEqual(snapshot);
    expect(snapshot.prefs?.sections[0]?.name).toBe("General");
  });
});

describe("the RPC payloads", () => {
  it("round-trips a command input", () => {
    const input = decodeCommandInput({
      command: "switch",
      args: ["cswap/claude", "2"],
      options: { yes: "true" },
    });

    expect(encodeCommandInput(input)).toEqual({
      command: "switch",
      args: ["cswap/claude", "2"],
      options: { yes: "true" },
    });
  });

  it("rejects a command input whose options are not strings", () => {
    expect(() =>
      decodeCommandInput({ command: "switch", args: [], options: { yes: true } }),
    ).toThrow();
  });

  it("carries any result shape, and none at all", () => {
    expect(decodeCommandResult({ result: { fleet: "cswap/claude" } }).result).toEqual({
      fleet: "cswap/claude",
    });
    expect(decodeCommandResult({}).result).toBeUndefined();
    expect(encodeCommandResult(decodeCommandResult({}))).toEqual({});
  });
});

describe("the infinitus capability", () => {
  it("decodes present, absent and false", () => {
    expect(decodeCapabilities({ repositoryIdentity: true, infinitus: true }).infinitus).toBe(true);
    expect(decodeCapabilities({ repositoryIdentity: true, infinitus: false }).infinitus).toBe(
      false,
    );
    expect(decodeCapabilities({ repositoryIdentity: true }).infinitus).toBeUndefined();
  });

  it("rejects a non-boolean capability", () => {
    expect(() => decodeCapabilities({ repositoryIdentity: true, infinitus: "yes" })).toThrow();
  });
});

describe("the phone-only write bodies", () => {
  const decodeRegistration = Schema.decodeUnknownSync(InfinitusActivityPushRegistration);
  const encodeRegistration = Schema.encodeUnknownSync(InfinitusActivityPushRegistration);
  const decodeActivity = Schema.decodeUnknownSync(InfinitusClientActivityReport);
  const decodeCrash = Schema.decodeUnknownSync(InfinitusCrashReport);

  // The keys the native phone sends today (NetworkFleetMirror, ISO 8601 dates).
  const registration = {
    kind: "working-start",
    token: "8f3a…c1",
    deviceId: "F3B1D2E4-0000-4000-8000-000000000001",
    deviceName: "Loc's iPhone",
    environment: "sandbox",
    themeID: "rpg",
    registeredAt: "2026-09-10T10:00:00Z",
    macId: "env-7c2f",
    layout: "expo",
  } as const;

  it("round-trips a token registration with every field", () => {
    const decoded = decodeRegistration(registration);
    expect(decoded.kind).toBe("working-start");
    expect(decoded.macId).toBe("env-7c2f");
    expect(encodeRegistration(decoded)).toEqual(registration);
  });

  it("accepts the null theme and the absent macId, layout and stamp an older phone sends", () => {
    const { macId: _macId, layout: _layout, registeredAt: _at, ...older } = registration;
    const decoded = decodeRegistration({ ...older, kind: "alert", themeID: null });
    expect(decoded.themeID).toBeNull();
    expect(decoded.macId).toBeUndefined();
    expect(decoded.layout).toBeUndefined();
    expect(decoded.registeredAt).toBeUndefined();
  });

  it("rejects a token kind the Mac has no slot for", () => {
    expect(() => decodeRegistration({ ...registration, kind: "widget" })).toThrow();
  });

  it("decodes a lease report whose scopes mix a pid and none", () => {
    const decoded = decodeActivity({
      clientId: "phone-1",
      visible: true,
      focused: true,
      recentlyInteracted: false,
      scopes: [{ type: "sessions" }, { type: "session", pid: 4243 }, { type: "fleets" }],
      ttlMs: 30_000,
    });
    expect(decoded.scopes[1]?.pid).toBe(4243);
    expect(decoded.scopes[0]?.pid).toBeUndefined();
  });

  it("rejects a scope kind the lease table does not know", () => {
    expect(() =>
      decodeActivity({
        clientId: "phone-1",
        visible: true,
        focused: true,
        recentlyInteracted: false,
        scopes: [{ type: "threads" }],
        ttlMs: 30_000,
      }),
    ).toThrow();
  });

  it("decodes a crash report with and without its raw diagnostic", () => {
    const report = {
      id: "3E5C…",
      platform: "ios",
      device: "iPhone",
      appVersion: "0.4.4",
      osVersion: "iOS 26.0",
      at: "2026-09-10T09:58:12Z",
      kind: "crash",
      reason: "EXC_BAD_ACCESS (SIGSEGV)",
      frames: ["Infinitus +0x1234 -[Foo bar]"],
    };
    expect(decodeCrash(report).raw).toBeUndefined();
    expect(decodeCrash({ ...report, raw: "{}" }).raw).toBe("{}");
  });
});

describe("the Live Activity content states", () => {
  const decodeWorking = Schema.decodeUnknownSync(InfinitusWorkingActivityState);
  const decodeRevival = Schema.decodeUnknownSync(InfinitusRevivalActivityState);

  it("decodes a working card the way the Mac's default encoder writes it", () => {
    const decoded = decodeWorking({
      active: "death2",
      icon: "bolt",
      slot: "P1",
      plan: "Max 20×",
      cash: null,
      windows: [
        { label: "5h", color: "green", pct: 0.42, reset: "1h10m·13:00" },
        { label: "7d", color: "amber", pct: 0.88, reset: null },
      ],
      binding: 1,
      busy: 2,
      total: 3,
      waiting: 0,
      next: "death4",
      tokensPerMinute: 1200,
      tokenFraction: 0.6,
      accent: "teal",
      plain: false,
    });
    expect(decoded.windows[1]?.pct).toBe(0.88);
    expect(decoded.rateIcon).toBeUndefined();
  });

  it("decodes a revival card whose revivesAt is seconds since 2001", () => {
    const decoded = decodeRevival({
      reviver: "death3",
      icon: null,
      revivesAt: 810_000_000,
      sessions: 4,
      waiting: 2,
      later: ["loc 2:50 PM"],
      reviveWord: "revives",
      deadWord: "is dead",
      accent: "red",
      revived: false,
    });
    expect(decoded.revivesAt).toBe(810_000_000);
    expect(decoded.later).toEqual(["loc 2:50 PM"]);
  });

  it("rejects a working card missing its window list", () => {
    expect(() =>
      decodeWorking({
        active: "a",
        slot: "P1",
        busy: 0,
        total: 0,
        waiting: 0,
        tokenFraction: 0,
        accent: "x",
        plain: true,
      }),
    ).toThrow();
  });
});

describe("InfinitusAwsLogins", () => {
  const decodeLogins = Schema.decodeUnknownSync(InfinitusAwsLogins);

  it("decodes a lapsed sign-in with a login in flight and one with none", () => {
    const decoded = decodeLogins({
      logins: [
        {
          profile: "papaya",
          flow: "relay",
          pid: 4243,
          sessionLabel: "limitless",
          state: {
            profile: "papaya",
            flow: "relay",
            phase: "waitingForBrowser",
            url: "https://device.sso.example/?user_code=ABCD",
            userCode: "ABCD-1234",
            callbackPort: 51234,
            message: null,
            startedAt: 1_800_000_000,
            pid: 4243,
          },
          account: { number: 1, email: "a@x.com" },
        },
        { profile: "default", provider: "gcloud", flow: "deviceCode", pid: null, state: null },
      ],
    });
    expect(decoded.logins[0]?.state?.userCode).toBe("ABCD-1234");
    expect(decoded.logins[1]?.provider).toBe("gcloud");
    expect(decoded.logins[1]?.state).toBeNull();
  });

  it("keeps a flow or phase it has never heard of, and rejects a missing profile", () => {
    expect(
      decodeLogins({
        logins: [
          {
            profile: "p",
            flow: "teleport",
            state: { profile: "p", flow: "teleport", phase: "levitating", startedAt: 1 },
          },
        ],
      }).logins[0]?.state?.phase,
    ).toBe("levitating");
    expect(() => decodeLogins({ logins: [{ flow: "relay" }] })).toThrow();
  });
});
