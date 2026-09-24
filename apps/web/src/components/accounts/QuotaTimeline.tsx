import type { FleetSectionModel } from "@infinitus/client-runtime/state/infinitusAccounts";
import {
  quotaTimelineLanes,
  quotaTimelineRange,
  type QuotaLane,
  type QuotaSegment,
  type QuotaTimelineRange,
  type QuotaTimelineView,
} from "@infinitus/client-runtime/state/infinitusQuotaTimeline";
import {
  decodeUtilization,
  utilizationFiveHourWindows,
  utilizationGenerations,
} from "@infinitus/client-runtime/state/infinitusUtilization";
import type { EnvironmentId } from "@infinitus/contracts";
import type { TimestampFormat } from "@infinitus/contracts/settings";
import * as Schema from "effect/Schema";
import { ChevronLeftIcon, ChevronRightIcon, FlameIcon } from "lucide-react";
import { useMemo, useState } from "react";

import { useLocalStorage } from "../../hooks/useLocalStorage";
import { usePrimarySettings } from "../../hooks/useSettings";
import { cn } from "../../lib/utils";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { formatShortTimestamp, weekStartsOn } from "../../timestampFormat";
import { Button } from "../ui/button";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import { fleetProvider } from "./providerMark";

const VIEW_KEY = "infinitus.quotaTimelineView";
const VIEWS = ["weekly", "fiveHour"] as const;
const VIEW_SCHEMA = Schema.Literals(VIEWS);
const VIEW_LABELS: Record<QuotaTimelineView, string> = { weekly: "Weekly", fiveHour: "5-hour" };

const dayFormatter = new Intl.DateTimeFormat(undefined, { month: "2-digit", day: "2-digit" });
const weekdayFormatter = new Intl.DateTimeFormat(undefined, { weekday: "short" });

/** "09/28 22:00" in the weekly view, "22:00" in the five-hour one. */
function instantLabel(ms: number, view: QuotaTimelineView, format: TimestampFormat): string {
  const time = formatShortTimestamp(new Date(ms).toISOString(), format);
  return view === "weekly" ? `${dayFormatter.format(ms)} ${time}` : time;
}

/** Where an instant sits across the range, as a CSS percentage, clamped. */
function position(ms: number, range: QuotaTimelineRange): number {
  return Math.min(100, Math.max(0, ((ms - range.from) / (range.to - range.from)) * 100));
}

/**
 * Every account's usage windows on one calendar (the CLIProxyAPI "Quota
 * windows" view): a lane per account, a bar per window from when it opened to
 * when it resets, filled to the share spent. The now line crosses each running
 * bar at the share of its time gone, so a fill past the line is ahead of pace.
 * Rolled windows come from the Mac's `utilization` telemetry (the last
 * reading of each week, the peak of each 5h window); without that verb the
 * lanes show the running window and the ones ahead only.
 */
export function QuotaTimeline({
  environmentId,
  sections,
  hasHistory,
  nowMs,
}: {
  readonly environmentId: EnvironmentId;
  readonly sections: ReadonlyArray<FleetSectionModel>;
  /** The machine's app lists the `utilization` verb. */
  readonly hasHistory: boolean;
  readonly nowMs: number;
}) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const [view, setView] = useLocalStorage<QuotaTimelineView, string>(
    VIEW_KEY,
    "weekly",
    VIEW_SCHEMA,
  );
  const [offset, setOffset] = useState(0);
  // One day of samples is the smallest reply; the rolled windows ride along
  // whole, since the Mac reconstructs them off its full history.
  const utilizationQuery = useEnvironmentQuery(
    hasHistory
      ? infinitusEnvironment.utilization({
          environmentId,
          input: { command: "utilization", args: [], options: { days: "1" } },
        })
      : null,
  );
  const utilization = useMemo(
    () => (utilizationQuery.data === null ? null : decodeUtilization(utilizationQuery.data.result)),
    [utilizationQuery.data],
  );
  const history = useMemo(
    () => ({
      generations: utilization === null ? [] : utilizationGenerations(utilization),
      fiveHourWindows: utilization === null ? [] : utilizationFiveHourWindows(utilization),
    }),
    [utilization],
  );
  // A handful of lanes: cheaper to rebuild than to key a memo on.
  const range = quotaTimelineRange(view, nowMs, offset, { weekStartsOn });
  const lanes = quotaTimelineLanes({ sections, ...history, view, range, nowMs });
  if (lanes.length === 0) return null;

  const span =
    view === "weekly"
      ? `${dayFormatter.format(range.from)} – ${dayFormatter.format(range.to - 1)} · two weeks`
      : `${instantLabel(range.from, "weekly", timestampFormat)} – ${instantLabel(range.to, "weekly", timestampFormat)} · 24 hours`;
  const today = new Date(nowMs).toDateString();

  return (
    <section className="flex flex-col gap-3 rounded-lg border p-3" aria-label="Quota windows">
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex min-w-0 flex-col">
          <h3 className="font-medium text-foreground text-sm">Quota windows</h3>
          <p className="text-muted-foreground text-xs tabular-nums">
            {span}
            {range.current ? " · current" : ""}
          </p>
        </div>
        <div className="ms-auto flex items-center gap-1">
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label="Earlier"
            onClick={() => setOffset((value) => value - 1)}
          >
            <ChevronLeftIcon />
          </Button>
          <Button size="xs" variant="ghost" disabled={offset === 0} onClick={() => setOffset(0)}>
            Today
          </Button>
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label="Later"
            onClick={() => setOffset((value) => value + 1)}
          >
            <ChevronRightIcon />
          </Button>
        </div>
        <div className="flex items-center gap-1" role="radiogroup" aria-label="Window">
          {VIEWS.map((option) => (
            <Button
              key={option}
              size="xs"
              variant={option === view ? "secondary" : "ghost"}
              role="radio"
              aria-checked={option === view}
              onClick={() => {
                setView(option);
                setOffset(0);
              }}
            >
              {VIEW_LABELS[option]}
            </Button>
          ))}
        </div>
      </div>

      <div className="overflow-x-auto">
        <div className="grid min-w-[40rem] grid-cols-[minmax(9rem,13rem)_1fr]">
          <div className="border-b pb-1 text-muted-foreground text-xs">Account</div>
          <div className="relative flex border-b pb-1">
            {range.ticks.map((tick, index) => (
              <div
                key={tick}
                className={cn(
                  "flex min-w-0 flex-1 flex-col items-center text-[10px] text-muted-foreground tabular-nums leading-tight",
                  view === "weekly" && new Date(tick).toDateString() === today
                    ? "text-foreground"
                    : null,
                )}
              >
                {view === "weekly" ? (
                  <>
                    <span>{weekdayFormatter.format(tick)}</span>
                    <span>{dayFormatter.format(tick)}</span>
                  </>
                ) : index % 3 === 0 ? (
                  <span>{formatShortTimestamp(new Date(tick).toISOString(), timestampFormat)}</span>
                ) : null}
              </div>
            ))}
          </div>
          {lanes.map((lane) => (
            <Lane
              key={lane.key}
              lane={lane}
              view={view}
              range={range}
              nowMs={nowMs}
              timestampFormat={timestampFormat}
            />
          ))}
        </div>
      </div>

      <p className="flex flex-wrap items-center gap-x-4 gap-y-1 text-muted-foreground text-xs">
        <span className="flex items-center gap-1.5">
          <span className="h-2 w-5 rounded-full border border-foreground/30 bg-foreground/15" />
          running
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-2 w-5 rounded-full border border-muted-foreground/50 border-dashed" />
          earliest next
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-2 w-5 rounded-full bg-muted" />
          rolled
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-3 w-0.5 bg-warning" />
          banked reset lapses
        </span>
        <span>
          {view === "weekly"
            ? "Lanes ending together compete for the same days."
            : "A 5h window starts on first use, so only kept-warm accounts show the ones ahead."}
        </span>
      </p>
    </section>
  );
}

function Lane({
  lane,
  view,
  range,
  nowMs,
  timestampFormat,
}: {
  readonly lane: QuotaLane;
  readonly view: QuotaTimelineView;
  readonly range: QuotaTimelineRange;
  readonly nowMs: number;
  readonly timestampFormat: TimestampFormat;
}) {
  const Mark = fleetProvider(lane.provider).mark;
  return (
    <>
      <div
        className={cn(
          "flex min-w-0 flex-col justify-center gap-1 border-b py-2 pe-3",
          lane.held ? "opacity-60" : null,
        )}
      >
        <span className="flex min-w-0 items-center gap-1.5 text-xs">
          {Mark === null ? null : <Mark className="size-3.5 shrink-0" aria-hidden />}
          <span className={cn("truncate font-medium", lane.active ? "text-foreground" : null)}>
            {lane.label}
          </span>
          {lane.active ? (
            <span className="size-1.5 shrink-0 rounded-full bg-success" aria-label="Active" />
          ) : null}
          {lane.autoIgnite ? (
            <FlameIcon
              className="size-3 shrink-0 fill-current text-orange-500"
              aria-label="Kept warm"
            />
          ) : null}
        </span>
        {lane.windows.length === 0 ? null : (
          <span className="flex flex-wrap gap-x-2 text-[10px] text-muted-foreground tabular-nums">
            {lane.windows.map((window) => (
              <span key={window.name}>
                {window.name} <span className="text-foreground">{window.pct}%</span>
              </span>
            ))}
          </span>
        )}
      </div>
      <div className="relative border-b">
        {/* Day or hour columns, recessive. */}
        <div className="absolute inset-0 flex" aria-hidden>
          {range.ticks.map((tick) => (
            <div key={tick} className="flex-1 border-s border-border/40 first:border-s-0" />
          ))}
        </div>
        {lane.segments.map((segment) => (
          <Segment
            key={segment.key}
            segment={segment}
            lane={lane}
            view={view}
            range={range}
            timestampFormat={timestampFormat}
          />
        ))}
        {lane.resetExpiresAt === null ? null : (
          <Tooltip>
            <TooltipTrigger
              render={
                <span
                  role="img"
                  aria-label={`${lane.label}: banked reset lapses ${instantLabel(lane.resetExpiresAt, "weekly", timestampFormat)}`}
                  className="absolute inset-y-1 w-0.5 bg-warning"
                  style={{ left: `${position(lane.resetExpiresAt, range)}%` }}
                />
              }
            />
            <TooltipPopup side="top">
              Banked reset lapses {instantLabel(lane.resetExpiresAt, "weekly", timestampFormat)}
            </TooltipPopup>
          </Tooltip>
        )}
        {range.current ? (
          <span
            className="pointer-events-none absolute inset-y-0 w-px bg-foreground/50"
            style={{ left: `${position(nowMs, range)}%` }}
            aria-hidden
          />
        ) : null}
      </div>
    </>
  );
}

function Segment({
  segment,
  lane,
  view,
  range,
  timestampFormat,
}: {
  readonly segment: QuotaSegment;
  readonly lane: QuotaLane;
  readonly view: QuotaTimelineView;
  readonly range: QuotaTimelineRange;
  readonly timestampFormat: TimestampFormat;
}) {
  const left = position(segment.start, range);
  const width = position(segment.end, range) - left;
  const resets = instantLabel(segment.end, view, timestampFormat);
  const label = segment.pct === null ? resets : `${segment.pct}% · ${resets}`;
  const what =
    segment.kind === "current"
      ? `${segment.pct}% used, resets ${resets}`
      : segment.kind === "elapsed"
        ? `${view === "weekly" ? "ended at" : "peaked at"} ${segment.pct}%, reset ${resets}`
        : `earliest next window, until ${resets}`;
  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <span
            role="img"
            aria-label={`${lane.label}: ${what}`}
            className={cn(
              "absolute inset-y-2 flex cursor-default items-center overflow-hidden rounded-full px-2 text-[10px] tabular-nums whitespace-nowrap",
              segment.kind === "current"
                ? "border border-foreground/30 bg-foreground/10 text-foreground"
                : segment.kind === "elapsed"
                  ? "bg-muted text-muted-foreground"
                  : "border border-muted-foreground/40 border-dashed text-muted-foreground",
            )}
            style={{ left: `${left}%`, width: `${width}%` }}
          >
            {segment.kind === "current" && segment.pct !== null && segment.pct > 0 ? (
              <span
                className="absolute inset-y-0 left-0 bg-foreground/20"
                style={{ width: `${segment.pct}%` }}
                aria-hidden
              />
            ) : null}
            <span className="relative truncate">{label}</span>
          </span>
        }
      />
      <TooltipPopup side="top">
        {lane.label} · {what}
      </TooltipPopup>
    </Tooltip>
  );
}
