import type { AccountRowModel } from "@t3tools/client-runtime/state/infinitusAccounts";
import { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import { describe, expect, it } from "vite-plus/test";

import {
  chipEnvironment,
  commandFailureMessage,
  homeChip,
  infinitusMacs,
  exhaustedCopy,
  macAccountsModel,
  rowBadges,
  rowMenuActions,
  switchConfirmation,
  windowTone,
} from "./accountsRoute.logic";

const macId = EnvironmentId.make("mac-1");
const NOW = Date.parse("2026-09-11T08:00:00Z");
const RESET = "2026-09-11T10:30:00.000Z";
/** Every account at its 5h limit until RESET. */
const exhaustedSnapshot: InfinitusSnapshot = {
  available: true,
  fleets: [
    {
      key: "cswap/claude",
      engineID: "cswap",
      provider: "claude",
      capabilities: ["switch"],
      activeNumber: 1,
      accounts: [
        {
          number: 1,
          alias: "death1",
          email: "one@example.com",
          isOrganization: false,
          active: true,
          usageStatus: "limited",
          usage: { fiveHour: { pct: 100, resetsAt: RESET } },
        },
      ],
    },
  ],
  sessions: [],
  commands: [],
};
const plainId = EnvironmentId.make("server-2");

const row: AccountRowModel = {
  number: 2,
  label: "death4",
  plan: "Max 20×",
  active: false,
  next: true,
  preferred: false,
  held: false,
  windows: [],
  scoped: [],
  freshness: "updated just now",
  actions: ["switch", "hold", "prefer", "rename"],
  reloginNeeded: false,
  email: "one@example.com",
};

const readySnapshot: InfinitusSnapshot = {
  available: true,
  fleets: [
    {
      key: "cswap/claude",
      engineID: "cswap",
      provider: "claude",
      capabilities: ["switch"],
      accounts: [
        {
          number: 1,
          email: "one@example.com",
          isOrganization: false,
          active: true,
          usageStatus: "ok",
        },
      ],
    },
  ],
  sessions: [],
  commands: [],
};

describe("infinitusMacs", () => {
  it("lists only the environments advertising the capability, with their connection", () => {
    const configs = new Map([
      [macId, { environment: { capabilities: { infinitus: true } } }],
      [plainId, { environment: { capabilities: {} } }],
    ]);
    const presentations = new Map([
      [macId, { entry: { target: { label: "Studio" } }, connection: { phase: "connecting" } }],
      [plainId, { entry: { target: { label: "Box" } }, connection: { phase: "connected" } }],
    ]);
    expect(infinitusMacs(configs, presentations)).toEqual([
      { environmentId: macId, label: "Studio", connected: false },
    ]);
  });

  it("skips an environment whose config has not arrived", () => {
    const presentations = new Map([
      [macId, { entry: { target: { label: "Studio" } }, connection: { phase: "connected" } }],
    ]);
    expect(infinitusMacs(new Map(), presentations)).toEqual([]);
  });
});

describe("macAccountsModel", () => {
  it("is loading before the first snapshot", () => {
    expect(macAccountsModel(null, NOW)).toMatchObject({ state: "loading", sections: [] });
  });

  it("carries the app's reason when it is unavailable", () => {
    const model = macAccountsModel(
      {
        available: false,
        unavailableReason: "the socket refused the connection",
        fleets: [],
        sessions: [],
        commands: [],
      },
      NOW,
    );
    expect(model.state).toBe("unavailable");
    expect(model.unavailableReason).toBe("the socket refused the connection");
  });

  it("is empty with no fleets and ready with one section per fleet", () => {
    expect(macAccountsModel({ ...readySnapshot, fleets: [] }, NOW).state).toBe("empty");
    const model = macAccountsModel(readySnapshot, NOW);
    expect(model.state).toBe("ready");
    expect(model.sections.map((section) => section.title)).toEqual(["claude (cswap)"]);
    expect(model.forecast).toBeNull();
  });
});

describe("rowMenuActions", () => {
  it("mirrors the row's actions in order, wording prefer by its current side", () => {
    expect(rowMenuActions(row, { canPrompt: true }).map((action) => action.title)).toEqual([
      "Switch to this account",
      "Hold",
      "Star (pick first)",
      "Rename…",
    ]);
    expect(
      rowMenuActions({ ...row, preferred: true, actions: ["prefer"] }, { canPrompt: true })[0]
        ?.title,
    ).toBe("Unstar");
    expect(rowMenuActions({ ...row, actions: ["unhold"] }, { canPrompt: true })[0]?.title).toBe(
      "Release hold",
    );
  });

  it("drops rename where no text prompt exists, and offers nothing for a row with no actions", () => {
    expect(rowMenuActions(row, { canPrompt: false }).map((action) => action.id)).toEqual([
      "switch",
      "hold",
      "prefer",
    ]);
    expect(rowMenuActions({ ...row, actions: [] }, { canPrompt: true })).toEqual([]);
  });
});

describe("row presentation", () => {
  it("names the switch confirmation after the fleet and the account", () => {
    expect(switchConfirmation(row, "claude").title).toBe("Switch claude to death4?");
  });

  it("orders badges active, next, held, starred", () => {
    expect(rowBadges({ ...row, active: true, held: true, preferred: true })).toEqual([
      "active",
      "next",
      "held",
      "starred",
    ]);
    expect(rowBadges({ ...row, next: false })).toEqual([]);
  });

  it("grades a window by how full it is", () => {
    expect(windowTone(12)).toBe("calm");
    expect(windowTone(70)).toBe("warm");
    expect(windowTone(90)).toBe("hot");
  });
});

describe("commandFailureMessage", () => {
  it("quotes a refused command and reads a relaunch as pending, not failed", () => {
    expect(
      commandFailureMessage(
        Cause.fail({ _tag: "InfinitusCommandFailed", error: "no such account", restarting: false }),
      ),
    ).toBe("no such account");
    expect(
      commandFailureMessage(
        Cause.fail({ _tag: "InfinitusCommandFailed", error: "", restarting: true }),
      ),
    ).toMatch(/relaunching/);
  });

  it("names an unreachable app and falls back to the error's own message", () => {
    expect(
      commandFailureMessage(Cause.fail({ _tag: "InfinitusUnavailable", path: "/x", cause: "y" })),
    ).toBe("Infinitus is not running on this Mac.");
    expect(commandFailureMessage(Cause.fail(new Error("socket hung up")))).toBe("socket hung up");
    expect(commandFailureMessage(Cause.fail(new Error("   ")))).toBe(
      "The command did not reach the Mac.",
    );
  });
});

describe("homeChip", () => {
  it("is silent while loading and muted when the app is unavailable", () => {
    expect(homeChip(null, NOW)).toBeNull();
    expect(homeChip({ available: false, fleets: [], sessions: [], commands: [] }, NOW)).toEqual({
      label: "Infinitus",
      pct: null,
      tone: "off",
      limited: false,
    });
  });

  it("names the active account and grades its fullest window", () => {
    const snapshot: InfinitusSnapshot = {
      ...readySnapshot,
      fleets: [
        {
          ...readySnapshot.fleets[0]!,
          activeNumber: 2,
          accounts: [
            {
              number: 1,
              email: "one@example.com",
              isOrganization: false,
              active: false,
              usageStatus: "ok",
            },
            {
              number: 2,
              alias: "death2",
              email: "two@example.com",
              isOrganization: false,
              active: true,
              usageStatus: "ok",
              usage: { fiveHour: { pct: 42 }, sevenDay: { pct: 91 } },
            },
          ],
        },
      ],
    };
    expect(homeChip(snapshot, NOW)).toEqual({
      label: "death2",
      pct: 91,
      tone: "hot",
      limited: false,
    });
  });

  it("has nothing to say for a fleet with no active account, and no pct without usage", () => {
    expect(
      homeChip({ ...readySnapshot, fleets: [{ ...readySnapshot.fleets[0]!, accounts: [] }] }, NOW),
    ).toBeNull();
    expect(homeChip(readySnapshot, NOW)).toEqual({
      label: "one@example.com",
      pct: null,
      tone: "calm",
      limited: false,
    });
  });
});

describe("chipEnvironment", () => {
  const macs = [
    { environmentId: macId, label: "Studio", connected: true },
    { environmentId: plainId, label: "Mini", connected: true },
  ];

  it("follows the selected environment when it is a Mac, else the first Mac", () => {
    expect(chipEnvironment(plainId, macs)?.label).toBe("Mini");
    expect(chipEnvironment(EnvironmentId.make("other"), macs)?.label).toBe("Studio");
    expect(chipEnvironment(null, macs)?.label).toBe("Studio");
    expect(chipEnvironment(null, [])).toBeNull();
  });
});

describe("exhausted band (#706)", () => {
  it("the model carries a band only for a fleet whose every account is at a limit", () => {
    expect(macAccountsModel(readySnapshot, NOW).bands.size).toBe(0);
    const bands = macAccountsModel(exhaustedSnapshot, NOW).bands;
    expect(bands.get("cswap/claude")).toEqual({ revivalAt: RESET, revivesFirst: "death1" });
    // Past the reset the reading belongs to a window that rolled: no band.
    expect(macAccountsModel(exhaustedSnapshot, Date.parse(RESET) + 1).bands.size).toBe(0);
  });

  it("the chip reads limited in the hot tone instead of the pct", () => {
    expect(homeChip(exhaustedSnapshot, NOW)).toEqual({
      label: "death1",
      pct: 100,
      tone: "hot",
      limited: true,
    });
  });

  it("the copy names the revival and who comes back first", () => {
    const time = new Date(RESET).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    expect(exhaustedCopy({ revivalAt: RESET, revivesFirst: "death1" }, NOW)).toBe(
      `All accounts exhausted · next revival ${time} (death1)`,
    );
    expect(exhaustedCopy({ revivalAt: RESET, revivesFirst: null }, NOW)).toBe(
      `All accounts exhausted · next revival ${time}`,
    );
    expect(exhaustedCopy({ revivalAt: RESET, revivesFirst: null }, NOW - 86_400_000)).toBe(
      `All accounts exhausted · next revival tomorrow at ${time}`,
    );
    expect(exhaustedCopy({ revivalAt: null, revivesFirst: null }, NOW)).toBe(
      "All accounts exhausted",
    );
  });
});
