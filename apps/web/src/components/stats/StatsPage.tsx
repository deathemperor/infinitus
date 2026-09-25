import { useAtomValue } from "@effect/atom-react";
import { createStatsAtoms } from "@infinitus/client-runtime/state/stats";
import {
  ACTIVITY_FOOTNOTE,
  activityRows,
  effortRows,
  effortText,
  engineRows,
  modelRows,
  sessionLengthRows,
  sessionTimeLine,
  STATS_PERIODS,
  statsTileGroups,
  type EffortRow,
  type StatsPeriod,
  type StatsSummary,
} from "@infinitus/client-runtime/state/infinitusStats";
import { runAtomCommand } from "@infinitus/client-runtime/state/runtime";
import type { EnvironmentId, StatsRequest, UsageDay } from "@infinitus/contracts";
import { mergeStats, statsDayFormatter } from "@infinitus/shared/stats";
import * as Schema from "effect/Schema";
import { useMemo, useState } from "react";
import { ChevronDownIcon } from "lucide-react";
import { RefreshIcon } from "~/components/ui/refresh-icon";
import { isElectron } from "../../env";
import { useNowMinute } from "../../hooks/useNowMinute";
import { useLocalStorage } from "../../hooks/useLocalStorage";
import { appAtomRegistry } from "../../rpc/atomRegistry";
import { environmentPresentations } from "../../state/presentation";
import { serverEnvironment } from "../../state/server";
import { Button } from "../ui/button";
import { Menu, MenuTrigger, MenuPopup, MenuCheckboxItem, MenuSeparator } from "../ui/menu";
import { ScrollArea } from "../ui/scroll-area";
import { SidebarInset } from "../ui/sidebar";
import { Skeleton } from "../ui/skeleton";
import { WorkspaceBreadcrumb, WorkspaceBreadcrumbItem } from "../WorkspaceBreadcrumb";
import { WorkspacePageContainer } from "../WorkspacePageContainer";
import { WorkspacePageHeader } from "../WorkspacePageHeader";
import { StatsTileGroupView } from "./StatsTiles";

const PERIOD_SCHEMA = Schema.Literals(STATS_PERIODS);
const REPORTING_TIME_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone;
const reportDay = statsDayFormatter(REPORTING_TIME_ZONE);
const PERIOD_LABELS: Record<StatsPeriod, string> = {
  day: "Today",
  week: "Week",
  month: "Month",
  year: "Year",
};
const ESTIMATE_NOTE = "Estimates from selected environments, never billing truth.";
const statsAtoms = createStatsAtoms({
  server: serverEnvironment,
  presentations: environmentPresentations,
});
const NATIVE_TILES = [
  "Switches",
  "Accounts hit a limit",
  "Revivals",
  "Minutes lost, all out",
  "Ignites",
  "Resumes",
];

export function StatsPage() {
  const [period, setPeriod] = useLocalStorage<StatsPeriod, string>(
    "infinitus.statsPeriod",
    "week",
    PERIOD_SCHEMA,
  );
  const [selectedIds, setSelectedIds] = useState<EnvironmentId[] | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const minute = useNowMinute();
  const today = reportDay(Date.parse(minute + ":00Z")) as UsageDay;
  const request = useMemo<StatsRequest>(
    () => ({ period, today, timeZone: REPORTING_TIME_ZONE }),
    [period, today],
  );
  const key = JSON.stringify({ request, selectedIds });
  const environments = useAtomValue(statsAtoms(key));
  const selected = environments.filter((e) => e.selected);
  const snapshots = useMemo(
    () => environments.flatMap((e) => (e.selected && e.snapshot ? [e.snapshot] : [])),
    [environments],
  );
  const summary = useMemo(() => mergeStats(snapshots, request), [snapshots, request]);
  const notes = [
    ...new Set(
      snapshots.flatMap((s) => [
        ...s.unavailable,
        ...s.sources.flatMap((source) =>
          source.message && source.status !== "missing" ? [source.message] : [],
        ),
      ]),
    ),
  ];
  const unavailable = new Set(NATIVE_TILES);
  if (
    snapshots.length > 0 &&
    snapshots.every(
      (s) => s.repositories.length === 0 || s.repositories.every((r) => !r.pullRequestsAvailable),
    )
  ) {
    for (const id of ["PRs opened", "PRs merged", "Per PR", "Mean hours to merge"])
      unavailable.add(id);
  }
  if ((summary.total.unpricedRecords ?? 0) > 0 && (summary.total.pricedRecords ?? 0) === 0) {
    for (const id of ["Spend", "Cache savings", "Per commit", "Per PR"]) unavailable.add(id);
  }
  if ((summary.total.unpricedRecords ?? 0) > 0) {
    unavailable.add("Per commit");
    unavailable.add("Per PR");
  }
  if (
    snapshots.length > 0 &&
    snapshots.every(
      (s) =>
        s.repositories.length === 0 ||
        s.repositories.every((r) => !r.complete && r.commits.length === 0),
    )
  ) {
    for (const id of [
      "Commits",
      "Lines +",
      "Lines −",
      "Files touched",
      "Co-authored by Claude",
      "Reverts",
      "Repos",
      "Messages / commit",
      "Per commit",
      "Tokens / line",
    ])
      unavailable.add(id);
  }
  if (
    snapshots.length > 0 &&
    snapshots.every(
      (s) =>
        !s.sources.some(
          (source) => source.fingerprint.provider !== "grok" && source.status !== "missing",
        ),
    )
  ) {
    for (const id of [
      "Turns",
      "Tool calls",
      "Keyboard",
      "Phone",
      "Agents",
      "Nudges",
      "Sub-agents",
      "Tool calls / message",
      "Longest unattended",
      "Human share",
      "Waiting on you",
      "Questions",
      "Denied tools",
      "Tool errors",
      "API retries",
      "Compactions",
    ])
      unavailable.add(id);
  }
  const pending = selected.some((e) => e.status === "scanning");
  const missing = selected.filter((e) => e.status !== "ready");
  const refresh = async () => {
    setRefreshing(true);
    try {
      await Promise.all(
        selected
          .filter((e) => e.status === "ready" || e.status === "scanning" || e.status === "error")
          .map(async (e) => {
            await runAtomCommand(
              appAtomRegistry,
              serverEnvironment.refreshUsageRates,
              { environmentId: e.environmentId, input: {} },
              { reportFailure: false },
            );
            appAtomRegistry.refresh(
              serverEnvironment.stats({ environmentId: e.environmentId, input: request }),
            );
          }),
      );
    } finally {
      setRefreshing(false);
    }
  };
  return (
    <SidebarInset className="h-dvh min-h-0 overflow-hidden overscroll-y-none isolate">
      <div className="flex min-h-0 min-w-0 flex-1 flex-col bg-background text-foreground">
        <WorkspacePageHeader electron={isElectron} className="h-auto">
          <div className="flex w-full min-w-0 flex-wrap items-center gap-2 py-2">
            <WorkspaceBreadcrumb ariaLabel="Stats breadcrumb">
              <WorkspaceBreadcrumbItem current>
                <h1>Stats</h1>
              </WorkspaceBreadcrumbItem>
            </WorkspaceBreadcrumb>
            <div className="ms-auto flex items-center gap-1" role="radiogroup" aria-label="Period">
              {STATS_PERIODS.map((option) => (
                <Button
                  key={option}
                  size="sm"
                  variant={option === period ? "secondary" : "ghost"}
                  role="radio"
                  aria-checked={option === period}
                  onClick={() => setPeriod(option)}
                >
                  {PERIOD_LABELS[option]}
                </Button>
              ))}
            </div>
            <Menu>
              <MenuTrigger render={<Button variant="outline" size="sm" />}>
                {selectedIds === null
                  ? "All environments"
                  : selected.length === 1
                    ? selected[0]!.label
                    : `${selected.length} environments`}
                <ChevronDownIcon className="size-3.5" />
              </MenuTrigger>
              <MenuPopup align="end">
                <MenuCheckboxItem
                  checked={selectedIds === null}
                  onCheckedChange={() => setSelectedIds(null)}
                >
                  All environments
                </MenuCheckboxItem>
                <MenuSeparator />
                {environments.map((e) => (
                  <MenuCheckboxItem
                    key={e.environmentId}
                    checked={e.selected}
                    onCheckedChange={(checked) => {
                      const next = new Set(selected.map((item) => item.environmentId));
                      if (checked) next.add(e.environmentId);
                      else next.delete(e.environmentId);
                      setSelectedIds([...next]);
                    }}
                  >
                    {e.label}
                    {e.status === "ready" || e.status === "unselected" ? "" : ` · ${e.status}`}
                  </MenuCheckboxItem>
                ))}
              </MenuPopup>
            </Menu>
            <Button
              onClick={() => void refresh()}
              aria-label="Refresh stats"
              aria-busy={refreshing || pending}
              disabled={refreshing || selected.length === 0}
              size="icon-sm"
              variant="ghost"
            >
              <RefreshIcon className="size-3.5" refreshing={refreshing || pending} />
            </Button>
          </div>
        </WorkspacePageHeader>
        <ScrollArea className="min-h-0 flex-1">
          <WorkspacePageContainer width="wide">
            <div className="flex flex-col gap-4">
              {missing.length > 0 ? (
                <p role="status" className="text-muted-foreground text-xs">
                  {snapshots.length > 0 ? "Partial totals. " : ""}
                  {missing
                    .map(
                      (e) =>
                        `${e.label}: ${e.status === "unsupported" ? "update this server to enable Stats" : e.status}`,
                    )
                    .join(" · ")}
                </p>
              ) : null}
              {selected.length === 0 ? (
                <p className="text-muted-foreground text-sm">
                  Select an environment to view Stats.
                </p>
              ) : snapshots.length === 0 ? (
                pending ? (
                  <StatsSkeleton />
                ) : (
                  <p className="text-muted-foreground text-sm">
                    Stats is unavailable. Connect or update an environment, then refresh.
                  </p>
                )
              ) : (
                <>
                  {(summary.total.unpricedRecords ?? 0) > 0 ? (
                    <p className="text-muted-foreground text-xs">
                      Costs exclude {summary.total.unpricedRecords} unpriced responses. Set model
                      prices in Usage or refresh pricing.
                    </p>
                  ) : null}
                  <StatsBody summary={summary} unavailable={unavailable} />
                  {notes.length > 0 ? (
                    <details className="text-muted-foreground text-xs">
                      <summary className="cursor-pointer">Data coverage</summary>
                      <ul className="mt-2 list-disc space-y-1 ps-4">
                        {notes.map((note) => (
                          <li key={note}>{note}</li>
                        ))}
                      </ul>
                    </details>
                  ) : null}
                </>
              )}
            </div>
          </WorkspacePageContainer>
        </ScrollArea>
      </div>
    </SidebarInset>
  );
}

function StatsBody({
  summary,
  unavailable,
}: {
  readonly summary: StatsSummary;
  readonly unavailable: ReadonlySet<string>;
}) {
  const groups = statsTileGroups(summary).map((group) => ({
    ...group,
    tiles: group.tiles.map((tile) =>
      unavailable.has(tile.id) ? { ...tile, value: "—", delta: null, series: [] } : tile,
    ),
  }));
  const tables: ReadonlyArray<{ readonly title: string; readonly rows: ReadonlyArray<EffortRow> }> =
    [
      { title: "Activities", rows: activityRows(summary) },
      { title: "Models", rows: modelRows(summary) },
      { title: "Engines", rows: engineRows(summary) },
      { title: "Effort", rows: effortRows(summary) },
    ];
  const streak = summary.streak ?? 0;
  return (
    <div className="flex flex-col gap-6">
      <p className="text-muted-foreground text-xs">
        {summary.from} – {summary.to} · {summary.streakCapped ? "≥" : ""}
        {streak}-day streak · {ESTIMATE_NOTE}
      </p>
      {groups.map((group) => (
        <StatsTileGroupView key={group.id} group={group} />
      ))}
      <section className="flex flex-col gap-2">
        <h2 className="font-medium text-foreground text-sm">Session lengths</h2>
        <SessionLengths summary={summary} />
      </section>
      <section className="flex flex-col gap-3">
        <h2 className="font-medium text-foreground text-sm">Where the effort went</h2>
        {tables.map((table) => (
          <EffortTable key={table.title} title={table.title} rows={table.rows} />
        ))}
        <p className="text-muted-foreground text-xs">{ACTIVITY_FOOTNOTE}</p>
      </section>
    </div>
  );
}

function SessionLengths({ summary }: { readonly summary: StatsSummary }) {
  const rows = sessionLengthRows(summary);
  const max = Math.max(1, ...rows.map((row) => row.count));
  return (
    <div className="flex flex-col gap-1">
      {rows.map((row) => (
        <div key={row.label} className="flex items-center gap-2 text-xs">
          <span className="w-20 shrink-0 text-muted-foreground">{row.label}</span>
          <span className="h-2 flex-1 overflow-hidden rounded bg-muted">
            <span
              className="block h-full bg-primary"
              style={{ width: `${(row.count / max) * 100}%` }}
            />
          </span>
          <span className="w-10 shrink-0 text-right tabular-nums">{row.count}</span>
        </div>
      ))}
      <p className="text-muted-foreground text-xs">{sessionTimeLine(summary)}</p>
    </div>
  );
}

function EffortTable({
  title,
  rows,
}: {
  readonly title: string;
  readonly rows: ReadonlyArray<EffortRow>;
}) {
  if (rows.length === 0) {
    return <p className="text-muted-foreground text-xs">{title}: nothing yet this period</p>;
  }
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-xs">
        <thead className="text-muted-foreground">
          <tr>
            <th className="py-1 text-left font-medium">{title}</th>
            <th className="py-1 text-right font-medium">Stretches</th>
            <th className="py-1 text-right font-medium">Time</th>
            <th className="py-1 text-right font-medium">Tokens</th>
            <th className="py-1 text-right font-medium">Cached</th>
            <th className="py-1 text-right font-medium">Spend</th>
            <th className="py-1 text-right font-medium">Share</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.id} className="border-t">
              <td className="py-1 pr-2">{row.id}</td>
              <td className="py-1 text-right tabular-nums">{row.count}</td>
              <td className="py-1 text-right tabular-nums">{effortText.minutes(row.minutes)}</td>
              <td className="py-1 text-right tabular-nums">{effortText.tokens(row.tokens)}</td>
              <td className="py-1 text-right tabular-nums">{effortText.cached(row.cachedShare)}</td>
              <td className="py-1 text-right tabular-nums">
                {row.unpriced
                  ? row.usd > 0
                    ? `${effortText.usd(row.usd)} + unpriced`
                    : "Unpriced"
                  : effortText.usd(row.usd)}
              </td>
              <td className="py-1 text-right tabular-nums">{effortText.share(row.share)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function StatsSkeleton() {
  return (
    <div className="grid grid-cols-[repeat(auto-fill,minmax(150px,1fr))] gap-2">
      {Array.from({ length: 8 }, (_, index) => (
        <Skeleton key={index} className="h-20 w-full" />
      ))}
    </div>
  );
}
