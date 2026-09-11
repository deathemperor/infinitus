import { useAtomValue } from "@effect/atom-react";
import {
  ACTIVITY_KIND_LABELS,
  activityRows,
  decodeEventRows,
} from "@t3tools/client-runtime/state/infinitusActivity";
import type { InfinitusEvent } from "@t3tools/contracts/infinitus";
import { useEffect, useMemo, useState, type ReactNode } from "react";

import { RefreshIcon } from "~/components/ui/refresh-icon";

import { isElectron } from "../../env";
import { useNowMinute } from "../../hooks/useNowMinute";
import { usePrimarySettings } from "../../hooks/useSettings";
import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { primaryServerConfigAtom } from "../../state/server";
import { formatShortTimestamp } from "../../timestampFormat";
import { AccountsUnavailable } from "../accounts/AccountsUnavailable";
import { Button } from "../ui/button";
import { ScrollArea } from "../ui/scroll-area";
import { SidebarInset } from "../ui/sidebar";
import { Skeleton } from "../ui/skeleton";
import { WorkspaceBreadcrumb, WorkspaceBreadcrumbItem } from "../WorkspaceBreadcrumb";
import { WorkspacePageContainer } from "../WorkspacePageContainer";
import { WorkspacePageHeader } from "../WorkspacePageHeader";
import { activityDays } from "./activity.logic";

const EVENTS_INPUT = { command: "events", args: [], options: { limit: "100" } } as const;

/**
 * `/activity` (#659): the pop-out's Activity pane, in the fork — every
 * account change Infinitus made, newest first. `events --limit 100` is read
 * once through the events query atom (dropped a minute after the page
 * leaves); everything after arrives as the snapshot subscription's deltas,
 * the same stream the toasts read, so the page never polls on its own.
 * Primary environment only.
 */
export function ActivityPage() {
  const environmentId = usePrimaryEnvironmentId();
  const capability = useAtomValue(primaryServerConfigAtom)?.environment.capabilities.infinitus;
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const minute = useNowMinute();
  const ready = capability === true && environmentId !== null;
  const snapshotQuery = useEnvironmentQuery(
    ready ? infinitusEnvironment.snapshot({ environmentId, input: {} }) : null,
  );
  const snapshot = snapshotQuery.data;
  const hasVerb =
    snapshot?.available === true && snapshot.commands.some((command) => command.name === "events");
  const eventsQuery = useEnvironmentQuery(
    ready && hasVerb ? infinitusEnvironment.events({ environmentId, input: EVENTS_INPUT }) : null,
  );
  const initial = useMemo(
    () => (eventsQuery.data === null ? null : decodeEventRows(eventsQuery.data.result)),
    [eventsQuery.data],
  );

  // Deltas since mount: each snapshot carries the events new to that poll.
  const [deltas, setDeltas] = useState<ReadonlyArray<InfinitusEvent>>([]);
  const news = snapshot?.events;
  useEffect(() => {
    if (news === undefined || news.length === 0) return;
    setDeltas((previous) => [...previous, ...news]);
  }, [news]);
  useEffect(() => setDeltas([]), [environmentId]);

  const days = useMemo(
    () => (initial === null ? [] : activityDays(activityRows(initial, deltas), Date.parse(minute))),
    [initial, deltas, minute],
  );

  const topbarContent = (
    <div className="flex w-full min-w-0 items-center gap-x-3 py-2">
      <WorkspaceBreadcrumb ariaLabel="Activity breadcrumb" className="min-w-0">
        <WorkspaceBreadcrumbItem current>
          <h1>Activity</h1>
        </WorkspaceBreadcrumbItem>
      </WorkspaceBreadcrumb>
      <Button
        className="ms-auto"
        onClick={() => eventsQuery.refresh()}
        aria-label="Refresh activity"
        aria-busy={eventsQuery.isPending}
        disabled={!hasVerb}
        size="icon-sm"
        variant="ghost"
      >
        <RefreshIcon className="size-3.5" refreshing={eventsQuery.isPending} />
      </Button>
    </div>
  );

  let body: ReactNode;
  if (capability !== true) {
    body = (
      <section className="max-w-xl rounded-lg border p-4">
        <p className="text-muted-foreground text-sm">
          This server has no Infinitus adapter for this platform.
        </p>
      </section>
    );
  } else if (snapshot === null) {
    body = <ActivitySkeleton />;
  } else if (!snapshot.available) {
    body = (
      <AccountsUnavailable
        reason={snapshot.unavailableReason ?? null}
        socketPath={snapshot.status?.socket ?? null}
        onRetry={snapshotQuery.refresh}
      />
    );
  } else if (!hasVerb) {
    body = (
      <p className="text-muted-foreground text-sm">This Infinitus build has no events verb.</p>
    );
  } else if (eventsQuery.error !== null) {
    body = <p className="text-destructive text-sm">{eventsQuery.error}</p>;
  } else if (initial === null) {
    body =
      eventsQuery.data === null ? (
        <ActivitySkeleton />
      ) : (
        <p className="text-muted-foreground text-sm">The events reply could not be read.</p>
      );
  } else if (days.length === 0) {
    body = <p className="text-muted-foreground text-sm">Nothing logged yet.</p>;
  } else {
    body = (
      <div className="flex flex-col gap-5">
        <p className="text-muted-foreground text-xs">
          Every account change Infinitus made, newest first.
        </p>
        {days.map((day) => (
          <section key={day.label} className="flex flex-col gap-1">
            <h2 className="font-medium text-foreground text-sm">{day.label}</h2>
            <ul className="flex flex-col">
              {day.rows.map((row) => {
                const chip = ACTIVITY_KIND_LABELS[row.kind];
                return (
                  <li key={row.id} className="flex items-baseline gap-2 py-1 text-xs">
                    <span className="w-16 shrink-0 text-muted-foreground tabular-nums">
                      {formatShortTimestamp(row.at, timestampFormat)}
                    </span>
                    {chip === undefined ? null : (
                      <span className="shrink-0 rounded bg-muted px-1 text-[10px] text-muted-foreground">
                        {chip}
                      </span>
                    )}
                    <span className="min-w-0 break-words text-foreground">{row.text}</span>
                  </li>
                );
              })}
            </ul>
          </section>
        ))}
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

function ActivitySkeleton() {
  return (
    <div className="flex flex-col gap-2">
      {Array.from({ length: 6 }, (_, index) => (
        <Skeleton key={index} className="h-4 w-full" />
      ))}
    </div>
  );
}
