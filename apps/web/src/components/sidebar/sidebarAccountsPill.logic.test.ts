import type {
  InfinitusAccount,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import { sidebarAccountsPillView } from "./sidebarAccountsPill.logic";

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
    capabilities: ["switch"],
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

const usage = { fiveHour: { pct: 63 }, sevenDay: { pct: 94 } };

describe("sidebarAccountsPillView", () => {
  it("draws the active account's label and its fullest window", () => {
    const view = sidebarAccountsPillView({
      capability: true,
      snapshot: snapshot({
        fleets: [
          fleet({
            activeNumber: 2,
            accounts: [
              account({ number: 1, alias: "spare", usage }),
              account({ number: 2, alias: "daily", usage }),
            ],
          }),
        ],
      }),
    });

    expect(view).toEqual({
      text: "daily · 7d 94%",
      tooltip: "daily · 7d 94% used",
      offline: false,
    });
  });

  it("keeps the five-hour window when it is the tighter one", () => {
    const view = sidebarAccountsPillView({
      capability: true,
      snapshot: snapshot({
        fleets: [
          fleet({
            accounts: [
              account({
                active: true,
                alias: "daily",
                usage: { fiveHour: { pct: 81 }, sevenDay: { pct: 12 } },
              }),
            ],
          }),
        ],
      }),
    });

    expect(view?.text).toBe("daily · 5h 81%");
  });

  it("skips fleets with no account in use and falls through to the next", () => {
    const view = sidebarAccountsPillView({
      capability: true,
      snapshot: snapshot({
        fleets: [
          fleet({ key: "idle", accounts: [account({ number: 1, alias: "nobody" })] }),
          fleet({
            key: "codex",
            accounts: [account({ number: 4, active: true, email: "beta@example.com", usage })],
          }),
        ],
      }),
    });

    expect(view?.text).toBe("beta@example.com · 7d 94%");
  });

  it("shows the label alone when the engine reported no usable windows", () => {
    const view = sidebarAccountsPillView({
      capability: true,
      snapshot: snapshot({
        fleets: [fleet({ accounts: [account({ active: true, alias: "daily" })] })],
      }),
    });

    expect(view).toEqual({ text: "daily", tooltip: "daily", offline: false });
  });

  it("says Infinitus is offline, with the reason as its tooltip", () => {
    const view = sidebarAccountsPillView({
      capability: true,
      snapshot: snapshot({ available: false, unavailableReason: "socket refused" }),
    });

    expect(view).toEqual({
      text: "Infinitus offline",
      tooltip: "socket refused",
      offline: true,
    });
  });

  it("falls back to its own words when the app gave no reason", () => {
    const view = sidebarAccountsPillView({
      capability: true,
      snapshot: snapshot({ available: false }),
    });

    expect(view?.tooltip).toBe("Infinitus offline");
  });

  it("draws nothing while loading, without Infinitus, or with no fleets at all", () => {
    expect(sidebarAccountsPillView({ capability: true, snapshot: null })).toBeNull();
    expect(sidebarAccountsPillView({ capability: undefined, snapshot: snapshot() })).toBeNull();
    expect(sidebarAccountsPillView({ capability: false, snapshot: snapshot() })).toBeNull();
    expect(sidebarAccountsPillView({ capability: true, snapshot: snapshot() })).toBeNull();
  });

  it("draws nothing when no fleet has an account in use", () => {
    expect(
      sidebarAccountsPillView({
        capability: true,
        snapshot: snapshot({ fleets: [fleet({ accounts: [account({ alias: "idle" })] })] }),
      }),
    ).toBeNull();
  });
});
