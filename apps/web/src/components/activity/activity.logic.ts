import type { ActivityRow } from "@t3tools/client-runtime/state/infinitusActivity";

/** The log sectioned by local calendar day, newest day first, in row order. */
export interface ActivityDay {
  readonly label: string;
  readonly rows: ReadonlyArray<ActivityRow>;
}

const dateFormatter = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric" });
const dateWithYearFormatter = new Intl.DateTimeFormat("en-US", {
  month: "short",
  day: "numeric",
  year: "numeric",
});

function dayStart(ms: number): number {
  const date = new Date(ms);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/** "Today", "Yesterday", "Sep 9", "Dec 31, 2025" — local days, not 24 h windows. */
export function dayLabel(atMs: number, nowMs: number): string {
  const diff = Math.round((dayStart(nowMs) - dayStart(atMs)) / 86_400_000);
  if (diff <= 0) return "Today";
  if (diff === 1) return "Yesterday";
  const date = new Date(atMs);
  return date.getFullYear() === new Date(nowMs).getFullYear()
    ? dateFormatter.format(date)
    : dateWithYearFormatter.format(date);
}

/** Rows (already newest first) sectioned by day; an unparseable `at` lands
    in an "Undated" section at the end. */
export function activityDays(rows: ReadonlyArray<ActivityRow>, nowMs: number): ActivityDay[] {
  const days: ActivityDay[] = [];
  const undated: ActivityRow[] = [];
  let current: { label: string; rows: ActivityRow[] } | null = null;
  for (const row of rows) {
    const atMs = Date.parse(row.at);
    if (Number.isNaN(atMs)) {
      undated.push(row);
      continue;
    }
    const label = dayLabel(atMs, nowMs);
    if (current === null || current.label !== label) {
      current = { label, rows: [] };
      days.push(current);
    }
    current.rows.push(row);
  }
  if (undated.length > 0) days.push({ label: "Undated", rows: undated });
  return days;
}
