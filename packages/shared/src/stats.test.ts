import { describe, it, expect } from "vite-plus/test";
import { UsageDay, type StatsRequest, type StatsSnapshot } from "@infinitus/contracts";
import { mergeStats, statsWindow } from "./stats.ts";

const request: StatsRequest = {
  period: "week",
  today: UsageDay.make("2026-09-22"),
  timeZone: "UTC",
};
function snapshot(overrides: Partial<StatsSnapshot> = {}): StatsSnapshot {
  return {
    contractVersion: 1,
    ...statsWindow(request),
    timeZone: "UTC",
    readAt: "2026-09-22T12:00:00Z",
    historyFrom: "2024-07-01",
    activeDays: [],
    sessions: [],
    repositories: [],
    sources: [],
    pricing: { status: "fresh", source: "test", fetchedAt: null, knownModels: 1 },
    unavailable: [],
    ...overrides,
  };
}
describe("portable Stats", () => {
  it("uses calendar periods including leap years and Monday weeks", () => {
    expect(
      statsWindow({ ...request, period: "month", today: UsageDay.make("2024-02-29") }),
    ).toEqual({ from: "2024-02-01", to: "2024-02-29", previousFrom: "2024-01-01" });
    expect(statsWindow({ ...request, period: "year" })).toEqual({
      from: "2026-01-01",
      to: "2026-12-31",
      previousFrom: "2025-01-01",
    });
    expect(statsWindow(request)).toEqual({
      from: "2026-09-21",
      to: "2026-09-27",
      previousFrom: "2026-09-14",
    });
    expect(() => statsWindow({ ...request, today: UsageDay.make("2026-02-30") })).toThrow();
  });
  it("deduplicates moved sessions and clones, sums simultaneous peaks and recomputes ratios", () => {
    const minute = Date.parse("2026-09-22T10:00:00Z") / 60000;
    const session = {
      id: "codex:s1",
      sourceId: "mac",
      updatedAt: 2,
      days: [
        {
          key: request.today,
          day: {
            sessions: ["codex:s1"],
            humanMessages: 2,
            outputTokens: 50,
            usd: 3,
            longestUnattended: 4,
          },
        },
      ],
      minutes: [[minute, 50] as const],
    };
    const repo = {
      id: "github.com/me/repo",
      complete: true,
      pullRequestsAvailable: true,
      commits: [
        {
          id: "sha",
          at: minute * 60000,
          added: 20,
          removed: 3,
          files: 2,
          coAuthored: false,
          revert: false,
        },
      ],
      pullRequests: [],
    };
    const a = snapshot({ sessions: [session], repositories: [repo] });
    const b = snapshot({
      sessions: [
        { ...session, updatedAt: 1 },
        {
          ...session,
          id: "claude:s2",
          days: [
            {
              key: request.today,
              day: {
                sessions: ["claude:s2"],
                humanMessages: 3,
                outputTokens: 70,
                usd: 4,
                longestUnattended: 8,
              },
            },
          ],
          minutes: [[minute, 70]],
        },
      ],
      repositories: [repo],
    });
    const result = mergeStats([a, b], request);
    expect(result.total).toMatchObject({
      commits: 1,
      outputTokens: 120,
      usd: 7,
      humanMessages: 5,
      peakTokensPerMinute: 120,
      longestUnattended: 8,
      linesAdded: 20,
    });
    expect(result.total.sessions).toHaveLength(2);
    expect(mergeStats([a], request).total.usd).toBe(3);
  });
  it("counts streaks from activity across machines and excludes mismatched reporting windows", () => {
    const a = snapshot({
      sessions: [
        {
          id: "a",
          sourceId: "a",
          updatedAt: 1,
          days: [{ key: "2026-09-21", day: { humanMessages: 1 } }],
          minutes: [],
        },
      ],
    });
    const b = snapshot({
      sessions: [
        {
          id: "b",
          sourceId: "b",
          updatedAt: 1,
          days: [{ key: "2026-09-22", day: { humanMessages: 1 } }],
          minutes: [],
        },
      ],
    });
    expect(mergeStats([a, b], request).streak).toBe(2);
    expect(mergeStats([a, { ...b, timeZone: "Asia/Tokyo" }], request).total.humanMessages).toBe(1);
  });
});

it("counts streak history outside Today and marks a retained-history boundary", () => {
  const todayRequest = { ...request, period: "day" as const };
  const history = snapshot({
    ...statsWindow(todayRequest),
    activeDays: ["2026-09-19", "2026-09-20", "2026-09-21", "2026-09-22"],
  });
  expect(mergeStats([history], todayRequest)).toMatchObject({ streak: 4, streakCapped: false });
  expect(mergeStats([{ ...history, historyFrom: "2026-09-19" }], todayRequest)).toMatchObject({
    streak: 4,
    streakCapped: true,
  });
});

it("buckets fleet peaks in the requested timezone across a DST boundary", () => {
  const local = {
    ...request,
    today: UsageDay.make("2026-03-08"),
    period: "day" as const,
    timeZone: "America/Los_Angeles",
  };
  const minutes = [
    [Date.parse("2026-03-08T07:59:00Z") / 60000, 100],
    [Date.parse("2026-03-08T10:01:00Z") / 60000, 50],
  ] as const;
  const history = snapshot({
    ...statsWindow(local),
    timeZone: local.timeZone,
    sessions: [{ id: "s", sourceId: "s", updatedAt: 1, days: [], minutes }],
  });
  const result = mergeStats([history], local);
  expect(result.previous.peakTokensPerMinute).toBe(100);
  expect(result.total.peakTokensPerMinute).toBe(50);
});
