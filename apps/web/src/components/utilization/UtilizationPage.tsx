import { useAtomValue } from "@effect/atom-react";
import {
  buildForecast,
  infinitusCapabilityOf,
  infinitusPageState,
  type ForecastLineModel,
  type ForecastModel,
  type ForecastWindowModel,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import {
  compactTokens,
  decodeUtilization,
  fiveHourSummary,
  formatCount,
  historyLines,
  historyRange,
  liveRateText,
  replayText,
  RUN_RATE_NOTE,
  runRateRows,
  utilizationWindows,
  wasteRows,
  WASTE_GAP_SECONDS,
  type FiveHourWindowRow,
  type HistoryLine,
  type WasteRow,
} from "@t3tools/client-runtime/state/infinitusUtilization";
import type { InfinitusLiveTokenRate, InfinitusUtilization } from "@t3tools/contracts/infinitus";
import type { TimestampFormat } from "@t3tools/contracts/settings";
import * as Schema from "effect/Schema";
import { useMemo, useState, type ReactNode } from "react";

import { RefreshIcon } from "~/components/ui/refresh-icon";

import { isElectron } from "../../env";
import { useLocalStorage } from "../../hooks/useLocalStorage";
import { usePrimarySettings } from "../../hooks/useSettings";
import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { primaryServerConfigAtom } from "../../state/server";
import { formatDayAwareTimestamp, formatUpcomingTimestamp } from "../../timestampFormat";
import { AccountsUnavailable } from "../accounts/AccountsUnavailable";
import { ForecastStrip } from "../accounts/ForecastStrip";
import { Button } from "../ui/button";
import { ScrollArea } from "../ui/scroll-area";
import { SidebarInset } from "../ui/sidebar";
import { Skeleton } from "../ui/skeleton";
import { WorkspaceBreadcrumb, WorkspaceBreadcrumbItem } from "../WorkspaceBreadcrumb";
import { WorkspacePageContainer } from "../WorkspacePageContainer";
import { WorkspacePageHeader } from "../WorkspacePageHeader";

/** Native's `UsageForecast.basisText`, for a build whose reply carries none. */
const DEFAULT_BASIS =
  "5h pace measured over the last hour, weekly and per-model paces over the last day.";

const DAYS_KEY = "infinitus.utilizationDays";
const DAYS_CHOICES = ["1", "7", "30"] as const;
const DAYS_LABELS: Record<(typeof DAYS_CHOICES)[number], string> = {
  "1": "24 hours",
  "7": "7 days",
  "30": "30 days",
};
const NEEDS_NEWER_APP =
  "History and the run rate need a newer Infinitus app (the utilization verb).";

/**
 * `/utilization` (#747): the native Utilization pane in the fork. The
 * forecast section reads off the `forecast` reply the snapshot already
 * carries (every account's projection at its own measured pace); History
 * (every account's percentage of one window over 1 / 7 / 30 days) and Run
 * rate (tokens, API-equivalent $ and messages over the last hour / day /
 * week, plus the live output rate) read `utilization --days n` through the
 * utilization query atom, held and re-read every 5 min only while this page
 * is mounted. Primary environment only, like Stats.
 */
export function UtilizationPage() {
  const environmentId = usePrimaryEnvironmentId();
  const capability = infinitusCapabilityOf(
    useAtomValue(primaryServerConfigAtom)?.environment.capabilities,
  );
  const ready = capability === true && environmentId !== null;
  const snapshotQuery = useEnvironmentQuery(
    ready ? infinitusEnvironment.snapshot({ environmentId, input: {} }) : null,
  );
  const snapshot = snapshotQuery.data;
  const hasVerb =
    snapshot?.available === true &&
    snapshot.commands.some((command) => command.name === "forecast");
  const hasHistoryVerb =
    snapshot?.available === true &&
    snapshot.commands.some((command) => command.name === "utilization");
  const forecast = useMemo(() => (snapshot === null ? null : buildForecast(snapshot)), [snapshot]);
  const [days, setDays] = useLocalStorage<(typeof DAYS_CHOICES)[number], string>(
    DAYS_KEY,
    "7",
    Schema.Literals(DAYS_CHOICES),
  );
  const utilizationQuery = useEnvironmentQuery(
    ready && hasHistoryVerb
      ? infinitusEnvironment.utilization({
          environmentId,
          input: { command: "utilization", args: [], options: { days } },
        })
      : null,
  );
  const utilization = useMemo(
    () => (utilizationQuery.data === null ? null : decodeUtilization(utilizationQuery.data.result)),
    [utilizationQuery.data],
  );
  // This server's own live rate (#1127), folded from the turns it recorded.
  // No Mac verb behind it, so it survives the session sweep that empties the
  // Mac's own `liveRate`; a failed read simply leaves the line out.
  const liveTokenRateQuery = useEnvironmentQuery(
    ready ? infinitusEnvironment.liveTokenRate({ environmentId, input: {} }) : null,
  );
  // The alias a fleet shows for an account, keyed by the email the history carries.
  const labels = useMemo(() => {
    const out: Record<string, string> = {};
    for (const fleet of snapshot?.fleets ?? []) {
      for (const account of fleet.accounts) {
        if (account.alias !== undefined && account.alias !== "") out[account.email] = account.alias;
      }
    }
    return out;
  }, [snapshot?.fleets]);

  const topbarContent = (
    <div className="flex w-full min-w-0 items-center gap-x-3 py-2">
      <WorkspaceBreadcrumb ariaLabel="Utilization breadcrumb" className="min-w-0">
        <WorkspaceBreadcrumbItem current>
          <h1>Utilization</h1>
        </WorkspaceBreadcrumbItem>
      </WorkspaceBreadcrumb>
      <div className="ms-auto flex items-center gap-1" role="radiogroup" aria-label="Range">
        {DAYS_CHOICES.map((option) => (
          <Button
            key={option}
            size="sm"
            variant={option === days ? "secondary" : "ghost"}
            role="radio"
            aria-checked={option === days}
            disabled={!hasHistoryVerb}
            onClick={() => setDays(option)}
          >
            {DAYS_LABELS[option]}
          </Button>
        ))}
      </div>
      <Button
        onClick={() => {
          snapshotQuery.refresh();
          if (hasHistoryVerb) utilizationQuery.refresh();
        }}
        aria-label="Refresh utilization"
        aria-busy={snapshotQuery.isPending || utilizationQuery.isPending}
        disabled={!hasVerb}
        size="icon-sm"
        variant="ghost"
      >
        <RefreshIcon
          className="size-3.5"
          refreshing={snapshotQuery.isPending || utilizationQuery.isPending}
        />
      </Button>
    </div>
  );

  let body: ReactNode;
  const gate = infinitusPageState({ capability, snapshot });
  if (gate === "unsupported") {
    body = (
      <section className="max-w-xl rounded-lg border p-4">
        <p className="text-muted-foreground text-sm">
          This server has no Infinitus adapter for this platform.
        </p>
      </section>
    );
  } else if (gate === "loading" || snapshot === null) {
    body = <UtilizationSkeleton />;
  } else if (gate === "unavailable") {
    body = (
      <AccountsUnavailable
        reason={snapshot.unavailableReason ?? null}
        socketPath={snapshot.status?.socket ?? null}
        onRetry={snapshotQuery.refresh}
      />
    );
  } else if (!hasVerb) {
    body = (
      <p className="text-muted-foreground text-sm">This Infinitus build has no forecast verb.</p>
    );
  } else {
    body = (
      <div className="flex flex-col gap-8">
        <ForecastSection forecast={forecast} />
        {!hasHistoryVerb ? (
          <p className="text-muted-foreground text-sm">{NEEDS_NEWER_APP}</p>
        ) : utilizationQuery.error !== null ? (
          <p className="text-destructive text-sm">{utilizationQuery.error}</p>
        ) : utilization === null ? (
          utilizationQuery.data === null ? (
            <UtilizationSkeleton />
          ) : (
            <p className="text-muted-foreground text-sm">
              The utilization reply could not be read.
            </p>
          )
        ) : (
          <>
            <HistorySection utilization={utilization} labels={labels} />
            <FiveHourSection utilization={utilization} labels={labels} />
            <WasteSection utilization={utilization} labels={labels} />
            <RunRateSection utilization={utilization} liveTokenRate={liveTokenRateQuery.data} />
          </>
        )}
      </div>
    );
  }

  return (
    <SidebarInset className="h-dvh min-h-0 overflow-hidden overscroll-y-none bg-background text-foreground isolate">
      <div className="flex min-h-0 min-w-0 flex-1 flex-col bg-background text-foreground">
        <WorkspacePageHeader electron={isElectron} className="h-auto">
          {topbarContent}
        </WorkspacePageHeader>
        <ScrollArea className="min-h-0 flex-1">
          <WorkspacePageContainer width="wide">{body}</WorkspacePageContainer>
        </ScrollArea>
      </div>
    </SidebarInset>
  );
}

function ForecastSection({ forecast }: { readonly forecast: ForecastModel | null }) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  return (
    <div className="flex flex-col gap-6">
      <section className="flex flex-col gap-3">
        <h2 className="font-medium text-foreground text-sm">Forecast</h2>
        {forecast === null || forecast.accounts.length === 0 ? (
          <p className="text-muted-foreground text-sm">
            No projection yet — needs an active account and ten minutes of polls.
          </p>
        ) : (
          forecast.accounts.map((line) => (
            <ForecastLine key={line.number} line={line} timestampFormat={timestampFormat} />
          ))
        )}
        <p className="text-muted-foreground text-xs">
          Estimate. {forecast?.basis ?? DEFAULT_BASIS}
        </p>
      </section>
      {forecast !== null && forecast.hasActive ? <ForecastStrip forecast={forecast} /> : null}
    </div>
  );
}

function ForecastLine({
  line,
  timestampFormat,
}: {
  readonly line: ForecastLineModel;
  readonly timestampFormat: TimestampFormat;
}) {
  return (
    <div className="flex flex-col gap-1 rounded-lg border p-3">
      <div className="flex items-center gap-2 text-sm">
        <span className="font-medium text-foreground">{line.label}</span>
        {line.active ? (
          <span className="text-xs text-orange-500">Active</span>
        ) : line.disabled ? (
          <span className="text-muted-foreground text-xs">On Hold</span>
        ) : null}
        <span className="ms-auto text-xs">
          {line.bindsAt !== null && line.bindsWindow !== null ? (
            <span className="text-orange-500">
              {line.bindsWindow} binds first,{" "}
              {formatUpcomingTimestamp(line.bindsAt, timestampFormat)}
            </span>
          ) : (
            <span className="text-muted-foreground">No limit in sight</span>
          )}
        </span>
      </div>
      {line.windows.map((window) => (
        <ForecastWindowRow key={window.name} window={window} timestampFormat={timestampFormat} />
      ))}
    </div>
  );
}

/** Native's `ForecastWords.rate`: whole percents at 10 %/h and up, one decimal below. */
function rateLabel(pctPerHour: number): string {
  return `${pctPerHour >= 10 ? pctPerHour.toFixed(0) : pctPerHour.toFixed(1)}%/h`;
}

function ForecastWindowRow({
  window,
  timestampFormat,
}: {
  readonly window: ForecastWindowModel;
  readonly timestampFormat: TimestampFormat;
}) {
  const outcome =
    window.hitsAt !== null
      ? { text: `Out ${formatUpcomingTimestamp(window.hitsAt, timestampFormat)}`, warn: true }
      : window.ratePctPerHour !== null
        ? { text: "Resets before it fills", warn: false }
        : null;
  return (
    <div className="flex items-center gap-3 text-xs tabular-nums">
      <span className="w-16 shrink-0 truncate">{window.name}</span>
      <span className="w-10 shrink-0 text-right">{window.pct}%</span>
      <span
        className={
          window.ratePctPerHour === null
            ? "w-24 shrink-0 text-right text-muted-foreground"
            : "w-24 shrink-0 text-right"
        }
      >
        {window.ratePctPerHour === null ? "Pace unknown" : rateLabel(window.ratePctPerHour)}
      </span>
      {outcome ? (
        <span className={outcome.warn ? "text-orange-500" : "text-muted-foreground"}>
          {outcome.text}
        </span>
      ) : null}
      {window.resetsAt !== null ? (
        <span className="ms-auto text-muted-foreground">
          Resets {formatUpcomingTimestamp(window.resetsAt, timestampFormat)}
        </span>
      ) : null}
    </div>
  );
}

/** One stroke per account; the fleet rarely has more, and a sixth wraps around. */
const LINE_COLORS = [
  "text-primary",
  "text-orange-500",
  "text-emerald-500",
  "text-sky-500",
  "text-violet-500",
];

function HistorySection({
  utilization,
  labels,
}: {
  readonly utilization: InfinitusUtilization;
  readonly labels: Readonly<Record<string, string>>;
}) {
  const windows = utilizationWindows(utilization);
  const [chosen, setChosen] = useState("5h");
  const window = windows.includes(chosen) ? chosen : (windows[0] ?? "5h");
  const lines = useMemo(
    () => historyLines(utilization, window, labels),
    [labels, utilization, window],
  );
  const range = useMemo(
    () => historyRange(utilization, Math.floor(Date.now() / 1000)),
    [utilization],
  );
  return (
    <section className="flex flex-col gap-3" data-testid="utilization-history">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="font-medium text-foreground text-sm">History</h2>
        {windows.length > 1 ? (
          <div className="ms-auto flex items-center gap-1" role="radiogroup" aria-label="Window">
            {windows.map((name) => (
              <Button
                key={name}
                size="xs"
                variant={name === window ? "secondary" : "ghost"}
                role="radio"
                aria-checked={name === window}
                onClick={() => setChosen(name)}
              >
                {name}
              </Button>
            ))}
          </div>
        ) : null}
      </div>
      {lines.length === 0 ? (
        <p className="text-muted-foreground text-sm">
          No history yet. Samples build up while Infinitus runs — come back after a few polls.
        </p>
      ) : (
        <>
          <HistoryChart lines={lines} range={range} days={utilization.days} />
          <ul className="flex flex-wrap gap-x-4 gap-y-1 text-xs">
            {lines.map((line, index) => (
              <li key={line.email} className="flex items-center gap-1.5 tabular-nums">
                <span
                  aria-hidden
                  className={`inline-block size-2 rounded-full bg-current ${LINE_COLORS[index % LINE_COLORS.length]}`}
                />
                <span className="text-foreground">{line.label}</span>
                <span className="text-muted-foreground">{Math.round(line.latestPct)}%</span>
                {line.active ? <span className="text-orange-500">Active</span> : null}
              </li>
            ))}
          </ul>
        </>
      )}
      <p className="text-muted-foreground text-xs">
        The {window} window of every account, as the Mac recorded it at each engine poll.
      </p>
    </section>
  );
}

/** A day's range is labelled by the hour, a longer one by the date. The day
    range ends on the same clock time it started, so its labels carry the
    weekday too — without it both ends of the axis read the same. */
function axisLabel(seconds: number, days: number): string {
  const date = new Date(seconds * 1000);
  return days <= 1
    ? date.toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit" })
    : date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function HistoryChart({
  lines,
  range,
  days,
}: {
  readonly lines: ReadonlyArray<HistoryLine>;
  readonly range: { readonly from: number; readonly to: number };
  readonly days: number;
}) {
  const width = 600;
  const height = 160;
  const span = Math.max(1, range.to - range.from);
  const x = (t: number) => ((t - range.from) / span) * width;
  const y = (pct: number) => height - (pct / 100) * height;
  return (
    <div className="flex flex-col gap-1">
      <svg
        viewBox={`0 0 ${width} ${height}`}
        className="h-40 w-full rounded-md border"
        preserveAspectRatio="none"
        role="img"
        aria-label="Usage history"
      >
        {[0, 25, 50, 75, 100].map((pct) => (
          <line
            key={pct}
            x1={0}
            x2={width}
            y1={y(pct)}
            y2={y(pct)}
            className="text-border"
            stroke="currentColor"
            strokeWidth={pct === 100 || pct === 0 ? 0 : 1}
            strokeDasharray={pct === 50 ? undefined : "2 4"}
          />
        ))}
        {lines.map((line, index) => (
          <polyline
            key={line.email}
            className={LINE_COLORS[index % LINE_COLORS.length]}
            points={line.points
              .map((point) => `${x(point.t).toFixed(1)},${y(point.pct).toFixed(1)}`)
              .join(" ")}
            fill="none"
            stroke="currentColor"
            strokeWidth={1.5}
            vectorEffect="non-scaling-stroke"
          />
        ))}
      </svg>
      <div className="flex justify-between text-muted-foreground text-xs tabular-nums">
        <span>{axisLabel(range.from, days)}</span>
        <span>100% at the top</span>
        <span>{axisLabel(range.to, days)}</span>
      </div>
    </div>
  );
}

const isoFromSeconds = (seconds: number) => new Date(seconds * 1000).toISOString();

/** The Mac's reconstructed 5h windows: a window starts on the first request
    after the previous one expired, so what it was used for is its PEAK, not
    the percentage it ended on — headroom idles rather than leaking. */
function FiveHourSection({
  utilization,
  labels,
}: {
  readonly utilization: InfinitusUtilization;
  readonly labels: Readonly<Record<string, string>>;
}) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const range = useMemo(
    () => historyRange(utilization, Math.floor(Date.now() / 1000)),
    [utilization],
  );
  const summary = useMemo(
    () => fiveHourSummary(utilization, range, labels),
    [labels, range, utilization],
  );
  const replay = replayText(utilization);
  if (summary === null) {
    return null;
  }
  return (
    <section className="flex flex-col gap-3" data-testid="utilization-five-hour">
      <h2 className="font-medium text-foreground text-sm">Five-hour windows</h2>
      <p className="text-muted-foreground text-xs tabular-nums">
        {summary.count} {summary.count === 1 ? "window" : "windows"} · mean peak{" "}
        {Math.round(summary.meanPeakPct)}%
        {summary.unused > 0 ? ` · ${summary.unused} never used past 5%` : ""}
      </p>
      <ul className="flex flex-col gap-1.5">
        {summary.windows.map((window) => (
          <FiveHourRow key={window.key} window={window} timestampFormat={timestampFormat} />
        ))}
      </ul>
      {replay !== null ? <p className="text-muted-foreground text-xs">{replay}</p> : null}
      <p className="text-muted-foreground text-xs">
        A window starts on the first request after the last one expired, so the peak is what it was
        used for — the rest idled rather than leaking.
      </p>
    </section>
  );
}

function FiveHourRow({
  window,
  timestampFormat,
}: {
  readonly window: FiveHourWindowRow;
  readonly timestampFormat: TimestampFormat;
}) {
  return (
    <li className="flex items-center gap-3 text-xs tabular-nums">
      <span className="w-28 shrink-0 truncate text-foreground">{window.label}</span>
      <span className="w-32 shrink-0 text-muted-foreground">
        {formatDayAwareTimestamp(isoFromSeconds(window.start), timestampFormat)}
      </span>
      <span className="h-1.5 min-w-0 flex-1 rounded-full bg-muted">
        <span
          aria-hidden
          className="block h-full rounded-full bg-primary"
          style={{ width: `${Math.max(1, window.peakPct)}%` }}
        />
      </span>
      <span className="w-10 shrink-0 text-right text-foreground">
        {Math.round(window.peakPct)}%
      </span>
      <span className="w-24 shrink-0 text-right">
        {window.closed ? (
          <span className="text-muted-foreground">
            {window.samples} {window.samples === 1 ? "poll" : "polls"}
          </span>
        ) : (
          <span className="text-orange-500">Still ticking</span>
        )}
      </span>
    </li>
  );
}

/** The weekly rollovers: what expired unused at each 7d — or per-model —
    reset. A 5h window recycles ~34× a week, so its leftovers are idle time
    rather than lost quota and never count here. */
function WasteSection({
  utilization,
  labels,
}: {
  readonly utilization: InfinitusUtilization;
  readonly labels: Readonly<Record<string, string>>;
}) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const waste = useMemo(() => wasteRows(utilization, labels), [labels, utilization]);
  if (waste.length === 0) {
    return null;
  }
  return (
    <section className="flex flex-col gap-3" data-testid="utilization-waste">
      <h2 className="font-medium text-foreground text-sm">Weekly waste</h2>
      <ul className="flex flex-col gap-1.5">
        {waste.map((row) => (
          <WasteRowLine key={row.key} row={row} timestampFormat={timestampFormat} />
        ))}
      </ul>
      <p className="text-muted-foreground text-xs">
        The headroom that expired at each weekly reset, as the Mac last saw the window. Five-hour
        windows are left out: they recycle all week, so their leftovers are idle time, not lost
        quota.
      </p>
    </section>
  );
}

function WasteRowLine({
  row,
  timestampFormat,
}: {
  readonly row: WasteRow;
  readonly timestampFormat: TimestampFormat;
}) {
  // A long gap between the last poll and the reset means the final percentage
  // is a floor: the app was not watching for the window's tail.
  const stale = row.observationGap !== null && row.observationGap >= WASTE_GAP_SECONDS;
  return (
    <li className="flex items-center gap-3 text-xs tabular-nums">
      <span className="w-28 shrink-0 truncate text-foreground">{row.label}</span>
      <span className="w-12 shrink-0 text-muted-foreground">{row.window}</span>
      <span className="w-32 shrink-0 text-muted-foreground">
        {formatDayAwareTimestamp(isoFromSeconds(row.resetAt), timestampFormat)}
      </span>
      <span className="h-1.5 min-w-0 flex-1 rounded-full bg-muted">
        <span
          aria-hidden
          className="block h-full rounded-full bg-primary"
          style={{ width: `${Math.max(1, row.finalPct)}%` }}
        />
      </span>
      <span className="w-24 shrink-0 text-right text-foreground">
        {Math.round(row.wastePct)}% unused
      </span>
      {/* Reserved on every row, stale or not: the caveat is a flex sibling of
          the bar's track, so a slot only some rows carry would leave their
          bars shorter than the rest and the percentages incomparable. */}
      <span className="w-40 shrink-0 text-muted-foreground">
        {stale ? "Last seen hours before" : null}
      </span>
    </li>
  );
}

function RunRateSection({
  utilization,
  liveTokenRate,
}: {
  readonly utilization: InfinitusUtilization;
  readonly liveTokenRate: InfinitusLiveTokenRate | null;
}) {
  const rows = runRateRows(utilization);
  const live = liveRateText(utilization, liveTokenRate);
  const unpriced = utilization.rates?.unpricedModels ?? [];
  return (
    <section className="flex flex-col gap-3" data-testid="utilization-run-rate">
      <h2 className="font-medium text-foreground text-sm">Run rate</h2>
      {rows === null ? (
        <p className="text-muted-foreground text-sm">
          Scanning transcripts — the run rate shows once the Mac has read a week of them.
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full max-w-xl text-xs tabular-nums">
            <thead className="text-muted-foreground">
              <tr>
                <th className="py-1 text-left font-normal" />
                <th className="py-1 text-right font-normal">Tokens</th>
                <th className="py-1 text-right font-normal">API-equivalent $</th>
                <th className="py-1 text-right font-normal">Turns</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.label}>
                  <td className="py-1 text-left text-foreground">{row.label}</td>
                  <td className="py-1 text-right">{compactTokens(row.tokens)}</td>
                  <td className="py-1 text-right">{row.usd.toFixed(2)}</td>
                  <td className="py-1 text-right">{formatCount(row.messages)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {unpriced.length > 0 ? (
        <p className="text-muted-foreground text-xs">
          Tokens counted but not priced: {unpriced.join(", ")}
        </p>
      ) : null}
      {live !== null ? <p className="text-muted-foreground text-xs">{live}</p> : null}
      <p className="text-muted-foreground text-xs">{RUN_RATE_NOTE}</p>
    </section>
  );
}

function UtilizationSkeleton() {
  return (
    <div className="flex flex-col gap-3">
      <Skeleton className="h-4 w-24" />
      <Skeleton className="h-24 w-full" />
      <Skeleton className="h-24 w-full" />
    </div>
  );
}
