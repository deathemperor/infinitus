import { useAtomValue } from "@effect/atom-react";
import {
  infinitusCapabilityOf,
  infinitusPageState,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import {
  ACTIVITY_FOOTNOTE,
  activityRows,
  decodeStatsSummary,
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
} from "@t3tools/client-runtime/state/infinitusStats";
import * as Schema from "effect/Schema";
import { useMemo, type ReactNode } from "react";

import { RefreshIcon } from "~/components/ui/refresh-icon";

import { isElectron } from "../../env";
import { useLocalStorage } from "../../hooks/useLocalStorage";
import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { primaryServerConfigAtom } from "../../state/server";
import { AccountsUnavailable } from "../accounts/AccountsUnavailable";
import { Button } from "../ui/button";
import { ScrollArea } from "../ui/scroll-area";
import { SidebarInset } from "../ui/sidebar";
import { Skeleton } from "../ui/skeleton";
import { WorkspaceBreadcrumb, WorkspaceBreadcrumbItem } from "../WorkspaceBreadcrumb";
import { WorkspacePageContainer } from "../WorkspacePageContainer";
import { WorkspacePageHeader } from "../WorkspacePageHeader";
import { StatsTileGroupView } from "./StatsTiles";

const PERIOD_KEY = "infinitus.statsPeriod";
const PERIOD_LABELS: Record<StatsPeriod, string> = {
  day: "Today",
  week: "Week",
  month: "Month",
  year: "Year",
};
const ESTIMATE_NOTE = "Estimates from transcripts and repos on the Mac, never billing truth.";

/**
 * `/stats` (#659): the pop-out's Stats pane, in the fork. Reads `stats
 * --period p` through the stats query atom, which is held and re-read every
 * 5 min only while this page is mounted, and subscribes to the snapshot with
 * `needs: ["stats"]` so the server's lease carries the `stats` scope — the
 * Mac's transcript rescan runs at its 5-min cadence only while someone is
 * looking (#625). Primary environment only.
 */
export function StatsPage() {
  const environmentId = usePrimaryEnvironmentId();
  const capability = infinitusCapabilityOf(
    useAtomValue(primaryServerConfigAtom)?.environment.capabilities,
  );
  const [period, setPeriod] = useLocalStorage<StatsPeriod, string>(
    PERIOD_KEY,
    "week",
    Schema.Literals(STATS_PERIODS),
  );
  const ready = capability === true && environmentId !== null;
  const snapshotQuery = useEnvironmentQuery(
    ready ? infinitusEnvironment.snapshot({ environmentId, input: { needs: ["stats"] } }) : null,
  );
  const snapshot = snapshotQuery.data;
  const hasVerb =
    snapshot?.available === true && snapshot.commands.some((command) => command.name === "stats");
  const statsQuery = useEnvironmentQuery(
    ready && hasVerb
      ? infinitusEnvironment.stats({
          environmentId,
          input: { command: "stats", args: [], options: { period } },
        })
      : null,
  );
  const summary = useMemo(
    () => (statsQuery.data === null ? null : decodeStatsSummary(statsQuery.data.result)),
    [statsQuery.data],
  );

  const topbarContent = (
    <div className="flex w-full min-w-0 items-center gap-x-3 py-2">
      <WorkspaceBreadcrumb ariaLabel="Stats breadcrumb" className="min-w-0">
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
      <Button
        onClick={() => statsQuery.refresh()}
        aria-label="Refresh stats"
        aria-busy={statsQuery.isPending}
        disabled={!hasVerb}
        size="icon-sm"
        variant="ghost"
      >
        <RefreshIcon className="size-3.5" refreshing={statsQuery.isPending} />
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
    body = <StatsSkeleton />;
  } else if (gate === "unavailable") {
    body = (
      <AccountsUnavailable
        reason={snapshot.unavailableReason ?? null}
        socketPath={snapshot.status?.socket ?? null}
        onRetry={snapshotQuery.refresh}
      />
    );
  } else if (!hasVerb) {
    body = <p className="text-muted-foreground text-sm">This Infinitus build has no stats verb.</p>;
  } else if (statsQuery.error !== null) {
    body = <p className="text-destructive text-sm">{statsQuery.error}</p>;
  } else if (summary === null) {
    body =
      statsQuery.data === null ? (
        <StatsSkeleton />
      ) : (
        <p className="text-muted-foreground text-sm">The stats reply could not be read.</p>
      );
  } else {
    body = <StatsBody summary={summary} />;
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

function StatsBody({ summary }: { readonly summary: StatsSummary }) {
  const groups = statsTileGroups(summary);
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
        {summary.from} – {summary.to} · {streak}-day streak · {ESTIMATE_NOTE}
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
              <td className="py-1 text-right tabular-nums">{effortText.usd(row.usd)}</td>
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
