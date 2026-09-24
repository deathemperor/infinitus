import type { InfinitusAccount, InfinitusFleet } from "@infinitus/contracts/infinitus";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import { buildFleetSection } from "./infinitusAccounts.ts";
import { quotaTimelineLanes, quotaTimelineRange } from "./infinitusQuotaTimeline.ts";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
// Thursday 24 September 2026, 17:11 in Ho Chi Minh City (UTC+7, no DST).
const NOW = Date.parse("2026-09-24T10:11:00Z");
const ZONE = { timeZone: "Asia/Ho_Chi_Minh" };

function fleet(accounts: InfinitusAccount[]): InfinitusFleet {
  return { key: "claude", engineID: "swapd", provider: "claude", capabilities: [], accounts };
}

function account(overrides: Partial<InfinitusAccount>): InfinitusAccount {
  return {
    number: 1,
    email: "a@example.com",
    active: false,
    isOrganization: false,
    usageStatus: "ok",
    ...overrides,
  };
}

const iso = (ms: number) => DateTime.formatIso(DateTime.makeUnsafe(ms));

describe("quotaTimelineRange", () => {
  it("spans two weeks from the start of the local week and steps a week at a time", () => {
    const range = quotaTimelineRange("weekly", NOW, 0, ZONE);
    expect(range.from).toBe(Date.parse("2026-09-20T00:00:00+07:00"));
    expect(range.to).toBe(Date.parse("2026-10-04T00:00:00+07:00"));
    expect(range.ticks).toHaveLength(14);
    expect(range.current).toBe(true);

    const next = quotaTimelineRange("weekly", NOW, 1, { ...ZONE, weekStartsOn: 1 });
    expect(next.from).toBe(Date.parse("2026-09-28T00:00:00+07:00"));
    expect(next.current).toBe(false);
  });

  it("spans a day around the current hour in the five-hour view", () => {
    const range = quotaTimelineRange("fiveHour", NOW, 0, ZONE);
    expect(range.from).toBe(Date.parse("2026-09-24T05:00:00+07:00"));
    expect(range.to - range.from).toBe(DAY);
    expect(range.ticks).toHaveLength(24);
    expect(quotaTimelineRange("fiveHour", NOW, -1, ZONE).from).toBe(range.from - 12 * HOUR);
  });
});

describe("quotaTimelineLanes", () => {
  const weekly = quotaTimelineRange("weekly", NOW, 0, ZONE);

  it("draws the week that is running, the rolled one from history and the ones ahead", () => {
    const resetsAt = NOW + 4 * DAY;
    const section = buildFleetSection(
      fleet([account({ usage: { sevenDay: { pct: 31, resetsAt: iso(resetsAt) } } })]),
    );
    const [lane] = quotaTimelineLanes({
      sections: [section],
      generations: [
        { email: "a@example.com", window: "7d", resetAt: (NOW - 3 * DAY) / 1000, finalPct: 88 },
      ],
      fiveHourWindows: [],
      view: "weekly",
      range: weekly,
      nowMs: NOW,
    });
    expect(lane?.segments.map(({ kind, start, end, pct }) => ({ kind, start, end, pct }))).toEqual([
      { kind: "elapsed", start: NOW - 10 * DAY, end: NOW - 3 * DAY, pct: 88 },
      { kind: "current", start: resetsAt - 7 * DAY, end: resetsAt, pct: 31 },
      { kind: "upcoming", start: resetsAt, end: resetsAt + 7 * DAY, pct: null },
    ]);
  });

  it("ends a window cut short where the next one opened", () => {
    const resetsAt = NOW + 6 * DAY;
    const [lane] = quotaTimelineLanes({
      sections: [
        buildFleetSection(
          fleet([account({ usage: { sevenDay: { pct: 5, resetsAt: iso(resetsAt) } } })]),
        ),
      ],
      // The window a banked reset ended still names the reset it would have had.
      generations: [
        { email: "a@example.com", window: "7d", resetAt: (NOW + 2 * DAY) / 1000, finalPct: 100 },
      ],
      fiveHourWindows: [],
      view: "weekly",
      range: weekly,
      nowMs: NOW,
    });
    expect(lane?.segments.map(({ kind, end, pct }) => ({ kind, end, pct }))).toEqual([
      { kind: "elapsed", end: resetsAt - 7 * DAY, pct: 100 },
      { kind: "current", end: resetsAt, pct: 5 },
      { kind: "upcoming", end: resetsAt + 7 * DAY, pct: null },
    ]);
  });

  it("skips history that is the running window itself", () => {
    // The Mac closed it on a reading a minute early; the engine still runs it.
    const resetsAt = NOW + 60_000;
    const [lane] = quotaTimelineLanes({
      sections: [
        buildFleetSection(
          fleet([account({ usage: { sevenDay: { pct: 5, resetsAt: iso(resetsAt) } } })]),
        ),
      ],
      generations: [
        { email: "a@example.com", window: "7d", resetAt: (NOW - 30_000) / 1000, finalPct: 4 },
      ],
      fiveHourWindows: [],
      view: "weekly",
      range: weekly,
      nowMs: NOW,
    });
    expect(lane?.segments.map((segment) => segment.kind)).toEqual([
      "current",
      "upcoming",
      "upcoming",
    ]);
  });

  it("predicts the next 5h windows only for an account kept warm", () => {
    const range = quotaTimelineRange("fiveHour", NOW, 0, ZONE);
    const resetsAt = NOW + 2 * HOUR;
    const usage = { fiveHour: { pct: 72, resetsAt: iso(resetsAt) } };
    const lanes = quotaTimelineLanes({
      sections: [
        buildFleetSection(
          fleet([
            account({ number: 1, usage }),
            account({ number: 2, email: "b@example.com", usage, autoIgnite: true }),
          ]),
        ),
      ],
      generations: [],
      fiveHourWindows: [
        {
          email: "a@example.com",
          start: (NOW - 9 * HOUR) / 1000,
          resetsAt: (NOW - 4 * HOUR) / 1000,
          peakPct: 100,
          samples: 40,
          closed: true,
        },
      ],
      view: "fiveHour",
      range,
      nowMs: NOW,
    });
    expect(lanes[0]?.segments.map((segment) => segment.kind)).toEqual(["elapsed", "current"]);
    expect(lanes[1]?.segments.map((segment) => segment.kind)).toEqual([
      "current",
      "upcoming",
      "upcoming",
    ]);
  });

  it("draws nothing current for a reading whose reset already passed", () => {
    const [lane] = quotaTimelineLanes({
      sections: [
        buildFleetSection(
          fleet([account({ usage: { sevenDay: { pct: 100, resetsAt: iso(NOW - HOUR) } } })]),
        ),
      ],
      generations: [],
      fiveHourWindows: [],
      view: "weekly",
      range: weekly,
      nowMs: NOW,
    });
    expect(lane?.segments).toEqual([]);
  });

  it("marks when the banked reset lapses, inside the range only", () => {
    const lanes = quotaTimelineLanes({
      sections: [
        buildFleetSection(
          fleet([
            account({ number: 1, resets: { available: 1, total: 1, endsAt: iso(NOW + 3 * DAY) } }),
            account({ number: 2, resets: { available: 1, total: 1, endsAt: iso(NOW + 30 * DAY) } }),
          ]),
        ),
      ],
      generations: [],
      fiveHourWindows: [],
      view: "weekly",
      range: weekly,
      nowMs: NOW,
    });
    expect(lanes.map((lane) => lane.resetExpiresAt)).toEqual([NOW + 3 * DAY, null]);
  });
});
