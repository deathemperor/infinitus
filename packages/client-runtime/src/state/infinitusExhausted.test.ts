import type { InfinitusAccount, InfinitusFleet } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import { exhaustedBand } from "./infinitusExhausted.ts";

const NOW = Date.parse("2026-09-11T10:00:00Z");
const IN_2H = "2026-09-11T12:00:00.000Z";
const IN_5H = "2026-09-11T15:00:00.000Z";
const IN_3D = "2026-09-14T10:00:00.000Z";

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

function fleet(
  accounts: InfinitusAccount[],
  overrides: Partial<InfinitusFleet> = {},
): InfinitusFleet {
  return {
    key: "claude",
    engineID: "swapd",
    provider: "claude",
    capabilities: [],
    accounts,
    ...overrides,
  };
}

describe("exhaustedBand", () => {
  it("names the earliest revival when every account is at a limit", () => {
    const band = exhaustedBand(
      fleet([
        account({ number: 1, alias: "a", usage: { fiveHour: { pct: 100, resetsAt: IN_5H } } }),
        account({ number: 2, alias: "b", usage: { sevenDay: { pct: 100, resetsAt: IN_2H } } }),
      ]),
      NOW,
    );
    expect(band).toEqual({ revivalAt: IN_2H, revivesFirst: "b" });
  });

  it("stays away while one unheld account still has room", () => {
    const band = exhaustedBand(
      fleet([
        account({ number: 1, usage: { fiveHour: { pct: 100, resetsAt: IN_2H } } }),
        account({ number: 2, usage: { fiveHour: { pct: 40 } } }),
      ]),
      NOW,
    );
    expect(band).toBeNull();
  });

  it("skips held accounts and treats an account with no reading as not exhausted", () => {
    const dead = account({
      number: 1,
      alias: "a",
      usage: { fiveHour: { pct: 100, resetsAt: IN_2H } },
    });
    expect(
      exhaustedBand(
        fleet([dead, account({ number: 2, disabled: true, usage: { fiveHour: { pct: 3 } } })]),
        NOW,
      ),
    ).toEqual({ revivalAt: IN_2H, revivesFirst: "a" });
    expect(
      exhaustedBand(fleet([dead, account({ number: 2, usageStatus: "error" })]), NOW),
    ).toBeNull();
    expect(exhaustedBand(fleet([account({ disabled: true })]), NOW)).toBeNull();
  });

  it("an account revives only when its LAST maxed window rolls, including per-model ones", () => {
    const band = exhaustedBand(
      fleet([
        account({
          alias: "a",
          usage: {
            fiveHour: { pct: 100, resetsAt: IN_2H },
            scoped: [{ name: "opus", pct: 100, resetsAt: IN_3D }],
          },
        }),
      ]),
      NOW,
    );
    expect(band).toEqual({ revivalAt: IN_3D, revivesFirst: "a" });
  });

  it("a maxed window whose reset has passed no longer counts", () => {
    const band = exhaustedBand(
      fleet([account({ usage: { sevenDay: { pct: 100, resetsAt: "2026-09-11T09:00:00Z" } } })]),
      NOW,
    );
    expect(band).toBeNull();
  });

  it("falls back to the engine's reviver when no account reset can be ranked, else shows no time", () => {
    const noReset = account({ number: 3, alias: "c", usage: { fiveHour: { pct: 100 } } });
    expect(
      exhaustedBand(fleet([noReset], { nextRecovery: { number: 3, at: IN_5H } }), NOW),
    ).toEqual({ revivalAt: IN_5H, revivesFirst: "c" });
    expect(exhaustedBand(fleet([noReset]), NOW)).toEqual({ revivalAt: null, revivesFirst: null });
    // An implausibly far reset is a bad string, not a reviver.
    const farOut = account({ usage: { fiveHour: { pct: 100, resetsAt: "2027-01-01T00:00:00Z" } } });
    expect(exhaustedBand(fleet([farOut]), NOW)).toEqual({ revivalAt: null, revivesFirst: null });
  });
});
