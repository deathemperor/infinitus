import { useAtomValue } from "@effect/atom-react";
import {
  buildForecast,
  infinitusCapabilityOf,
  infinitusPageState,
  type ForecastLineModel,
  type ForecastModel,
  type ForecastWindowModel,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import type { TimestampFormat } from "@t3tools/contracts/settings";
import { useMemo, type ReactNode } from "react";

import { RefreshIcon } from "~/components/ui/refresh-icon";

import { isElectron } from "../../env";
import { usePrimarySettings } from "../../hooks/useSettings";
import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { primaryServerConfigAtom } from "../../state/server";
import { formatUpcomingTimestamp } from "../../timestampFormat";
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

/**
 * `/utilization` (#747): the native Utilization pane in the fork. Today the
 * forecast section only, read off the `forecast` reply the snapshot already
 * carries (every account's projection at its own measured pace); the history
 * chart and the run-rate table follow the `utilization` verb native is adding.
 * Primary environment only, like Stats.
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
  const forecast = useMemo(() => (snapshot === null ? null : buildForecast(snapshot)), [snapshot]);

  const topbarContent = (
    <div className="flex w-full min-w-0 items-center gap-x-3 py-2">
      <WorkspaceBreadcrumb ariaLabel="Utilization breadcrumb" className="min-w-0">
        <WorkspaceBreadcrumbItem current>
          <h1>Utilization</h1>
        </WorkspaceBreadcrumbItem>
      </WorkspaceBreadcrumb>
      <Button
        className="ms-auto"
        onClick={() => snapshotQuery.refresh()}
        aria-label="Refresh utilization"
        aria-busy={snapshotQuery.isPending}
        disabled={!hasVerb}
        size="icon-sm"
        variant="ghost"
      >
        <RefreshIcon className="size-3.5" refreshing={snapshotQuery.isPending} />
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
    body = <ForecastSection forecast={forecast} />;
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

function UtilizationSkeleton() {
  return (
    <div className="flex flex-col gap-3">
      <Skeleton className="h-4 w-24" />
      <Skeleton className="h-24 w-full" />
      <Skeleton className="h-24 w-full" />
    </div>
  );
}
