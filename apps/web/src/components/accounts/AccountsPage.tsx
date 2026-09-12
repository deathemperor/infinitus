import { Link } from "@tanstack/react-router";
import { useAtomValue } from "@effect/atom-react";
import {
  accountCommandArgs,
  accountsPageState,
  addAccountCommandArgs,
  buildFleetSection,
  buildForecast,
  buildSignInRows,
  infinitusCapabilityAcross,
  infinitusCapabilityOf,
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
import * as Redacted from "effect/Redacted";
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
import { FleetSection, type FleetSignIn } from "./FleetSection";
import { ForecastStrip } from "./ForecastStrip";
import {
  SIGN_IN_POLL_MS,
  signInBeginCommandArgs,
  signInBeginReply,
  signInBridge,
  signInCancelCommandArgs,
  signInEnded,
  signInStatusCommandArgs,
  signInStatusReply,
  signInCodeReply,
  signInCodeSecretArgs,
  snapshotOffersSignIn,
  type SignInFlow,
} from "./signIn.logic";
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
  const [signInFlow, setSignInFlow] = useState<SignInFlow | null>(null);
  /** Bumped on every start and on unmount: a poll from an earlier flow stops. */
  const signInRunRef = useRef(0);
  // The bridge is a window global fixed for the page's life.
  const bridge = useMemo(
    () => signInBridge(typeof window === "undefined" ? undefined : window.desktopBridge),
    [],
  );
  // Each add/re-login gets a run number; a newer run or an unmount retires
  // the polling loop of the one before it.
  const addRunRef = useRef(0);
  useEffect(
    () => () => {
      addRunRef.current += 1;
      signInRunRef.current += 1;
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
  // Across every environment, not the chosen one: a server that answered
  // `false` is unsupported even though it never becomes `environmentId`.
  const capability = infinitusCapabilityAcross(
    environments.map((environment) =>
      infinitusCapabilityOf(serverConfigs.get(environment.environmentId)?.environment.capabilities),
    ),
  );

  const snapshotQuery = useEnvironmentQuery(
    environmentId === null ? null : infinitusEnvironment.snapshot({ environmentId, input: {} }),
  );
  const snapshot = snapshotQuery.data;
  const state = accountsPageState({ capability, snapshot });
  // The exhausted band's "reset has passed" reads against the shared minute clock.
  const minute = useNowMinute();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  // The fork's one secret-carrying call (#747): the sign-in code, on a client
  // without the shell. The value lives in the form field until submitted.
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });

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

  // The in-app sign-in (#677): `signin-begin` on the app, the provider's page
  // in the shell's child window, `signin-status` every two seconds until the
  // app says it ended. Only this Mac's own app can show the window, so the
  // shell path exists for the primary environment in the desktop client;
  // every other client opens the page from a link and hands the code over
  // `infinitus.secret` (#747).
  const shellSignIn =
    bridge !== null && environmentId !== null && environmentId === primaryEnvironmentId
      ? bridge
      : null;
  const inAppSignIn = environmentId !== null;

  const startSignIn = async (fleetKey: string, target: AccountRowModel | null) => {
    if (environmentId === null) return;
    const run = ++signInRunRef.current;
    const live = () => signInRunRef.current === run;
    const base: SignInFlow = {
      fleetKey,
      target: target?.label ?? null,
      flowId: null,
      url: null,
      pasteCode: false,
      phase: "starting",
      error: null,
      account: null,
      codeError: null,
      codeBusy: false,
    };
    setSignInFlow(base);
    const begun = await runCommand({
      environmentId,
      input: signInBeginCommandArgs(fleetKey, target?.email ?? null),
    });
    if (!live()) return;
    const reply = begun._tag === "Success" ? signInBeginReply(begun.value.result) : null;
    if (reply === null) {
      setSignInFlow({
        ...base,
        phase: "failed",
        error:
          begun._tag === "Failure"
            ? commandErrorMessage(begun.cause)
            : "Infinitus answered unexpectedly.",
      });
      return;
    }
    const begunFlow: SignInFlow = {
      ...base,
      flowId: reply.flowId,
      url: shellSignIn === null ? reply.url : null,
      pasteCode: reply.pasteCode,
    };
    setSignInFlow(begunFlow);
    await shellSignIn
      ?.open({ flowId: reply.flowId, url: reply.url, label: reply.label })
      .catch(() => {});
    while (live()) {
      await new Promise((resolve) => setTimeout(resolve, SIGN_IN_POLL_MS));
      if (!live()) return;
      const answer = await runCommand({
        environmentId,
        input: signInStatusCommandArgs(reply.flowId),
      });
      if (!live()) return;
      const status = answer._tag === "Success" ? signInStatusReply(answer.value.result) : null;
      // Every status answer is the whole of where the flow stands, so each
      // step starts from the begun flow, never from the previous step.
      const flow: SignInFlow =
        status === null
          ? {
              ...begunFlow,
              phase: "failed",
              error:
                answer._tag === "Failure"
                  ? commandErrorMessage(answer.cause)
                  : "Infinitus answered unexpectedly.",
            }
          : { ...begunFlow, phase: status.phase, error: status.error, account: status.account };
      setSignInFlow((current) =>
        current === null
          ? current
          : { ...flow, codeError: current.codeError, codeBusy: current.codeBusy },
      );
      if (signInEnded(flow.phase)) {
        await shellSignIn?.close(reply.flowId).catch(() => {});
        if (flow.phase === "done") {
          await runCommand({ environmentId, input: { command: "refresh", args: [], options: {} } });
        }
        return;
      }
    }
  };

  const cancelSignIn = async () => {
    if (environmentId === null || signInFlow === null) return;
    signInRunRef.current += 1;
    if (signInFlow.flowId !== null) {
      await shellSignIn?.close(signInFlow.flowId).catch(() => {});
      await runCommand({ environmentId, input: signInCancelCommandArgs(signInFlow.flowId) });
    }
    setSignInFlow(null);
  };

  /** The code over `infinitus.secret` (#747): the value goes on the secret
      channel and is dropped here; the reply carries the CLI's wording only. */
  const submitCodeOverRpc = async (
    flowId: string,
    code: string,
  ): Promise<{ readonly ok: boolean; readonly error?: string }> => {
    if (environmentId === null) return { ok: false, error: "No environment." };
    const answer = await runSecret({
      environmentId,
      input: { ...signInCodeSecretArgs(flowId), secret: Redacted.make(code) },
    });
    if (answer._tag === "Failure") return { ok: false, error: commandErrorMessage(answer.cause) };
    return (
      signInCodeReply(answer.value.result) ?? {
        ok: false,
        error: "Infinitus answered unexpectedly.",
      }
    );
  };

  const submitSignInCode = async (code: string) => {
    if (signInFlow === null || signInFlow.flowId === null) return;
    const flowId = signInFlow.flowId;
    setSignInFlow((current) =>
      current === null ? current : { ...current, codeBusy: true, codeError: null },
    );
    const result = await (
      shellSignIn === null
        ? submitCodeOverRpc(flowId, code)
        : shellSignIn.submitCode({ flowId, code })
    ).catch((cause: unknown) => ({
      ok: false,
      error: cause instanceof Error ? cause.message : String(cause),
    }));
    setSignInFlow((current) =>
      current === null || current.flowId !== flowId
        ? current
        : {
            ...current,
            codeBusy: false,
            codeError: result.ok ? null : (result.error ?? "The code was not accepted."),
          },
    );
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
              environmentId={environmentId}
              state={state}
              snapshot={snapshot}
              nowMs={Date.parse(minute)}
              pending={inFlight}
              failure={failure}
              pendingSignIn={signInInFlight}
              signInFailure={signInFailure}
              addFlow={addFlow}
              signIn={{
                offers: false,
                inApp: inAppSignIn,
                flow: signInFlow,
                onCancel: () => void cancelSignIn(),
                onSubmitCode: (code) => void submitSignInCode(code),
              }}
              onStartSignIn={(fleetKey, target) => void startSignIn(fleetKey, target)}
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
  environmentId,
  state,
  snapshot,
  nowMs,
  pending,
  failure,
  pendingSignIn,
  signInFailure,
  addFlow,
  signIn,
  onStartSignIn,
  onRetry,
  onAction,
  onSignIn,
  onAdd,
}: {
  readonly environmentId: EnvironmentId | null;
  readonly state: ReturnType<typeof accountsPageState>;
  readonly snapshot: InfinitusSnapshot | null;
  readonly nowMs: number;
  readonly pending: (CommandTarget & { action: AccountAction }) | null;
  readonly failure: (CommandTarget & { message: string }) | null;
  readonly pendingSignIn: string | null;
  readonly signInFailure: { readonly key: string; readonly message: string } | null;
  readonly addFlow: AddAccountFlow | null;
  /** The in-app sign-in, before the page's fleet and `offers` are known. */
  readonly signIn: Omit<FleetSignIn, "onStart">;
  readonly onStartSignIn: (fleetKey: string, target: AccountRowModel | null) => void;
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
        <section className="max-w-xl space-y-3 rounded-lg border p-4">
          <h2 className="text-sm font-medium">Set up your first account fleet</h2>
          <p className="text-sm text-muted-foreground">
            An engine manages your provider logins as a fleet of accounts. This host is connected,
            but no engine is reporting a fleet yet.
          </p>
          <p className="text-sm text-muted-foreground">
            Enable an engine in Settings › Infinitus › Engines, then add an account on that host.
          </p>
          <div className="flex flex-wrap items-center gap-3">
            <Button
              render={
                <Link
                  to="/settings/infinitus/engines"
                  search={environmentId ? { environmentId } : {}}
                />
              }
              size="sm"
            >
              Set up engines
            </Button>
            <a
              href="https://github.com/deathemperor/infinitus/blob/main/docs/user/accounts.md"
              target="_blank"
              rel="noreferrer"
              className="text-sm underline underline-offset-4"
            >
              Read the accounts setup guide
            </a>
          </div>
        </section>
        {signInsSection}
      </div>
    );
  }

  const forecast = buildForecast(snapshot);
  const offersAdd = snapshotOffersAdd(snapshot);
  const offersSignIn = snapshotOffersSignIn(snapshot);
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
            signIn={{
              ...signIn,
              offers: offersSignIn,
              flow: signIn.flow?.fleetKey === section.key ? signIn.flow : null,
              onStart: (target) => onStartSignIn(section.key, target),
            }}
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
