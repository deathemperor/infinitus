import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import { LIVE_RATE_WINDOW_MS, liveOutputRate } from "./liveRate.logic.ts";

const MIN = 60_000;
const NOW = DateTime.toEpochMillis(DateTime.makeUnsafe("2026-09-14T12:00:00.000Z"));
const iso = (ms: number) => DateTime.formatIso(DateTime.makeUnsafe(ms));
const at = (msBeforeNow: number) => iso(NOW - msBeforeNow);

describe("liveOutputRate (#1127)", () => {
  it("is null when no turn ran in the window", () => {
    expect(liveOutputRate([], NOW)).toBeNull();
    expect(liveOutputRate([{ outputTokens: 9000, completedAt: at(6 * MIN) }], NOW)).toBeNull();
  });

  it("spreads a turn wholly inside the window over the five minutes", () => {
    // 3000 output tokens, whatever the turn's own wall time: the window is
    // five minutes long, so the rate is the tokens it holds divided by five.
    expect(
      liveOutputRate([{ outputTokens: 3000, completedAt: at(MIN), durationMs: 2 * MIN }], NOW),
    ).toEqual({ perMinute: 600 });
  });

  it("counts a turn with no duration as a point at its completion", () => {
    expect(liveOutputRate([{ outputTokens: 500, completedAt: at(MIN) }], NOW)).toEqual({
      perMinute: 100,
    });
  });

  it("takes only the part of a straddling turn that lies inside the window", () => {
    // Ran ten minutes, finished at now-5min+1min: one of its ten minutes is
    // inside the window, so one tenth of its tokens count.
    expect(
      liveOutputRate(
        [{ outputTokens: 10_000, completedAt: at(4 * MIN), durationMs: 10 * MIN }],
        NOW,
      ),
    ).toEqual({ perMinute: 200 });
  });

  it("sums the turns that overlap and ignores the ones that do not", () => {
    expect(
      liveOutputRate(
        [
          { outputTokens: 1500, completedAt: at(MIN) },
          { outputTokens: 1000, completedAt: at(2 * MIN), durationMs: 30_000 },
          { outputTokens: 4000, completedAt: at(30 * MIN), durationMs: MIN },
        ],
        NOW,
      ),
    ).toEqual({ perMinute: 500 });
  });

  it("reads zero, not nothing, for a turn that ran and produced no output", () => {
    expect(liveOutputRate([{ outputTokens: 0, completedAt: at(MIN) }], NOW)).toEqual({
      perMinute: 0,
    });
  });

  it("leaves out a turn whose provider reported no usage", () => {
    // Cursor and Grok report none (#834): the row's zeros mean "not counted",
    // and a window holding only those must draw nothing, not a rate of zero.
    expect(
      liveOutputRate([{ outputTokens: 0, completedAt: at(MIN), usageUnavailable: true }], NOW),
    ).toBeNull();
    expect(
      liveOutputRate(
        [
          { outputTokens: 0, completedAt: at(MIN), usageUnavailable: true },
          { outputTokens: 2500, completedAt: at(2 * MIN) },
        ],
        NOW,
      ),
    ).toEqual({ perMinute: 500 });
  });

  it("drops a row whose completion cannot be read", () => {
    expect(liveOutputRate([{ outputTokens: 900, completedAt: "not a date" }], NOW)).toBeNull();
  });

  it("counts a turn stamped in the future as ending now", () => {
    // Clock skew between the recording server and this read must not make a
    // turn's tokens count for time that has not passed.
    expect(
      liveOutputRate([{ outputTokens: 1000, completedAt: iso(NOW + MIN), durationMs: MIN }], NOW),
    ).toEqual({ perMinute: 0 });
  });

  it("holds the window at five minutes", () => {
    expect(LIVE_RATE_WINDOW_MS).toBe(5 * MIN);
  });
});
