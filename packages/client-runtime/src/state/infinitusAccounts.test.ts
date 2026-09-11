import type {
  InfinitusAccount,
  InfinitusAwsLogin,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  WAIT_ADD_STILL_RUNNING,
  accountCommandArgs,
  accountsPageState,
  addAccountCommandArgs,
  buildFleetSection,
  buildForecast,
  buildSignInRows,
  signInCommandArgs,
  snapshotOffersAdd,
  snapshotSignInRunning,
  waitAddCommandArgs,
  waitAddOutcome,
  type AccountAction,
  type AccountRowModel,
  type AccountsPageState,
  type FleetSectionModel,
  type ForecastModel,
  type SignInRowModel,
  type UsageWindowBar,
} from "./infinitusAccounts.ts";

const ALL_CAPABILITIES = ["switch", "hold", "rename", "prefer"];

function account(overrides: Partial<InfinitusAccount> = {}): InfinitusAccount {
  return {
    number: 1,
    email: "alpha@example.com",
    active: false,
    isOrganization: false,
    usageStatus: "ok",
    ...overrides,
  };
}

function fleet(overrides: Partial<InfinitusFleet> = {}): InfinitusFleet {
  return {
    key: "claude",
    engineID: "cswap",
    provider: "claude",
    capabilities: ALL_CAPABILITIES,
    accounts: [account()],
    ...overrides,
  };
}

function snapshot(overrides: Partial<InfinitusSnapshot> = {}): InfinitusSnapshot {
  return {
    available: true,
    fleets: [],
    sessions: [],
    commands: [],
    ...overrides,
  };
}

/** One built row, index-checked so a fixture that stops producing it fails
    where it broke rather than as an `undefined` further down. */
function rowAt(source: InfinitusFleet, index = 0): AccountRowModel {
  const row = buildFleetSection(source).rows[index];
  if (row === undefined) throw new Error(`no row ${index}`);
  return row;
}

const twoAccounts = fleet({
  activeNumber: 1,
  nextCandidate: 2,
  accounts: [
    account({ number: 2, email: "beta@example.com", alias: "beta" }),
    account({ number: 1, email: "alpha@example.com", active: true, plan: "Max 20x" }),
  ],
});

describe("fleet sections", () => {
  it("orders rows by number and marks the active and next accounts", () => {
    const section: FleetSectionModel = buildFleetSection(twoAccounts);
    expect(section.rows.map((row) => row.number)).toEqual([1, 2]);
    expect(rowAt(twoAccounts, 0)).toMatchObject({
      label: "alpha@example.com",
      active: true,
      next: false,
    });
    expect(rowAt(twoAccounts, 1)).toMatchObject({ label: "beta", active: false, next: true });
  });

  it("titles the section with the engine only when it differs from the provider", () => {
    expect(buildFleetSection(twoAccounts).title).toBe("claude (cswap)");
    expect(buildFleetSection(fleet({ engineID: "claude" })).title).toBe("claude");
  });

  it("falls back to the email when an alias is missing and nulls a missing plan", () => {
    const row = rowAt(fleet());
    expect(row.label).toBe("alpha@example.com");
    expect(row.plan).toBeNull();
  });

  it("passes the fleet's caveat through", () => {
    expect(buildFleetSection(fleet({ caveat: "read-only engine" })).caveat).toBe(
      "read-only engine",
    );
    expect(buildFleetSection(fleet()).caveat).toBeNull();
  });
});

describe("usage windows", () => {
  it("reads the rolling windows in order and keeps only named scoped ones", () => {
    const row = rowAt(
      fleet({
        accounts: [
          account({
            usage: {
              fiveHour: { pct: 12.4 },
              sevenDay: {
                pct: 63.5,
                countdown: "2h 14m",
                aheadOfPace: true,
                resetsAt: "2026-09-15T11:00:00Z",
              },
              scoped: [{ name: "opus", pct: 220 }, { pct: 9 }],
            },
          }),
        ],
      }),
    );
    const windows: ReadonlyArray<UsageWindowBar> = row.windows;
    expect(windows).toEqual([
      { name: "5h", pct: 12, countdown: null, aheadOfPace: null, resetsAt: null },
      {
        name: "7d",
        pct: 64,
        countdown: "2h 14m",
        aheadOfPace: true,
        resetsAt: "2026-09-15T11:00:00Z",
      },
    ]);
    expect(row.scoped).toEqual([
      { name: "opus", pct: 100, countdown: null, aheadOfPace: null, resetsAt: null },
    ]);
  });

  it("clamps a negative percentage to zero", () => {
    const row = rowAt(fleet({ accounts: [account({ usage: { fiveHour: { pct: -4 } } })] }));
    expect(row.windows).toEqual([
      { name: "5h", pct: 0, countdown: null, aheadOfPace: null, resetsAt: null },
    ]);
  });

  it("shows no windows and no freshness when usage is missing", () => {
    const row = rowAt(fleet());
    expect(row.windows).toEqual([]);
    expect(row.scoped).toEqual([]);
    expect(row.freshness).toBeNull();
  });

  it("shows no windows for a malformed usage payload instead of throwing", () => {
    for (const usage of ["not an object", 42, { fiveHour: "nope" }, { sevenDay: { pct: "80" } }]) {
      const row = rowAt(fleet({ accounts: [account({ usage })] }));
      expect(row.windows).toEqual([]);
      expect(row.scoped).toEqual([]);
    }
  });
});

describe("freshness", () => {
  it("dates a readable reading and reports an unusable one as unavailable", () => {
    const dated = (overrides: Partial<InfinitusAccount>) =>
      rowAt(fleet({ accounts: [account(overrides)] })).freshness;
    expect(dated({ usageAgeSeconds: 12 })).toBe("updated just now");
    expect(dated({ usageAgeSeconds: 380 })).toBe("updated 6 min ago");
    expect(dated({ usageAgeSeconds: 7_400 })).toBe("updated 2 hr ago");
    expect(dated({ usageAgeSeconds: 90_000 })).toBe("updated 1 day ago");
    expect(dated({ usageAgeSeconds: 200_000 })).toBe("updated 2 days ago");
    expect(dated({ usageStatus: "stale", usageAgeSeconds: 380 })).toBe("updated 6 min ago");
    expect(dated({ usageStatus: "relogin_required", usageAgeSeconds: 380 })).toBe(
      "usage unavailable",
    );
    expect(dated({ usageStatus: "error" })).toBe("usage unavailable");
  });
});

describe("row actions", () => {
  const actionsFor = (
    accountOverrides: Partial<InfinitusAccount>,
    capabilities: ReadonlyArray<string> = ALL_CAPABILITIES,
  ): ReadonlyArray<AccountAction> =>
    rowAt(fleet({ capabilities, accounts: [account(accountOverrides)] })).actions;

  it("offers nothing when the fleet declares no capabilities", () => {
    expect(actionsFor({ preferred: false }, [])).toEqual([]);
  });

  it("does not offer a switch to the account already in use", () => {
    expect(actionsFor({ active: true, preferred: false })).not.toContain("switch");
    expect(actionsFor({ preferred: false })).toContain("switch");
  });

  it("offers hold or unhold by the held flag, never both", () => {
    expect(actionsFor({ preferred: false })).toContain("hold");
    expect(actionsFor({ preferred: false })).not.toContain("unhold");
    expect(actionsFor({ disabled: true, preferred: false })).toContain("unhold");
    expect(actionsFor({ disabled: true, preferred: false })).not.toContain("hold");
    expect(actionsFor({ preferred: false }, ["switch"])).not.toContain("hold");
  });

  it("hides the pick-first star on an engine whose accounts carry no preferred knob", () => {
    expect(actionsFor({})).not.toContain("prefer");
    expect(actionsFor({ preferred: false })).toContain("prefer");
    expect(actionsFor({ preferred: true })).toContain("prefer");
  });

  it("reports the held flag on the row", () => {
    const row: AccountRowModel = rowAt(fleet({ accounts: [account({ disabled: true })] }));
    expect(row.held).toBe(true);
    expect(rowAt(fleet()).held).toBe(false);
  });
});

describe("command arguments", () => {
  const row = rowAt(twoAccounts, 1);

  it("targets the account by fleet and number", () => {
    expect(accountCommandArgs("claude", row, "switch")).toEqual({
      command: "switch",
      args: ["claude", "2"],
    });
    expect(accountCommandArgs("claude", row, "hold")).toEqual({
      command: "hold",
      args: ["claude", "2"],
    });
    expect(accountCommandArgs("claude", row, "unhold")).toEqual({
      command: "unhold",
      args: ["claude", "2"],
    });
  });

  it("sends rename the new alias", () => {
    expect(accountCommandArgs("claude", row, "rename", "gamma")).toEqual({
      command: "rename",
      args: ["claude", "2", "gamma"],
    });
  });

  it("refuses a rename with no alias", () => {
    expect(() => accountCommandArgs("claude", row, "rename")).toThrow("rename needs an alias");
  });

  it("toggles prefer to the side it is switching to", () => {
    expect(accountCommandArgs("claude", row, "prefer").args).toEqual(["claude", "2", "on"]);
    const preferred = rowAt(fleet({ accounts: [account({ number: 3, preferred: true })] }));
    expect(accountCommandArgs("claude", preferred, "prefer").args).toEqual(["claude", "3", "off"]);
  });
});

describe("add account and re-login", () => {
  const addCommand = {
    name: "add",
    args: ["<fleet>"],
    options: [],
    effect: "human" as const,
    summary: "",
    replyShape: "",
  };

  it("offers add on a fleet with the in-app sign-in, never off the engine's name", () => {
    expect(buildFleetSection(fleet({ capabilities: ["addOAuth"] })).canAdd).toBe(true);
    expect(buildFleetSection(fleet({ engineID: "cswap", capabilities: [] })).canAdd).toBe(false);
    expect(buildFleetSection(fleet({ capabilities: ["addToken"] })).canAdd).toBe(false);
  });

  it("marks a lapsed sign-in for re-login only where the fleet can run one", () => {
    const lapsed = account({ usageStatus: "relogin_required" });
    expect(rowAt(fleet({ capabilities: ["addOAuth"], accounts: [lapsed] })).reloginNeeded).toBe(
      true,
    );
    expect(rowAt(fleet({ capabilities: ["addOAuth"] })).reloginNeeded).toBe(false);
    expect(rowAt(fleet({ capabilities: [], accounts: [lapsed] })).reloginNeeded).toBe(false);
  });

  it("gates on the manifest listing add and reads the app's sign-in flag", () => {
    expect(snapshotOffersAdd(snapshot())).toBe(false);
    expect(snapshotOffersAdd(snapshot({ commands: [addCommand] }))).toBe(true);
    expect(snapshotSignInRunning(snapshot())).toBe(false);
    expect(
      snapshotSignInRunning(
        snapshot({
          status: {
            version: "1",
            sha: "a",
            socket: "/tmp/s",
            badge: "",
            playground: false,
            signInRunning: true,
            engines: {},
          },
        }),
      ),
    ).toBe(true);
  });

  it("shapes add and the short wait-add poll", () => {
    expect(addAccountCommandArgs("cswap/claude")).toEqual({
      command: "add",
      args: ["cswap/claude"],
      options: {},
    });
    expect(waitAddCommandArgs(5)).toEqual({
      command: "wait-add",
      args: [],
      options: { timeout: "5" },
    });
  });

  it("reads a wait-add reply and recognises the still-running refusal", () => {
    expect(waitAddOutcome({ done: true, error: null, fleets: [] })).toEqual({
      done: true,
      error: null,
    });
    expect(waitAddOutcome({ done: false, error: "timed out" })).toEqual({
      done: false,
      error: "timed out",
    });
    expect(waitAddOutcome({ done: true })).toEqual({ done: true, error: null });
    expect(waitAddOutcome({ nope: true })).toBeNull();
    expect(WAIT_ADD_STILL_RUNNING.test("timed out after 5s")).toBe(true);
    expect(WAIT_ADD_STILL_RUNNING.test("a sign-in is already running")).toBe(false);
  });
});

describe("forecast", () => {
  it("is null when the app has nothing to project", () => {
    expect(buildForecast(snapshot())).toBeNull();
    expect(buildForecast(snapshot({ forecast: { forecast: null } }))).toBeNull();
  });

  it("resolves the drain order through the fleets and dates the projection", () => {
    const model: ForecastModel | null = buildForecast(
      snapshot({
        fleets: [twoAccounts],
        forecast: {
          forecast: {
            basis: "5h pace",
            computedAt: 1_757_000_000,
            allDeadAt: 1_757_086_400,
            drainOrder: [1, 2, 7],
          },
        },
      }),
    );
    expect(model).toEqual({
      allDeadAt: "2025-09-05T15:33:20.000Z",
      computedAt: "2025-09-04T15:33:20.000Z",
      drainOrder: ["alpha@example.com", "beta", "#7"],
    });
  });

  it("empties the fields the app left out or shaped differently", () => {
    expect(
      buildForecast(
        snapshot({
          fleets: [twoAccounts],
          forecast: { forecast: { basis: "5h pace", computedAt: null, drainOrder: "later" } },
        }),
      ),
    ).toEqual({ allDeadAt: null, computedAt: null, drainOrder: [] });
  });
});

describe("page state", () => {
  it("answers for every outcome", () => {
    const state = (input: Parameters<typeof accountsPageState>[0]): AccountsPageState =>
      accountsPageState(input);
    expect(state({ capability: undefined, snapshot: null })).toBe("unsupported");
    expect(state({ capability: false, snapshot: snapshot() })).toBe("unsupported");
    expect(state({ capability: true, snapshot: null })).toBe("loading");
    expect(
      state({
        capability: true,
        snapshot: snapshot({ available: false, unavailableReason: "no socket" }),
      }),
    ).toBe("unavailable");
    expect(state({ capability: true, snapshot: snapshot() })).toBe("empty");
    expect(state({ capability: true, snapshot: snapshot({ fleets: [twoAccounts] }) })).toBe(
      "ready",
    );
  });
});

describe("sign-in rows", () => {
  function login(overrides: Partial<InfinitusAwsLogin> = {}): InfinitusAwsLogin {
    return {
      profile: "dev",
      flow: "deviceCode",
      pid: 101,
      sessionLabel: "api · feature/login",
      failedAt: "2026-09-10T08:00:00Z",
      ...overrides,
    };
  }

  it("is empty without the aws-logins field, offline, or with nothing lapsed", () => {
    expect(buildSignInRows(snapshot())).toEqual([]);
    expect(buildSignInRows(snapshot({ available: false, awsLogins: [login()] }))).toEqual([]);
    expect(buildSignInRows(snapshot({ awsLogins: [] }))).toEqual([]);
  });

  it("builds one idle row per tool and profile", () => {
    const rows = buildSignInRows(
      snapshot({
        awsLogins: [
          login(),
          login({ profile: "me@example.com", provider: "gcloud", flow: "relay", pid: 202 }),
        ],
      }),
    );
    const expected: ReadonlyArray<SignInRowModel> = [
      {
        key: "aws:dev",
        tool: "aws",
        toolLabel: "AWS",
        profile: "dev",
        failedAt: "2026-09-10T08:00:00Z",
        sessions: ["api · feature/login"],
        pid: 101,
        deviceCode: true,
        phase: "idle",
        url: null,
        userCode: null,
        message: null,
      },
      {
        key: "gcloud:me@example.com",
        tool: "gcloud",
        toolLabel: "gcloud",
        profile: "me@example.com",
        failedAt: "2026-09-10T08:00:00Z",
        sessions: ["api · feature/login"],
        pid: 202,
        deviceCode: false,
        phase: "idle",
        url: null,
        userCode: null,
        message: null,
      },
    ];
    expect(rows).toEqual(expected);
  });

  it("folds every session waiting on one profile into its row, latest lapse first", () => {
    const rows = buildSignInRows(
      snapshot({
        sessions: [{ pid: 303, name: "web", cwd: "/w", kind: "claude" }],
        awsLogins: [
          login({ pid: 101, failedAt: "2026-09-10T08:00:00Z" }),
          login({ pid: 303, sessionLabel: null, failedAt: "2026-09-10T09:30:00Z" }),
          login({ pid: 404, sessionLabel: null, failedAt: null }),
          login({ pid: 101, failedAt: "2026-09-10T08:00:00Z" }),
        ],
      }),
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      key: "aws:dev",
      failedAt: "2026-09-10T09:30:00Z",
      pid: 303,
      sessions: ["api · feature/login", "web", "pid 404"],
    });
  });

  it("carries the running login's phase, page and code", () => {
    const at = (phase: string, extra: Partial<NonNullable<InfinitusAwsLogin["state"]>> = {}) =>
      buildSignInRows(
        snapshot({
          awsLogins: [
            login({
              state: { profile: "dev", flow: "deviceCode", phase, startedAt: 1, ...extra },
            }),
          ],
        }),
      )[0]!;
    expect(at("starting")).toMatchObject({ phase: "starting", url: null, userCode: null });
    expect(
      at("waitingForCode", { url: "https://device.sso.example/", userCode: "ABCD-EFGH" }),
    ).toMatchObject({
      phase: "waiting",
      url: "https://device.sso.example/",
      userCode: "ABCD-EFGH",
    });
    expect(at("waitingForBrowser")).toMatchObject({ phase: "waiting" });
    expect(at("somethingNewer")).toMatchObject({ phase: "waiting" });
    expect(at("done")).toMatchObject({ phase: "done" });
    expect(at("failed", { message: "token endpoint refused" })).toMatchObject({
      phase: "failed",
      message: "token endpoint refused",
    });
  });

  it("starts a device-code profile flag-less and every other flow on the Mac's browser", () => {
    const [aws, gcloud, relay] = buildSignInRows(
      snapshot({
        awsLogins: [
          login(),
          login({ profile: "me@example.com", provider: "gcloud", flow: "relay", pid: null }),
          login({ profile: "legacy", flow: "relay", pid: 505 }),
        ],
      }),
    );
    expect(signInCommandArgs(aws!)).toEqual({
      command: "aws-login",
      args: ["dev"],
      options: { pid: "101" },
    });
    expect(signInCommandArgs(gcloud!)).toEqual({
      command: "gcloud-login",
      args: ["me@example.com"],
      options: { local: "true" },
    });
    expect(signInCommandArgs(relay!)).toEqual({
      command: "aws-login",
      args: ["legacy"],
      options: { local: "true", pid: "505" },
    });
  });
});
