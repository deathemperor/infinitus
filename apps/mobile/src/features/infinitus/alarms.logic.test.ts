import type {
  InfinitusAccount,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  DEFAULT_LEAD_MS,
  alarmIsScheduled,
  leadMs,
  planAlarms,
  resetAlarms,
  swapAlarm,
} from "./alarms.logic";

const now = 1_800_000_000_000;
const hour = 3_600_000;

function account(
  n: number,
  five: number,
  resets: number | null,
  extra: Partial<InfinitusAccount> = {},
): InfinitusAccount {
  const resetsAt = resets === null ? undefined : new Date(resets).toISOString();
  return {
    number: n,
    email: `p${n}@x.com`,
    isOrganization: false,
    active: false,
    usageStatus: "ok",
    usage: { fiveHour: { pct: five, resetsAt }, sevenDay: { pct: 20, resetsAt } },
    ...extra,
  };
}

function fleet(accounts: InfinitusAccount[], activeNumber?: number): InfinitusFleet {
  return {
    key: "swapd/claude",
    engineID: "swapd",
    provider: "claude",
    capabilities: [],
    accounts,
    activeNumber,
  };
}

function snapshot(fleets: InfinitusFleet[], leadMinutes?: number): InfinitusSnapshot {
  return {
    available: true,
    fleets,
    sessions: [],
    commands: [],
    prefs:
      leadMinutes === undefined
        ? undefined
        : {
            sections: [],
            prefs: [
              {
                key: "revive_lead_minutes",
                type: "int",
                default: 10,
                value: leadMinutes,
                section: "push",
                effect: "live",
              },
            ],
          },
  };
}

describe("resetAlarms", () => {
  it("alarms an exhausted account ten minutes before its reset, live accounts not at all", () => {
    const reset = now + 3 * hour;
    const alarms = resetAlarms(
      fleet([account(1, 100, reset, { alias: "papaya" }), account(2, 40, reset)]),
      now,
      DEFAULT_LEAD_MS,
    );
    expect(alarms).toHaveLength(1);
    expect(alarms[0]?.id).toBe("infinitus-reset-swapd/claude-1");
    expect(alarms[0]?.fireAt).toBe(new Date(reset - DEFAULT_LEAD_MS).toISOString());
    expect(alarms[0]?.title).toBe("papaya resets in 10 min");
    expect(alarms[0]?.body).toMatch(/^the session limit lifts at /);
  });

  it("takes the lead as a knob and names it in the title", () => {
    const reset = now + 3 * hour;
    const alarms = resetAlarms(
      fleet([account(1, 100, reset, { alias: "papaya" })]),
      now,
      30 * 60_000,
    );
    expect(alarms.map((alarm) => alarm.fireAt)).toEqual([
      new Date(reset - 30 * 60_000).toISOString(),
    ]);
    expect(alarms[0]?.title).toBe("papaya resets in 30 min");
    expect(resetAlarms(fleet([account(1, 100, now + 20 * 60_000)]), now, 30 * 60_000)).toEqual([]);
  });

  it("plans nothing inside the lead window, for a held account, or without a reset instant", () => {
    expect(
      resetAlarms(
        fleet([
          account(1, 100, now + 5 * 60_000),
          account(2, 100, now + hour, { disabled: true }),
          account(3, 100, null),
        ]),
        now,
        DEFAULT_LEAD_MS,
      ),
    ).toEqual([]);
  });

  it("follows the window that resets last when several are exhausted, naming a scoped model", () => {
    const soon = now + hour;
    const late = now + 5 * hour;
    const alarms = resetAlarms(
      fleet([
        {
          ...account(1, 100, soon),
          usage: {
            fiveHour: { pct: 100, resetsAt: new Date(soon).toISOString() },
            scoped: [{ pct: 100, resetsAt: new Date(late).toISOString(), name: "Opus" }],
          },
        },
      ]),
      now,
      DEFAULT_LEAD_MS,
    );
    expect(alarms[0]?.fireAt).toBe(new Date(late - DEFAULT_LEAD_MS).toISOString());
    expect(alarms[0]?.body).toMatch(/^the Opus limit lifts at /);
  });
});

describe("swapAlarm", () => {
  const accounts = [account(1, 0, null, { alias: "papaya" }), account(2, 0, null)];

  it("fires only between two looks that name a known account", () => {
    expect(swapAlarm(undefined, fleet(accounts, 1))).toBeNull();
    expect(swapAlarm(1, fleet(accounts, 1))).toBeNull();
    expect(swapAlarm(1, fleet(accounts, 9))).toBeNull();
    const swap = swapAlarm(2, fleet(accounts, 1));
    expect(swap?.title).toBe("swapped to papaya");
    expect(swap?.fireAt).toBeNull();
    expect(swap?.id).toBe("infinitus-swap-swapd/claude");
  });
});

describe("planAlarms / leadMs", () => {
  it("reads the Mac's revive lead from the prefs and falls back to ten minutes", () => {
    expect(leadMs(snapshot([], 25))).toBe(25 * 60_000);
    expect(leadMs(snapshot([]))).toBe(DEFAULT_LEAD_MS);
    expect(leadMs(snapshot([], 0))).toBe(DEFAULT_LEAD_MS);
  });

  it("combines resets and the swap across a snapshot pair, and plans nothing while unavailable", () => {
    const reset = now + 3 * hour;
    const before = snapshot([fleet([account(1, 100, reset), account(2, 0, null)], 2)]);
    const after = snapshot([fleet([account(1, 100, reset), account(2, 0, null)], 1)], 30);
    const alarms = planAlarms(after, before, now);
    expect(alarms.map((alarm) => alarm.id)).toEqual([
      "infinitus-reset-swapd/claude-1",
      "infinitus-swap-swapd/claude",
    ]);
    expect(alarms[0]?.title).toMatch(/resets in 30 min$/);
    expect(planAlarms({ ...after, available: false }, before, now)).toEqual([]);
  });
});

describe("alarmIsScheduled", () => {
  const alarm = {
    id: "infinitus-reset-f-1",
    fireAt: "2027-01-01T10:00:00.000Z",
    title: "",
    body: "",
  };

  it("matches only a request stamped with the same fire time", () => {
    expect(alarmIsScheduled({ infinitus: "accounts", fireAt: alarm.fireAt }, alarm)).toBe(true);
    expect(
      alarmIsScheduled({ infinitus: "accounts", fireAt: "2027-01-01T11:00:00.000Z" }, alarm),
    ).toBe(false);
    expect(alarmIsScheduled({ infinitus: "accounts" }, alarm)).toBe(false);
    expect(alarmIsScheduled(undefined, alarm)).toBe(false);
  });
});
