import type { InfinitusAccount, InfinitusFleet } from "@infinitus/contracts/infinitus";
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
    expect(band).toEqual({ revivalAt: IN_2H, revivesFirst: "b", model: null });
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
    ).toEqual({ revivalAt: IN_2H, revivesFirst: "a", model: null });
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
    expect(band).toEqual({ revivalAt: IN_3D, revivesFirst: "a", model: null });
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
    ).toEqual({ revivalAt: IN_5H, revivesFirst: "c", model: null });
    expect(exhaustedBand(fleet([noReset]), NOW)).toEqual({
      revivalAt: null,
      revivesFirst: null,
      model: null,
    });
    // An implausibly far reset is a bad string, not a reviver.
    const farOut = account({ usage: { fiveHour: { pct: 100, resetsAt: "2027-01-01T00:00:00Z" } } });
    expect(exhaustedBand(fleet([farOut]), NOW)).toEqual({
      revivalAt: null,
      revivesFirst: null,
      model: null,
    });
  });

  it("names the model when one per-model window alone blocks every account", () => {
    const fable = (number: number, alias: string, fiveHourPct: number) =>
      account({
        number,
        alias,
        usage: {
          fiveHour: { pct: fiveHourPct, resetsAt: IN_2H },
          scoped: [{ name: "Fable", pct: 100, resetsAt: IN_3D }],
        },
      });
    expect(exhaustedBand(fleet([fable(1, "a", 20), fable(2, "b", 40)]), NOW)).toEqual({
      revivalAt: IN_3D,
      revivesFirst: "a",
      model: "Fable",
    });
    // A rolled per-model reading does not count; the still-maxed one names it.
    const rolled = account({
      alias: "c",
      usage: { scoped: [{ name: "Fable", pct: 100, resetsAt: "2026-09-11T09:00:00Z" }] },
    });
    expect(exhaustedBand(fleet([rolled]), NOW)).toBeNull();
    // A plan window maxed on any account, or two different models: the
    // generic verdict.
    const fiveHour = account({
      number: 3,
      alias: "c",
      usage: { fiveHour: { pct: 100, resetsAt: IN_2H } },
    });
    expect(exhaustedBand(fleet([fable(1, "a", 20), fiveHour]), NOW)?.model).toBeNull();
    const opus = account({
      number: 4,
      alias: "d",
      usage: { scoped: [{ name: "Opus", pct: 100, resetsAt: IN_5H }] },
    });
    expect(exhaustedBand(fleet([fable(1, "a", 20), opus]), NOW)?.model).toBeNull();
    // The engine-reviver fallback carries the model too.
    const unranked = account({
      number: 5,
      alias: "e",
      usage: { scoped: [{ name: "Fable", pct: 100 }] },
    });
    expect(exhaustedBand(fleet([unranked]), NOW)).toEqual({
      revivalAt: null,
      revivesFirst: null,
      model: "Fable",
    });
  });
});
