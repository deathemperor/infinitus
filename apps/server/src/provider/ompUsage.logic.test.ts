import { describe, expect, it } from "@effect/vitest";

import { ompCapacityToUsageLimits } from "./ompUsage.logic.ts";

const checkedAt = "2026-09-15T12:00:00.000Z";

const TWO_PROVIDER_CAPACITY = {
  capacity: {
    "google-antigravity": [
      {
        window: "5h",
        durationMs: 18_000_000,
        accounts: 1,
        usedAccounts: 0,
        remainingAccounts: 1,
      },
      {
        window: "7d",
        durationMs: 604_800_000,
        accounts: 1,
        usedAccounts: 0.0355,
        remainingAccounts: 0.9645,
      },
    ],
    zai: [
      {
        window: "5h",
        durationMs: 18_000_000,
        accounts: 2,
        usedAccounts: 1,
        remainingAccounts: 1,
      },
      {
        window: "30d",
        durationMs: 2_592_000_000,
        accounts: 2,
        usedAccounts: 0.4,
        remainingAccounts: 1.6,
      },
    ],
  },
};

describe("ompCapacityToUsageLimits", () => {
  it("maps a two-provider capacity into one window per provider per window id", () => {
    const result = ompCapacityToUsageLimits(TWO_PROVIDER_CAPACITY, checkedAt);
    expect(result.unavailable).toBeUndefined();
    expect(result.checkedAt).toBe(checkedAt);

    const byId = Object.fromEntries(result.windows.map((window) => [window.id, window]));
    expect(Object.keys(byId).sort()).toEqual([
      "google-antigravity:5h",
      "google-antigravity:7d",
      "zai:30d",
      "zai:5h",
    ]);

    expect(byId["google-antigravity:5h"]).toEqual({
      id: "google-antigravity:5h",
      kind: "session",
      label: "google-antigravity · Session",
      usedPercent: 0,
      windowDurationMins: 300,
    });
    expect(byId["google-antigravity:7d"]).toMatchObject({
      kind: "weekly",
      label: "google-antigravity · Weekly",
      windowDurationMins: 10_080,
    });
    expect(byId["google-antigravity:7d"]?.usedPercent).toBeCloseTo(3.55, 10);
    expect(byId["zai:5h"]).toMatchObject({
      kind: "session",
      label: "zai · Session",
      usedPercent: 50,
    });
    expect(byId["zai:30d"]).toMatchObject({
      kind: "monthly",
      label: "zai · Monthly",
      usedPercent: 20,
      windowDurationMins: 43_200,
    });

    for (const window of result.windows) {
      expect(window.label).toContain(window.id.slice(0, window.id.indexOf(":")));
    }
  });

  it("maps both window vocabularies onto the matching kind", () => {
    const result = ompCapacityToUsageLimits(
      {
        capacity: {
          mixed: [
            { window: "5h", accounts: 1, usedAccounts: 0, durationMs: 18_000_000 },
            { window: "weekly", accounts: 1, usedAccounts: 0.2, durationMs: 604_800_000 },
            { window: "7d", accounts: 1, usedAccounts: 0.3, durationMs: 604_800_000 },
            { window: "1mo", accounts: 1, usedAccounts: 0.4, durationMs: 2_592_000_000 },
            { window: "30d", accounts: 1, usedAccounts: 0.5, durationMs: 2_592_000_000 },
            { window: "monthly", accounts: 1, usedAccounts: 0.6, durationMs: 2_592_000_000 },
            { window: "custom", accounts: 1, usedAccounts: 0.1, durationMs: 1_000 },
          ],
        },
      },
      checkedAt,
    );

    const kindById = Object.fromEntries(result.windows.map((window) => [window.id, window.kind]));
    expect(kindById).toEqual({
      "mixed:5h": "session",
      "mixed:weekly": "weekly",
      "mixed:7d": "weekly",
      "mixed:1mo": "monthly",
      "mixed:30d": "monthly",
      "mixed:monthly": "monthly",
      "mixed:custom": "other",
    });
    expect(result.windows.find((window) => window.id === "mixed:custom")?.label).toBe(
      "mixed · custom",
    );
  });

  it("does not produce NaN or Infinity when accounts is 0", () => {
    const result = ompCapacityToUsageLimits(
      {
        capacity: {
          empty: [{ window: "5h", accounts: 0, usedAccounts: 0, durationMs: 18_000_000 }],
        },
      },
      checkedAt,
    );
    expect(result.windows).toHaveLength(1);
    const usedPercent = result.windows[0]?.usedPercent;
    expect(Number.isFinite(usedPercent)).toBe(true);
    expect(usedPercent).toBe(0);
  });

  it("drops malformed and unknown entries rather than throwing", () => {
    expect(() => ompCapacityToUsageLimits(null, checkedAt)).not.toThrow();
    expect(() => ompCapacityToUsageLimits([], checkedAt)).not.toThrow();
    expect(() => ompCapacityToUsageLimits("nope", checkedAt)).not.toThrow();
    expect(() =>
      ompCapacityToUsageLimits({ capacity: { broken: "not-an-array" } }, checkedAt),
    ).not.toThrow();

    const result = ompCapacityToUsageLimits(
      {
        capacity: {
          "": [{ window: "5h", accounts: 1, usedAccounts: 0 }],
          ok: [
            "skip-me",
            { window: "5h" },
            { accounts: 1, usedAccounts: 0 },
            { window: "5h", accounts: "1", usedAccounts: 0 },
            { window: "5h", accounts: -1, usedAccounts: 0 },
            { window: "5h", accounts: 1, usedAccounts: 0.25, durationMs: 18_000_000 },
          ],
        },
      },
      checkedAt,
    );
    expect(result.unavailable).toBeUndefined();
    expect(result.windows).toEqual([
      {
        id: "ok:5h",
        kind: "session",
        label: "ok · Session",
        usedPercent: 25,
        windowDurationMins: 300,
      },
    ]);
  });

  it("reports unsupported when capacity is missing or empty", () => {
    expect(ompCapacityToUsageLimits({}, checkedAt)).toEqual({
      checkedAt,
      windows: [],
      unavailable: { reason: "unsupported" },
    });
    expect(ompCapacityToUsageLimits({ capacity: {} }, checkedAt)).toEqual({
      checkedAt,
      windows: [],
      unavailable: { reason: "unsupported" },
    });
  });

  it("never puts an email in a fixture or the mapped result", () => {
    const payload = {
      capacity: {
        zai: [{ window: "5h", accounts: 1, usedAccounts: 0, durationMs: 18_000_000 }],
      },
      reports: [
        {
          provider: "zai",
          fetchedAt: 1,
          limits: [],
          metadata: { endpoint: "https://example.invalid", projectId: "p" },
        },
      ],
    };
    expect(JSON.stringify(TWO_PROVIDER_CAPACITY)).not.toMatch(/email|@/i);
    expect(JSON.stringify(payload)).not.toMatch(/email|@/i);
    const result = ompCapacityToUsageLimits(payload, checkedAt);
    expect(JSON.stringify(result)).not.toMatch(/email|@/i);
    expect(result.windows).toHaveLength(1);
  });
});
