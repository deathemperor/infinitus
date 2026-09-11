import { describe, expect, it } from "vite-plus/test";

import { activityDays, dayLabel } from "./activity.logic";

const NOW = Date.parse("2026-09-11T12:00:00");

describe("dayLabel", () => {
  it("names today, yesterday, then the date, with the year once it differs", () => {
    expect(dayLabel(Date.parse("2026-09-11T01:00:00"), NOW)).toBe("Today");
    expect(dayLabel(Date.parse("2026-09-10T23:59:00"), NOW)).toBe("Yesterday");
    expect(dayLabel(Date.parse("2026-09-01T10:00:00"), NOW)).toBe("Sep 1");
    expect(dayLabel(Date.parse("2025-12-31T10:00:00"), NOW)).toBe("Dec 31, 2025");
  });
});

describe("activityDays", () => {
  it("sections consecutive rows by day and parks undated rows last", () => {
    const row = (id: string, at: string) => ({ id, at, kind: "other", icon: "", text: id });
    const days = activityDays(
      [
        row("a", "2026-09-11T10:00:00"),
        row("b", "2026-09-11T09:00:00"),
        row("c", "2026-09-10T09:00:00"),
        row("d", "not a date"),
      ],
      NOW,
    );
    expect(days.map((day) => [day.label, day.rows.map((r) => r.id)])).toEqual([
      ["Today", ["a", "b"]],
      ["Yesterday", ["c"]],
      ["Undated", ["d"]],
    ]);
  });
});
