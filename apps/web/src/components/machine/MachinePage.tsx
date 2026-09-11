import { useAtomValue } from "@effect/atom-react";
import {
  infinitusCapabilityOf,
  infinitusPageState,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import {
  bytesText,
  decodeMachineReply,
  hookGroups,
  idleHours,
  minutesText,
  ownerKindLabel,
  type HookGroup,
  type MachineReport,
} from "@t3tools/client-runtime/state/infinitusMachine";
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

const MACHINE_INPUT = { command: "machine", args: [], options: {} } as const;
/** Owners shown before "Show all": the ones that need a look sort first. */
const HOOK_GROUPS_SHOWN = 12;
/** A first read answers `{sampling: true}` while native takes its sample;
    one early re-read beats waiting a whole refresh interval for the report. */
const SAMPLING_RETRY_MS = 5_000;

/**
 * `/machine` (#659): the pop-out's Machine pane in the fork — the Mac's
 * health as Infinitus sees it: load and swap, the hooks Claude Code runs
 * grouped by who installed them, runaway processes, leftover files, and the
 * Claude sessions' footprint. Reads `machine` through the machine query atom,
 * held and re-read every minute only while this page is mounted (native
 * samples at most once per 55 s). Read-only: the pane's kill, reclaim and
 * disable buttons stay on the Mac. Primary environment only.
 */
export function MachinePage() {
  const environmentId = usePrimaryEnvironmentId();
  const capability = infinitusCapabilityOf(
    useAtomValue(primaryServerConfigAtom)?.environment.capabilities,
  );
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const minute = useNowMinute();
  const ready = capability === true && environmentId !== null;
  const snapshotQuery = useEnvironmentQuery(
    ready ? infinitusEnvironment.snapshot({ environmentId, input: {} }) : null,
  );
  const snapshot = snapshotQuery.data;
  const hasVerb =
    snapshot?.available === true && snapshot.commands.some((command) => command.name === "machine");
  const machineQuery = useEnvironmentQuery(
    ready && hasVerb ? infinitusEnvironment.machine({ environmentId, input: MACHINE_INPUT }) : null,
  );
  const reply = useMemo(
    () => (machineQuery.data === null ? null : decodeMachineReply(machineQuery.data.result)),
    [machineQuery.data],
  );
  const sampling = reply?._tag === "sampling";
  const refresh = machineQuery.refresh;
  useEffect(() => {
    if (!sampling) return;
    const timer = setTimeout(refresh, SAMPLING_RETRY_MS);
    return () => clearTimeout(timer);
  }, [sampling, refresh]);

  const topbarContent = (
    <div className="flex w-full min-w-0 items-center gap-x-3 py-2">
      <WorkspaceBreadcrumb ariaLabel="Machine breadcrumb" className="min-w-0">
        <WorkspaceBreadcrumbItem current>
          <h1>Machine</h1>
        </WorkspaceBreadcrumbItem>
      </WorkspaceBreadcrumb>
      <Button
        className="ms-auto"
        onClick={() => machineQuery.refresh()}
        aria-label="Refresh machine report"
        aria-busy={machineQuery.isPending}
        disabled={!hasVerb}
        size="icon-sm"
        variant="ghost"
      >
        <RefreshIcon className="size-3.5" refreshing={machineQuery.isPending} />
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
    body = <MachineSkeleton />;
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
      <p className="text-muted-foreground text-sm">This Infinitus build has no machine verb.</p>
    );
  } else if (machineQuery.error !== null) {
    body = <p className="text-destructive text-sm">{machineQuery.error}</p>;
  } else if (reply === null) {
    body =
      machineQuery.data === null ? (
        <MachineSkeleton />
      ) : (
        <p className="text-muted-foreground text-sm">The machine reply could not be read.</p>
      );
  } else if (reply._tag === "sampling") {
    body = (
      <div className="flex flex-col gap-3">
        <p className="text-muted-foreground text-sm">Sampling the machine…</p>
        <MachineSkeleton />
      </div>
    );
  } else {
    body = (
      <MachineBody
        report={reply.report}
        sampledAt={formatShortTimestamp(reply.report.sample.at, timestampFormat)}
        nowMs={Date.parse(minute)}
      />
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

function MachineBody({
  report,
  sampledAt,
  nowMs,
}: {
  readonly report: MachineReport;
  readonly sampledAt: string;
  readonly nowMs: number;
}) {
  const s = report.sample;
  const summary: ReadonlyArray<readonly [string, ReactNode]> = [
    ["Sampled", sampledAt],
    [
      "Load",
      `${(s.load1 ?? 0).toFixed(2)} / ${s.cores ?? 0} cores · ${(s.load5 ?? 0).toFixed(2)} over 5 min`,
    ],
    ["Swap", `${s.swapUsedMB ?? 0} / ${s.swapTotalMB ?? 0} MB`],
    [
      "Processes",
      `${s.processes ?? 0} total, ${s.running ?? 0} running, ${s.uninterruptible ?? 0} uninterruptible, ${s.zombies ?? 0} zombies`,
    ],
    ["WindowServer", `${Math.round(s.windowServerCPU ?? 0)}% CPU`],
    [
      "Temp entries",
      s.tempEntries === undefined ? (
        <span key="temp" className="text-destructive">
          Listing timed out
        </span>
      ) : (
        s.tempEntries.toLocaleString("en-US")
      ),
    ],
    ["Claude sessions", `${s.claudeRSSMB ?? 0} MB resident`],
  ];
  return (
    <div className="flex flex-col gap-6">
      <Section title="Summary">
        <KeyValues rows={summary} />
      </Section>
      <Section title="Warnings">
        {report.warnings.length === 0 ? (
          <Muted>Nothing to flag.</Muted>
        ) : (
          <ul className="flex flex-col gap-1 text-sm">
            {report.warnings.map((warning, index) => (
              <li key={`${index}:${warning}`} className="text-destructive">
                {warning}
              </li>
            ))}
          </ul>
        )}
      </Section>
      <Section title="Hooks">
        <Hooks hooks={report.hooks} />
      </Section>
      <Section title="Runaways">
        {report.runaways.length === 0 ? (
          <Muted>None.</Muted>
        ) : (
          <ul className="flex flex-col gap-1 text-sm">
            {report.runaways.map((runaway) => (
              <li key={runaway.pid} className="flex flex-col">
                <span className="truncate font-mono text-xs">{runaway.command}</span>
                <span className="text-muted-foreground text-xs">
                  pid {runaway.pid} · {runaway.rssMB ?? 0} MB ·{" "}
                  {minutesText(runaway.elapsedSeconds ?? 0)} · {runaway.why}
                </span>
              </li>
            ))}
          </ul>
        )}
      </Section>
      <Section title="Residue">
        <KeyValues
          rows={[
            ["Stale sockets", `${report.residue.staleSockets ?? 0}`],
            ["Stale session-env dirs", `${report.residue.staleSessionEnvs ?? 0}`],
            ["Temp entries", `${report.residue.tempEntries ?? 0}`],
            ["Transcripts", bytesText(report.residue.transcriptsBytes ?? 0)],
            ["Plugin cache", bytesText(report.residue.pluginCacheBytes ?? 0)],
            ["claude-mem", bytesText(report.residue.memBytes ?? 0)],
          ]}
        />
      </Section>
      <Section title="Sessions">
        {report.sessions.length === 0 ? (
          <Muted>No Claude sessions.</Muted>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead className="text-muted-foreground">
                <tr>
                  <th className="py-1 text-left font-medium">Session</th>
                  <th className="py-1 text-right font-medium">Age</th>
                  <th className="py-1 text-right font-medium">RSS</th>
                  <th className="py-1 text-right font-medium">Idle</th>
                </tr>
              </thead>
              <tbody>
                {report.sessions.map((session) => {
                  const idle = idleHours(session, nowMs);
                  return (
                    <tr key={session.pid} className="border-border/50 border-t">
                      <td className="max-w-0 py-1">
                        <div className="truncate">{session.name}</div>
                        <div className="truncate text-muted-foreground">{session.cwd}</div>
                      </td>
                      <td className="py-1 text-right tabular-nums">
                        {minutesText(session.ageSeconds ?? 0)}
                      </td>
                      <td className="py-1 text-right tabular-nums">{session.rssMB ?? 0} MB</td>
                      <td className="py-1 text-right tabular-nums">
                        {idle === null ? "—" : `${idle} h`}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Section>
      <p className="text-muted-foreground text-xs">
        Read-only here; killing, reclaiming and disabling stay in the Mac app.
      </p>
    </div>
  );
}

function Hooks({ hooks }: { readonly hooks: MachineReport["hooks"] }) {
  const [showAll, setShowAll] = useState(false);
  const groups = useMemo(() => hookGroups(hooks), [hooks]);
  if (groups.length === 0) return <Muted>No hooks registered.</Muted>;
  const shown = showAll ? groups : groups.slice(0, HOOK_GROUPS_SHOWN);
  return (
    <div className="flex flex-col gap-2">
      <ul className="flex flex-col gap-1">
        {shown.map((group) => (
          <HookGroupRow key={group.owner} group={group} />
        ))}
      </ul>
      {groups.length > HOOK_GROUPS_SHOWN ? (
        <Button
          size="sm"
          variant="ghost"
          className="self-start"
          onClick={() => setShowAll((value) => !value)}
        >
          {showAll ? "Show fewer" : `Show all ${groups.length} owners`}
        </Button>
      ) : null}
    </div>
  );
}

function HookGroupRow({ group }: { readonly group: HookGroup }) {
  const live =
    group.instances === 0
      ? null
      : `${group.instances} live${group.helpers > 0 ? ` + ${group.helpers} helpers` : ""}`;
  return (
    <li className="flex flex-col gap-0.5 text-sm">
      <div className="flex flex-wrap items-center gap-x-2">
        <span className="font-medium">{group.owner}</span>
        <span className="text-muted-foreground text-xs">{ownerKindLabel(group.kind)}</span>
        {group.risky ? <Chip>Heavy</Chip> : null}
        {group.stuck > 0 ? <Chip destructive>{group.stuck} stuck</Chip> : null}
        {live !== null ? <span className="text-xs">{live}</span> : null}
        {group.oldestSeconds > 0 ? (
          <span className="text-muted-foreground text-xs">
            oldest {minutesText(group.oldestSeconds)}
          </span>
        ) : null}
      </div>
      <p className="text-muted-foreground text-xs">
        {group.registrations} {group.registrations === 1 ? "hook" : "hooks"} on{" "}
        {group.events.join(", ")} · {Math.round(group.spawnsPerHour)}/h expected
      </p>
    </li>
  );
}

function Section({ title, children }: { readonly title: string; readonly children: ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <h2 className="font-medium text-foreground text-sm">{title}</h2>
      {children}
    </section>
  );
}

function KeyValues({ rows }: { readonly rows: ReadonlyArray<readonly [string, ReactNode]> }) {
  return (
    <dl className="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
      {rows.map(([label, value]) => (
        <div key={label} className="contents">
          <dt className="text-muted-foreground">{label}</dt>
          <dd className="tabular-nums">{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function Chip({
  children,
  destructive = false,
}: {
  readonly children: ReactNode;
  readonly destructive?: boolean;
}) {
  return (
    <span
      className={
        destructive
          ? "rounded bg-destructive/10 px-1.5 py-0.5 text-[10px] text-destructive uppercase"
          : "rounded bg-muted px-1.5 py-0.5 text-[10px] text-muted-foreground uppercase"
      }
    >
      {children}
    </span>
  );
}

function Muted({ children }: { readonly children: ReactNode }) {
  return <p className="text-muted-foreground text-sm">{children}</p>;
}

function MachineSkeleton() {
  return (
    <div className="flex flex-col gap-2">
      {Array.from({ length: 6 }, (_, index) => (
        <Skeleton key={index} className="h-6 w-full" />
      ))}
    </div>
  );
}
