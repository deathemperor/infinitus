import { useAtomValue } from "@effect/atom-react";
import {
  accountCommandArgs,
  accountsPageState,
  addAccountCommandArgs,
  buildFleetSection,
  buildForecast,
  buildSignInRows,
  signInCommandArgs,
  snapshotOffersAdd,
  snapshotSignInRunning,
  waitAddCommandArgs,
  type AccountAction,
  type AccountRowModel,
  type SignInRowModel,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import { exhaustedBand } from "@t3tools/client-runtime/state/infinitusExhausted";
import type { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import { ChevronDownIcon } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { RefreshIcon } from "~/components/ui/refresh-icon";

import { isElectron } from "../../env";
import { useNowMinute } from "../../hooks/useNowMinute";
import { useEnvironments, usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { Button } from "../ui/button";
import { Menu, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuTrigger } from "../ui/menu";
import { ScrollArea } from "../ui/scroll-area";
import { SidebarInset } from "../ui/sidebar";
import { Skeleton } from "../ui/skeleton";
import {
  WorkspaceBreadcrumb,
  WorkspaceBreadcrumbItem,
  WorkspaceBreadcrumbSeparator,
} from "../WorkspaceBreadcrumb";
import { WorkspacePageContainer } from "../WorkspacePageContainer";
import { WorkspacePageHeader } from "../WorkspacePageHeader";
import { AccountsUnavailable } from "./AccountsUnavailable";
import { WAIT_ADD_STEP_SECONDS, waitAddStep, type AddAccountFlow } from "./addAccount.logic";
import { FleetSection } from "./FleetSection";
import { ForecastStrip } from "./ForecastStrip";
import { SignInsSection } from "./SignInsSection";

/** How long a command may hold its row's spinner when no snapshot follows it. */
const COMMAND_SETTLE_TIMEOUT_MS = 10_000;

interface CommandTarget {
  readonly fleetKey: string;
  readonly number: number;
}

/** A command whose row shows a spinner, tagged with the snapshot it was sent
    against: any newer snapshot is the app's answer and retires the spinner. */
interface PendingCommand extends CommandTarget {
  readonly action: AccountAction;
  readonly snapshot: InfinitusSnapshot | null;
}

/** A sign-in just started, keyed by its row; the next snapshot carries the
    login's own phase and takes over from the spinner. */
interface PendingSignIn {
  readonly key: string;
  readonly snapshot: InfinitusSnapshot | null;
}

/** What the socket said went wrong, in the words the error carries. */
function commandErrorMessage(cause: Cause.Cause<unknown>): string {
  const error: unknown = Cause.squash(cause);
  if (typeof error === "object" && error !== null) {
    const tagged = error as { readonly _tag?: unknown; readonly error?: unknown };
    if (tagged._tag === "InfinitusCommandFailed" && typeof tagged.error === "string") {
      return tagged.error;
    }
    if (tagged._tag === "InfinitusUnavailable") {
      const unavailable = error as { readonly cause?: unknown };
      if (typeof unavailable.cause === "string") return unavailable.cause;
    }
    if (error instanceof Error && error.message.trim() !== "") return error.message;
  }
  return "The command failed.";
}

/**
 * Every account the selected environment's engines report, one section per
 * fleet. The row model does the deriving (`@t3tools/client-runtime/state/infinitusAccounts`);
 * this page only picks the environment, draws the models and forwards each
 * button to the control socket.
 */
export function AccountsPage() {
  const { environments } = useEnvironments();
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  const serverConfigs = useAtomValue(environmentServerConfigsAtom);
  const [chosenEnvironmentId, setChosenEnvironmentId] = useState<EnvironmentId | null>(null);
  const [pending, setPending] = useState<PendingCommand | null>(null);
  const [failure, setFailure] = useState<(CommandTarget & { message: string }) | null>(null);
  const [pendingSignIn, setPendingSignIn] = useState<PendingSignIn | null>(null);
  const [signInFailure, setSignInFailure] = useState<{ key: string; message: string } | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [addFlow, setAddFlow] = useState<AddAccountFlow | null>(null);
  // Each add/re-login gets a run number; a newer run or an unmount retires
  // the polling loop of the one before it.
  const addRunRef = useRef(0);
  useEffect(
    () => () => {
      addRunRef.current += 1;
    },
    [],
  );

  const infinitusEnvironments = useMemo(
    () =>
      environments.filter(
        (environment) =>
          serverConfigs.get(environment.environmentId)?.environment.capabilities.infinitus === true,
      ),
    [environments, serverConfigs],
  );
  const environmentId =
    infinitusEnvironments.find((environment) => environment.environmentId === chosenEnvironmentId)
      ?.environmentId ??
    infinitusEnvironments.find((environment) => environment.environmentId === primaryEnvironmentId)
      ?.environmentId ??
    infinitusEnvironments[0]?.environmentId ??
    null;
  const capability =
    environmentId === null
      ? undefined
      : serverConfigs.get(environmentId)?.environment.capabilities.infinitus;

  const snapshotQuery = useEnvironmentQuery(
    environmentId === null ? null : infinitusEnvironment.snapshot({ environmentId, input: {} }),
  );
  const snapshot = snapshotQuery.data;
  const state = accountsPageState({ capability, snapshot });
  // The exhausted band's "reset has passed" reads against the shared minute clock.
  const minute = useNowMinute();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });

  // The spinner lives only as long as the snapshot the command was sent
  // against; the timeout covers a command the app answered without changing
  // anything a snapshot would carry.
  const inFlight = pending !== null && pending.snapshot === snapshot ? pending : null;
  useEffect(() => {
    if (pending === null) return;
    const timer = setTimeout(() => setPending(null), COMMAND_SETTLE_TIMEOUT_MS);
    return () => clearTimeout(timer);
  }, [pending]);
  const signInInFlight =
    pendingSignIn !== null && pendingSignIn.snapshot === snapshot ? pendingSignIn.key : null;
  useEffect(() => {
    if (pendingSignIn === null) return;
    const timer = setTimeout(() => setPendingSignIn(null), COMMAND_SETTLE_TIMEOUT_MS);
    return () => clearTimeout(timer);
  }, [pendingSignIn]);

  const dispatch = async (
    fleetKey: string,
    row: AccountRowModel,
    action: AccountAction,
    alias?: string,
  ) => {
    if (environmentId === null) return;
    const { command, args } = accountCommandArgs(fleetKey, row, action, alias);
    setPending({ fleetKey, number: row.number, action, snapshot });
    const result = await runCommand({
      environmentId,
      input: { command, args, options: {} },
    });
    if (result._tag === "Success") {
      setFailure(null);
      return;
    }
    setPending(null);
    setFailure({ fleetKey, number: row.number, message: commandErrorMessage(result.cause) });
  };

  const signIn = async (row: SignInRowModel) => {
    if (environmentId === null) return;
    setPendingSignIn({ key: row.key, snapshot });
    const result = await runCommand({ environmentId, input: signInCommandArgs(row) });
    if (result._tag === "Success") {
      setSignInFailure(null);
      return;
    }
    setPendingSignIn(null);
    setSignInFailure({ key: row.key, message: commandErrorMessage(result.cause) });
  };

  // `add <fleet>` puts the app's own sign-in on the Mac's screen; the page then
  // polls `wait-add` in short steps until the app says the flow ended. The new
  // account arrives through the snapshot: the server re-reads the fleets after
  // every forwarded command.
  const startAdd = async (fleetKey: string, target: AccountRowModel | null) => {
    if (environmentId === null) return;
    const run = ++addRunRef.current;
    const live = () => addRunRef.current === run;
    const targetLabel = target?.label ?? null;
    const phase = (next: AddAccountFlow["phase"]) => {
      if (live()) setAddFlow({ fleetKey, target: targetLabel, phase: next });
    };
    phase({ kind: "starting" });
    const started = await runCommand({ environmentId, input: addAccountCommandArgs(fleetKey) });
    if (started._tag === "Failure") {
      phase({ kind: "failed", message: commandErrorMessage(started.cause) });
      return;
    }
    phase({ kind: "waiting" });
    const startedAt = Date.now();
    while (live()) {
      const answer = await runCommand({
        environmentId,
        input: waitAddCommandArgs(WAIT_ADD_STEP_SECONDS),
      });
      const step = waitAddStep(
        answer._tag === "Success"
          ? { result: answer.value.result }
          : { failure: commandErrorMessage(answer.cause) },
        Date.now() - startedAt,
      );
      if (step.kind === "poll") continue;
      phase(step.kind === "done" ? step : { kind: "failed", message: step.message });
      return;
    }
  };

  const refresh = async () => {
    if (environmentId === null || isRefreshing) return;
    setIsRefreshing(true);
    await runCommand({ environmentId, input: { command: "refresh", args: [], options: {} } });
    setIsRefreshing(false);
  };

  const selectedLabel =
    infinitusEnvironments.find((environment) => environment.environmentId === environmentId)
      ?.label ?? "No environment";

  const topbarContent = (
    <div className="flex w-full min-w-0 items-center gap-x-3 py-2">
      <WorkspaceBreadcrumb ariaLabel="Accounts breadcrumb" className="min-w-0">
        <WorkspaceBreadcrumbItem>
          <h1>Accounts</h1>
        </WorkspaceBreadcrumbItem>
        <WorkspaceBreadcrumbSeparator />
        <WorkspaceBreadcrumbItem current className="min-w-10">
          <Menu>
            <MenuTrigger className="group/accounts-environment inline-flex min-w-0 max-w-full cursor-pointer items-center gap-1 rounded-sm text-left focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring">
              <span className="min-w-0 truncate">{selectedLabel}</span>
              <ChevronDownIcon
                className="size-3.5 shrink-0 text-muted-foreground opacity-0 transition-opacity group-hover/accounts-environment:opacity-100 group-focus-visible/accounts-environment:opacity-100 group-data-popup-open/accounts-environment:opacity-100"
                aria-hidden
              />
            </MenuTrigger>
            <MenuPopup align="start" className="w-72 max-w-[calc(100vw-2rem)]">
              <MenuRadioGroup
                value={environmentId}
                onValueChange={(value) => setChosenEnvironmentId(value as EnvironmentId)}
              >
                {infinitusEnvironments.map((environment) => (
                  <MenuRadioItem
                    key={environment.environmentId}
                    value={environment.environmentId}
                    closeOnClick
                  >
                    {environment.label}
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
              {infinitusEnvironments.length === 0 ? (
                <p className="px-2 py-2 text-muted-foreground text-xs">
                  No connected environment runs Infinitus.
                </p>
              ) : null}
            </MenuPopup>
          </Menu>
        </WorkspaceBreadcrumbItem>
      </WorkspaceBreadcrumb>
      <Button
        className="ms-auto"
        onClick={() => void refresh()}
        aria-label="Refresh accounts"
        aria-busy={isRefreshing}
        disabled={isRefreshing || environmentId === null}
        size="icon-sm"
        variant="ghost"
      >
        <RefreshIcon className="size-3.5" refreshing={isRefreshing} />
      </Button>
    </div>
  );

  return (
    <SidebarInset className="h-dvh min-h-0 overflow-hidden overscroll-y-none bg-background text-foreground isolate">
      <div className="flex min-h-0 min-w-0 flex-1 flex-col bg-background text-foreground">
        <WorkspacePageHeader electron={isElectron} className="h-auto">
          {topbarContent}
        </WorkspacePageHeader>

        <ScrollArea className="min-h-0 flex-1">
          <WorkspacePageContainer width="wide">
            <AccountsBody
              state={state}
              snapshot={snapshot}
              nowMs={Date.parse(minute)}
              pending={inFlight}
              failure={failure}
              pendingSignIn={signInInFlight}
              signInFailure={signInFailure}
              addFlow={addFlow}
              onRetry={snapshotQuery.refresh}
              onAction={(fleetKey, row, action, alias) =>
                void dispatch(fleetKey, row, action, alias)
              }
              onSignIn={(row) => void signIn(row)}
              onAdd={(fleetKey, target) => void startAdd(fleetKey, target)}
            />
          </WorkspacePageContainer>
        </ScrollArea>
      </div>
    </SidebarInset>
  );
}

function AccountsBody({
  state,
  snapshot,
  nowMs,
  pending,
  failure,
  pendingSignIn,
  signInFailure,
  addFlow,
  onRetry,
  onAction,
  onSignIn,
  onAdd,
}: {
  readonly state: ReturnType<typeof accountsPageState>;
  readonly snapshot: InfinitusSnapshot | null;
  readonly nowMs: number;
  readonly pending: (CommandTarget & { action: AccountAction }) | null;
  readonly failure: (CommandTarget & { message: string }) | null;
  readonly pendingSignIn: string | null;
  readonly signInFailure: { readonly key: string; readonly message: string } | null;
  readonly addFlow: AddAccountFlow | null;
  readonly onRetry: () => void;
  readonly onAction: (
    fleetKey: string,
    row: AccountRowModel,
    action: AccountAction,
    alias?: string,
  ) => void;
  readonly onSignIn: (row: SignInRowModel) => void;
  readonly onAdd: (fleetKey: string, target: AccountRowModel | null) => void;
}) {
  if (state === "unsupported") {
    return (
      <section className="max-w-xl rounded-lg border p-4">
        <p className="text-muted-foreground text-sm">
          This server has no Infinitus adapter for this platform.
        </p>
      </section>
    );
  }
  if (state === "loading" || snapshot === null) return <AccountsSkeleton />;
  if (state === "unavailable") {
    return (
      <AccountsUnavailable
        reason={snapshot.unavailableReason ?? null}
        socketPath={snapshot.status?.socket ?? null}
        onRetry={onRetry}
      />
    );
  }
  // A lapsed sign-in is worth a section even on a host with no fleets; the
  // section is left out entirely when nothing lapsed.
  const signIns = buildSignInRows(snapshot);
  const signInsSection =
    signIns.length === 0 ? null : (
      <SignInsSection
        rows={signIns}
        pendingKey={pendingSignIn}
        failure={signInFailure}
        onSignIn={onSignIn}
      />
    );
  if (state === "empty") {
    return (
      <div className="flex flex-col gap-6">
        <p className="text-muted-foreground text-sm">No engines report accounts on this host.</p>
        {signInsSection}
      </div>
    );
  }

  const forecast = buildForecast(snapshot);
  const offersAdd = snapshotOffersAdd(snapshot);
  const signInRunning = snapshotSignInRunning(snapshot);
  return (
    <div className="flex flex-col gap-6">
      {forecast === null ? null : <ForecastStrip forecast={forecast} />}
      {snapshot.fleets.map((fleet) => {
        const section = buildFleetSection(fleet);
        return (
          <FleetSection
            key={section.key}
            section={section}
            band={exhaustedBand(fleet, nowMs)}
            pending={
              pending?.fleetKey === section.key
                ? { number: pending.number, action: pending.action }
                : null
            }
            failure={
              failure?.fleetKey === section.key
                ? { number: failure.number, message: failure.message }
                : null
            }
            offersAdd={offersAdd}
            addFlow={addFlow?.fleetKey === section.key ? addFlow : null}
            signInRunning={signInRunning}
            onAction={(row, action, alias) => onAction(section.key, row, action, alias)}
            onAdd={(target) => onAdd(section.key, target)}
          />
        );
      })}
      {signInsSection}
    </div>
  );
}

/** Stand-in rows with the loaded page's shape while the first snapshot lands. */
function AccountsSkeleton() {
  return (
    <div className="flex flex-col gap-6">
      {[0, 1].map((section) => (
        <div key={section} className="flex flex-col gap-3">
          <Skeleton className="h-4 w-32" />
          {[0, 1, 2].map((row) => (
            <div key={row} className="flex flex-col gap-2">
              <Skeleton className="h-3.5 w-48" />
              <Skeleton className="h-6 w-full" />
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}
