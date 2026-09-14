import { describe, expect, it } from "vite-plus/test";

import {
  isEnvironmentUnreachable,
  nextRetry,
  NO_RETRY,
  RETRY_CAP_MS,
  retryDelayMs,
} from "./pushRetry.logic";

describe("retryDelayMs", () => {
  it("walks the table and then holds at the cap", () => {
    expect([1, 2, 3, 4, 5, 40].map(retryDelayMs)).toEqual([
      5_000,
      15_000,
      60_000,
      RETRY_CAP_MS,
      RETRY_CAP_MS,
      RETRY_CAP_MS,
    ]);
  });

  it("treats a zeroth attempt as the first", () => {
    expect(retryDelayMs(0)).toBe(5_000);
  });
});

describe("nextRetry", () => {
  it("backs off further on each failure while the Mac is reachable", () => {
    let schedule = NO_RETRY;
    const delays: Array<number | null> = [];
    for (let round = 0; round < 5; round += 1) {
      schedule = nextRetry({ attempt: schedule.attempt, landed: false, connected: true });
      delays.push(schedule.delayMs);
    }
    expect(delays).toEqual([5_000, 15_000, 60_000, RETRY_CAP_MS, RETRY_CAP_MS]);
    expect(schedule.attempt).toBe(5);
  });

  it("stops once the token is on file", () => {
    expect(nextRetry({ attempt: 3, landed: true, connected: true })).toEqual(NO_RETRY);
  });

  it("schedules nothing while the Mac is unreachable, and starts over when it returns", () => {
    const offline = nextRetry({ attempt: 2, landed: false, connected: false });
    expect(offline).toEqual(NO_RETRY);
    expect(nextRetry({ attempt: offline.attempt, landed: false, connected: true }).delayMs).toBe(
      5_000,
    );
  });
});

describe("isEnvironmentUnreachable", () => {
  it("knows the RPC's own refusal to reach the Mac", () => {
    expect(
      isEnvironmentUnreachable({
        _tag: "EnvironmentRpcUnavailableError",
        message: "HyperNovae is not connected.",
      }),
    ).toBe(true);
  });

  it("leaves every other failure to be read as a refusal", () => {
    expect(isEnvironmentUnreachable({ _tag: "InfinitusCommandFailed" })).toBe(false);
    expect(isEnvironmentUnreachable(new Error("boom"))).toBe(false);
    expect(isEnvironmentUnreachable(null)).toBe(false);
    expect(isEnvironmentUnreachable("EnvironmentRpcUnavailableError")).toBe(false);
  });
});
