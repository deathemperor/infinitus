import type {
  InfinitusAccount,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  accountCommandArgs,
  accountsPageState,
  buildFleetSection,
  buildForecast,
  type AccountAction,
  type AccountRowModel,
  type AccountsPageState,
  type FleetSectionModel,
  type ForecastModel,
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
              sevenDay: { pct: 63.5, countdown: "2h 14m", aheadOfPace: true },
              scoped: [{ name: "opus", pct: 220 }, { pct: 9 }],
            },
          }),
        ],
      }),
    );
    const windows: ReadonlyArray<UsageWindowBar> = row.windows;
    expect(windows).toEqual([
      { name: "5h", pct: 12, countdown: null, aheadOfPace: null },
      { name: "7d", pct: 64, countdown: "2h 14m", aheadOfPace: true },
    ]);
    expect(row.scoped).toEqual([{ name: "opus", pct: 100, countdown: null, aheadOfPace: null }]);
  });

  it("clamps a negative percentage to zero", () => {
    const row = rowAt(fleet({ accounts: [account({ usage: { fiveHour: { pct: -4 } } })] }));
    expect(row.windows).toEqual([{ name: "5h", pct: 0, countdown: null, aheadOfPace: null }]);
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
