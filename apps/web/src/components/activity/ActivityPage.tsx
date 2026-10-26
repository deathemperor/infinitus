import { useAtomValue } from "@effect/atom-react";
import {
  infinitusCapabilityOf,
  infinitusPageState,
} from "@infinitus/client-runtime/state/infinitusAccounts";
import {
  ACTIVITY_KIND_LABELS,
  activityRows,
  decodeEventRows,
  isPollRow,
} from "@infinitus/client-runtime/state/infinitusActivity";
import type { InfinitusEvent } from "@infinitus/contracts/infinitus";
import * as Schema from "effect/Schema";
import { useState, type ReactNode } from "react";

import { RefreshIcon } from "~/components/ui/refresh-icon";

import { useLocalStorage } from "../../hooks/useLocalStorage";
import { useNowMinute } from "../../hooks/useNowMinute";
import { usePrimarySettings } from "../../hooks/useSettings";
import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { primaryServerConfigAtom } from "../../state/server";
import { formatShortTimestamp } from "../../timestampFormat";
import { AccountsUnavailable } from "../accounts/AccountsUnavailable";
import { SettingsPageContainer, SettingsSection } from "../settings/settingsLayout";
import { Button } from "../ui/button";
import { Skeleton } from "../ui/skeleton";
import { activityDays } from "./activity.logic";

const EVENTS_INPUT = { command: "events", args: [], options: { limit: "100" } } as const;
/** Whether the poller's per-minute lines show; off by default (#696). */
const SHOW_POLLS_KEY = "infinitus.activityShowPolls";

/**
 * Settings › Engines › Activity (#659): every account change Infinitus made, newest first, reached
 * from swapd's row on the Engines page. `events --limit 100` is read once through the events query
 * atom; later changes arrive as the snapshot subscription's deltas, so the page never polls.
 * Primary environment only.
 */
export function ActivityPage() {
  const environmentId = usePrimaryEnvironmentId();
  const capability = infinitusCapabilityOf(
    useAtomValue(primaryServerConfigAtom)?.environment.capabilities,
  );
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const minute = useNowMinute();
  const [showPolls, setShowPolls] = useLocalStorage<boolean, boolean>(
    SHOW_POLLS_KEY,
    false,
    Schema.Boolean,
  );
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
  const initial = eventsQuery.data === null ? null : decodeEventRows(eventsQuery.data.result);

  // Deltas since mount: each snapshot carries the events new to that poll.
  // The batch already on hand at mount or at an environment switch is the
  // events read's to show, so collection starts from the next one.
  const news = snapshot?.events;
  const [collected, setCollected] = useState<{
    environmentId: typeof environmentId;
    news: typeof news;
    deltas: ReadonlyArray<InfinitusEvent>;
  }>({ environmentId, news, deltas: [] });
  if (collected.environmentId !== environmentId) {
    setCollected({ environmentId, news, deltas: [] });
  } else if (collected.news !== news) {
    setCollected({
      environmentId,
      news,
      deltas:
        news === undefined || news.length === 0 ? collected.deltas : [...collected.deltas, ...news],
    });
  }
  const deltas = collected.deltas;

  // The store keeps every row so the toggle is instant; only the view drops
  // the poller's lines.
  const rows = initial === null ? [] : activityRows(initial, deltas);
  const visible = showPolls ? rows : rows.filter((row) => !isPollRow(row));
  const hiddenPolls = rows.length - visible.length;
  const days = activityDays(visible, Date.parse(minute));

  const headerAction = (
    <div className="flex items-center gap-x-2">
      <Button
        size="sm"
        variant={showPolls ? "secondary" : "ghost"}
        aria-pressed={showPolls}
        onClick={() => setShowPolls((previous) => !previous)}
      >
        Show polls
      </Button>
      <Button
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
    body = <ActivitySkeleton />;
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
    body = (
      <p className="text-muted-foreground text-sm">
        {hiddenPolls === 0
          ? "Nothing logged yet."
          : "Only polls so far. Turn on Show polls to see them."}
      </p>
    );
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
                      <span className="shrink-0 rounded bg-muted px-1 text-3xs text-muted-foreground">
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
    <SettingsPageContainer>
      <SettingsSection
        id="infinitus-activity"
        title="Activity"
        variant="plain"
        headerAction={headerAction}
      >
        <div className="px-3 sm:px-4">{body}</div>
      </SettingsSection>
    </SettingsPageContainer>
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
