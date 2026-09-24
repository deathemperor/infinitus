import type {
  InfinitusUtilizationFiveHourWindow,
  InfinitusUtilizationGeneration,
} from "@infinitus/contracts/infinitus";
import * as DateTime from "effect/DateTime";

import type { FleetSectionModel, UsageWindowBar } from "./infinitusAccounts.ts";

/**
 * The Accounts page's quota-window timeline: every account a lane, every
 * usage window a bar from when it opened to when it resets, so the lanes
 * whose windows end together — the ones that compete for the same days —
 * line up on screen. Built from the rows the page already derives plus the
 * window telemetry `utilization` ships; the clock is an argument, so the same
 * inputs always draw the same bars. Instants are epoch milliseconds.
 */

export type QuotaTimelineView = "weekly" | "fiveHour";

const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
const WINDOW_MS: Record<QuotaTimelineView, number> = {
  weekly: 7 * DAY_MS,
  fiveHour: 5 * HOUR_MS,
};
/** Native's `WasteMath.resetSlack`: an engine recomputes `resetsAt` from a
    countdown on every poll, so two readings this close are the same window. */
const RESET_SLACK_MS = 120_000;

/** The span one screen of the timeline covers and where its columns start. */
export interface QuotaTimelineRange {
  readonly from: number;
  readonly to: number;
  /** Column starts, oldest first: local midnights (weekly) or hours. */
  readonly ticks: ReadonlyArray<number>;
  /** Whether `now` falls inside, so the page can say "current". */
  readonly current: boolean;
}

type Weekday = 0 | 1 | 2 | 3 | 4 | 5 | 6;

/**
 * Weekly: two weeks from the start of the local week holding `now`; each
 * `offset` step moves one week. Five-hour: a day around `now`, twelve hours
 * back from the current hour, each step twelve hours. Days are stepped on the
 * calendar, not in 24 h blocks, so a DST night still starts at midnight.
 * `timeZone` is the machine's own unless a test names one.
 */
export function quotaTimelineRange(
  view: QuotaTimelineView,
  nowMs: number,
  offset: number,
  options: { readonly weekStartsOn?: Weekday | undefined; readonly timeZone?: string } = {},
): QuotaTimelineRange {
  const now = DateTime.makeZonedUnsafe(nowMs, {
    timeZone: options.timeZone ?? DateTime.zoneMakeLocal(),
  });
  const ticks: number[] = [];
  if (view === "weekly") {
    const start = DateTime.add(
      DateTime.startOf(now, "week", { weekStartsOn: options.weekStartsOn ?? 0 }),
      { weeks: offset },
    );
    for (let day = 0; day <= 14; day += 1) {
      ticks.push(DateTime.toEpochMillis(DateTime.add(start, { days: day })));
    }
  } else {
    const from =
      DateTime.toEpochMillis(DateTime.startOf(now, "hour")) + (offset - 1) * 12 * HOUR_MS;
    for (let step = 0; step <= 24; step += 1) ticks.push(from + step * HOUR_MS);
  }
  const from = ticks[0] ?? nowMs;
  const to = ticks[ticks.length - 1] ?? nowMs;
  return { from, to, ticks: ticks.slice(0, -1), current: nowMs >= from && nowMs < to };
}

/** One bar. `elapsed` is a window that already rolled (its percentage is
    the last the Mac saw in a week, the peak in five hours), `current` the one
    ticking now, `upcoming` the earliest the next ones can run (no percentage). */
export interface QuotaSegment {
  readonly key: string;
  readonly kind: "elapsed" | "current" | "upcoming";
  readonly start: number;
  readonly end: number;
  readonly pct: number | null;
}

export interface QuotaLane {
  /** `fleet|number`, unique across the machine. */
  readonly key: string;
  /** The fleet's provider (`claude`, `codex`…), what tells two lanes apart
      when a machine runs more than one. */
  readonly provider: string;
  readonly fleetTitle: string;
  readonly number: number;
  readonly label: string;
  readonly active: boolean;
  readonly held: boolean;
  readonly autoIgnite: boolean;
  /** Every window the row reads, for the lane's legend column. */
  readonly windows: ReadonlyArray<UsageWindowBar>;
  /** Oldest first, never overlapping, each touching the range. */
  readonly segments: ReadonlyArray<QuotaSegment>;
  /** When the next banked reset lapses, when that is inside the range. */
  readonly resetExpiresAt: number | null;
}

function instant(iso: string | null): number | null {
  if (iso === null) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : ms;
}

/**
 * One lane's bars for a view.
 *
 * A window opens on the first request after the one before it expired, so
 * the bar ahead of a reset is only the earliest the next window can run. That
 * holds for a week, where an account in rotation is back within the day; a
 * 5h window sits cold for hours between uses, so upcoming 5h bars are drawn
 * only for an account kept warm, whose window the engine restarts as soon as
 * it goes cold. Rolled windows come from the Mac's history, never from
 * stepping back from the current one: a spent banked reset or an idle gap
 * makes the past irregular.
 */
function laneSegments(input: {
  readonly view: QuotaTimelineView;
  readonly window: UsageWindowBar | null;
  readonly autoIgnite: boolean;
  readonly history: ReadonlyArray<{ readonly end: number; readonly pct: number }>;
  readonly range: { readonly from: number; readonly to: number };
  readonly nowMs: number;
}): ReadonlyArray<QuotaSegment> {
  const length = WINDOW_MS[input.view];
  const resetsAt = instant(input.window?.resetsAt ?? null);
  const live = resetsAt !== null && resetsAt > input.nowMs ? resetsAt : null;
  // A window a banked reset ended keeps the reset it would have had, which
  // can still lie ahead; clipping below ends it where the running one opened.
  const segments: QuotaSegment[] = input.history
    .filter((past) => live === null || Math.abs(past.end - live) > RESET_SLACK_MS)
    .map((past) => ({
      key: `elapsed-${past.end}`,
      kind: "elapsed",
      start: past.end - length,
      // Rolled means over, whatever reset it named.
      end: Math.min(past.end, input.nowMs),
      pct: past.pct,
    }));
  if (live !== null && input.window !== null) {
    segments.push({
      key: `current-${live}`,
      kind: "current",
      start: live - length,
      end: live,
      pct: input.window.pct,
    });
    if (input.view === "weekly" || input.autoIgnite) {
      for (let start = live; start < input.range.to; start += length) {
        segments.push({
          key: `upcoming-${start}`,
          kind: "upcoming",
          start,
          end: start + length,
          pct: null,
        });
      }
    }
  }
  segments.sort((left, right) => left.start - right.start);
  // A window cut short (a spent banked reset) still reports the reset it
  // would have had; it ends where the next one opened.
  const clipped = segments.map((segment, index) => {
    const next = segments[index + 1];
    return next !== undefined && next.start < segment.end
      ? { ...segment, end: next.start }
      : segment;
  });
  return clipped.filter(
    (segment) =>
      segment.end > segment.start &&
      segment.end > input.range.from &&
      segment.start < input.range.to,
  );
}

/** Every account of the machine's fleets as a lane, fleets in the snapshot's
    order and accounts in each section's. The weekly view follows the 7d
    window, the five-hour view the 5h one; the per-model windows ride in the
    legend column. */
export function quotaTimelineLanes(input: {
  readonly sections: ReadonlyArray<FleetSectionModel>;
  readonly generations: ReadonlyArray<InfinitusUtilizationGeneration>;
  readonly fiveHourWindows: ReadonlyArray<InfinitusUtilizationFiveHourWindow>;
  readonly view: QuotaTimelineView;
  readonly range: { readonly from: number; readonly to: number };
  readonly nowMs: number;
}): ReadonlyArray<QuotaLane> {
  const windowName = input.view === "weekly" ? "7d" : "5h";
  return input.sections.flatMap((section) =>
    section.rows.map((row) => {
      const history =
        input.view === "weekly"
          ? input.generations
              .filter((past) => past.email === row.email && past.window === "7d")
              .map((past) => ({ end: past.resetAt * 1000, pct: past.finalPct }))
          : input.fiveHourWindows
              .filter((past) => past.email === row.email)
              .map((past) => ({ end: past.resetsAt * 1000, pct: past.peakPct }));
      const expiry = instant(row.resets?.endsAt ?? null);
      return {
        key: `${section.key}|${row.number}`,
        provider: section.provider,
        fleetTitle: section.title,
        number: row.number,
        label: row.label,
        active: row.active,
        held: row.held,
        autoIgnite: row.autoIgnite,
        windows: [...row.windows, ...row.scoped],
        segments: laneSegments({
          view: input.view,
          window: row.windows.find((window) => window.name === windowName) ?? null,
          autoIgnite: row.autoIgnite,
          history: history.map((past) => ({
            end: past.end,
            pct: Math.min(100, Math.max(0, Math.round(past.pct))),
          })),
          range: input.range,
          nowMs: input.nowMs,
        }),
        resetExpiresAt:
          expiry !== null && expiry >= input.range.from && expiry < input.range.to ? expiry : null,
      };
    }),
  );
}
