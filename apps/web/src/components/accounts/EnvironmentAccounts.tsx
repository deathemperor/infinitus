import {
  INFINITUS_COMMAND_TIMEOUT_MESSAGE,
  accountCommandArgs,
  accountsPageState,
  rowFlip,
  addAccountCommandArgs,
  buildFleetSection,
  buildForecast,
  buildSignInRows,
  signInCommandArgs,
  signInDismissCommandArgs,
  signInDismissSupported,
  snapshotOffersAdd,
  snapshotSignInRunning,
  waitAddCommandArgs,
  type AccountAction,
  type AccountRowModel,
  type RowFlip,
  type SignInRowModel,
} from "@infinitus/client-runtime/state/infinitusAccounts";
import { exhaustedBand } from "@infinitus/client-runtime/state/infinitusExhausted";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { Link } from "@tanstack/react-router";
import * as Cause from "effect/Cause";
import * as Redacted from "effect/Redacted";
import { useEffect, useMemo, useRef, useState } from "react";

import { RefreshIcon } from "~/components/ui/refresh-icon";

import { useNowMinute } from "../../hooks/useNowMinute";
import { randomUUID } from "../../lib/utils";
import type { EnvironmentPresentation } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { useAtomCommand } from "../../state/use-atom-command";
import { Button } from "../ui/button";
import { Skeleton } from "../ui/skeleton";
import { AccountsUnavailable } from "./AccountsUnavailable";
import { WAIT_ADD_STEP_SECONDS, waitAddStep, type AddAccountFlow } from "./addAccount.logic";
import { FleetSection, type FleetSignIn } from "./FleetSection";
import { ForecastStrip } from "./ForecastStrip";
import {
  fleetRunsShellOAuth,
  oauthSignInBridge,
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

/** How long a sign-in may hold its row's spinner when no snapshot follows it,
    and how long a flipped flag is drawn on a row the snapshots never confirm
    (a write the app answered without changing anything). */
const COMMAND_SETTLE_TIMEOUT_MS = 10_000;

interface CommandTarget {
  readonly fleetKey: string;
  readonly number: number;
}

/** A command in flight: its row shows a spinner until the socket answers.
    Several rows may be in flight at once (#1481: the Mac queues writes). */
interface PendingCommand extends CommandTarget {
  readonly action: AccountAction;
}

/** A toggle drawn on its row before the engine confirms it. It draws nothing
    once a snapshot agrees, and retires `COMMAND_SETTLE_TIMEOUT_MS` after the
    reply. */
interface PendingFlip extends CommandTarget, RowFlip {}

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
      if (unavailable.cause === "timeout") return INFINITUS_COMMAND_TIMEOUT_MESSAGE;
      if (typeof unavailable.cause === "string") return unavailable.cause;
    }
    if (error instanceof Error && error.message.trim() !== "") return error.message;
  }
  return "The command failed.";
}

/**
 * One machine's accounts: every fleet its engines report, one section per
 * fleet, under a heading that names the machine. The row model does the
 * deriving (`@infinitus/client-runtime/state/infinitusAccounts`); this
 * component owns the machine's snapshot and the flows in flight against it,
 * and forwards each button to that machine's control socket. The page draws
 * one of these per connected environment that runs Infinitus.
 */
export function EnvironmentAccounts({
  environment,
  primary,
}: {
  readonly environment: EnvironmentPresentation;
  /** This client's own machine: the only one whose sign-in the shell can run. */
  readonly primary: boolean;
}) {
  const environmentId = environment.environmentId;
  const [pending, setPending] = useState<ReadonlyArray<PendingCommand>>([]);
  const [flips, setFlips] = useState<ReadonlyArray<PendingFlip>>([]);
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
  const oauthBridge = useMemo(
    () => oauthSignInBridge(typeof window === "undefined" ? undefined : window.desktopBridge),
    [],
  );
  // Each add/re-login gets a run number; a newer run or an unmount retires
  // the polling loop of the one before it.
  const addRunRef = useRef(0);
  /** The shell's own sign-in outlives this page: the engine's child process
      keeps listening until something ends it, and once the page is gone
      nothing here can (#1213). Leaving it retires the flow. */
  const shellFlowIdRef = useRef<string | null>(null);
  useEffect(
    () => () => {
      addRunRef.current += 1;
      signInRunRef.current += 1;
      const flowId = shellFlowIdRef.current;
      if (flowId === null) return;
      shellFlowIdRef.current = null;
      void oauthBridge?.cancel(flowId).catch(() => {});
    },
    [oauthBridge],
  );

  // No subscription against a machine the client cannot reach; its group
  // says so instead of holding a skeleton that would never fill in.
  const connected = environment.connection.phase === "connected";
  const snapshotQuery = useEnvironmentQuery(
    connected ? infinitusEnvironment.snapshot({ environmentId, input: {} }) : null,
  );
  const snapshot = snapshotQuery.data;
  // The page lists only machines whose server answered with the adapter.
  const state = accountsPageState({ capability: true, snapshot });
  // The exhausted band's "reset has passed" reads against the shared minute clock.
  const minute = useNowMinute();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  // The fork's one secret-carrying call (#747): the sign-in code, on a client
  // without the shell. The value lives in the form field until submitted.
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });

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
    const { command, args, options } = accountCommandArgs(fleetKey, row, action, alias);
    const target = { fleetKey, number: row.number };
    const sameRow = (entry: CommandTarget) =>
      entry.fleetKey === target.fleetKey && entry.number === target.number;
    const command_ = { ...target, action };
    const flip = rowFlip(row, action);
    const pendingFlip = flip === null ? null : { ...target, ...flip };
    setPending((prev) => [...prev, command_]);
    if (pendingFlip !== null) {
      setFlips((prev) => [...prev.filter((entry) => !sameRow(entry)), pendingFlip]);
    }
    const result = await runCommand({
      environmentId,
      input: { command, args, options: options ?? {} },
    });
    setPending((prev) => prev.filter((entry) => entry !== command_));
    if (result._tag === "Success") {
      setFailure(null);
      if (pendingFlip !== null) {
        setTimeout(
          () => setFlips((prev) => prev.filter((entry) => entry !== pendingFlip)),
          COMMAND_SETTLE_TIMEOUT_MS,
        );
      }
      return;
    }
    if (pendingFlip !== null) setFlips((prev) => prev.filter((entry) => entry !== pendingFlip));
    setFailure({ ...target, message: commandErrorMessage(result.cause) });
  };

  const signIn = async (row: SignInRowModel) => {
    setPendingSignIn({ key: row.key, snapshot });
    const result = await runCommand({ environmentId, input: signInCommandArgs(row) });
    if (result._tag === "Success") {
      setSignInFailure(null);
      return;
    }
    setPendingSignIn(null);
    setSignInFailure({ key: row.key, message: commandErrorMessage(result.cause) });
  };

  const dismissSignIn = async (row: SignInRowModel) => {
    const result = await runCommand({
      environmentId,
      input: signInDismissCommandArgs(row.tool, row.profile),
    });
    if (result._tag === "Success") return;
    setSignInFailure({ key: row.key, message: commandErrorMessage(result.cause) });
  };

  // `add <fleet>` puts the app's own sign-in on the Mac's screen; the page then
  // polls `wait-add` in short steps until the app says the flow ended. The new
  // account arrives through the snapshot: the server re-reads the fleets after
  // every forwarded command.
  const startAdd = async (fleetKey: string, target: AccountRowModel | null) => {
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
  const shellSignIn = bridge !== null && primary ? bridge : null;

  // The sign-in this shell runs itself (#1213): the engine's own `add-oauth`,
  // spawned here, its loopback listener catching the redirect. It needs the
  // engine binary on this machine, so it exists only where the shell path
  // does — the desktop client looking at this Mac's own environment.
  const shellOAuthSignIn = oauthBridge !== null && primary ? oauthBridge : null;

  const startSignIn = async (fleetKey: string, target: AccountRowModel | null) => {
    const run = ++signInRunRef.current;
    const live = () => signInRunRef.current === run;
    const base: SignInFlow = {
      kind: "app",
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

  // The shell's own sign-in (#1213): one call for the whole flow. The shell
  // opens the provider's page as soon as the engine prints its URL, so the
  // flow waits for the provider from the moment it starts — there is no
  // status to poll and no code to paste, and the page runs in the system
  // browser, so only Cancel here or the engine's timeout ends it.
  const startShellOAuthSignIn = async (
    fleetKey: string,
    provider: string,
    target: AccountRowModel | null,
  ) => {
    if (shellOAuthSignIn === null) return;
    const run = ++signInRunRef.current;
    const live = () => signInRunRef.current === run;
    const targetLabel = target?.label ?? null;
    const flowId = randomUUID();
    const base: SignInFlow = {
      kind: "shell",
      fleetKey,
      target: targetLabel,
      flowId,
      url: null,
      pasteCode: false,
      phase: "waitingForToken",
      error: null,
      account: null,
      codeError: null,
      codeBusy: false,
    };
    setSignInFlow(base);
    shellFlowIdRef.current = flowId;
    const result = await shellOAuthSignIn
      .begin({
        flowId,
        provider,
        fleet: fleetKey,
        ...(target?.email === undefined ? {} : { relogin: target.email }),
      })
      .catch((cause: unknown) => ({
        ok: false as const,
        error: cause instanceof Error ? cause.message : String(cause),
      }));
    if (shellFlowIdRef.current === flowId) shellFlowIdRef.current = null;
    if (!live()) return;
    if (result.ok) {
      setSignInFlow({ ...base, phase: "done", account: result.email ?? null });
      await runCommand({ environmentId, input: { command: "refresh", args: [], options: {} } });
      return;
    }
    // A run the shell cancelled says nothing; the page drops the flow rather
    // than showing a failure the user caused.
    if (result.error === undefined) {
      setSignInFlow(null);
      return;
    }
    setSignInFlow({ ...base, phase: "failed", error: result.error });
  };

  const cancelSignIn = async () => {
    if (signInFlow === null) return;
    signInRunRef.current += 1;
    if (signInFlow.kind === "shell") {
      if (signInFlow.flowId !== null) {
        if (shellFlowIdRef.current === signInFlow.flowId) shellFlowIdRef.current = null;
        await shellOAuthSignIn?.cancel(signInFlow.flowId).catch(() => {});
      }
      setSignInFlow(null);
      return;
    }
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
    if (isRefreshing) return;
    setIsRefreshing(true);
    await runCommand({ environmentId, input: { command: "refresh", args: [], options: {} } });
    setIsRefreshing(false);
  };

  return (
    <section className="flex flex-col gap-4" aria-label={`Accounts on ${environment.label}`}>
      <div className="flex items-center gap-2">
        <h2 className="min-w-0 truncate font-semibold text-base text-foreground">
          {environment.label}
        </h2>
        <Button
          className="ms-auto"
          onClick={() => void refresh()}
          aria-label={`Refresh accounts: ${environment.label}`}
          aria-busy={isRefreshing}
          disabled={isRefreshing || !connected}
          size="icon-sm"
          variant="ghost"
        >
          <RefreshIcon className="size-3.5" refreshing={isRefreshing} />
        </Button>
      </div>
      {connected ? (
        <AccountsBody
          environment={environment}
          state={state}
          snapshot={snapshot}
          nowMs={Date.parse(minute)}
          pending={pending}
          flips={flips}
          failure={failure}
          pendingSignIn={signInInFlight}
          signInFailure={signInFailure}
          addFlow={addFlow}
          signIn={{
            offers: false,
            inApp: true,
            shellOAuth: shellOAuthSignIn !== null,
            flow: signInFlow,
            onCancel: () => void cancelSignIn(),
            onSubmitCode: (code) => void submitSignInCode(code),
          }}
          onStartSignIn={(fleetKey, target) => void startSignIn(fleetKey, target)}
          onStartShellOAuthSignIn={(fleetKey, provider, target) =>
            void startShellOAuthSignIn(fleetKey, provider, target)
          }
          onRetry={snapshotQuery.refresh}
          onAction={(fleetKey, row, action, alias) => void dispatch(fleetKey, row, action, alias)}
          onSignIn={(row) => void signIn(row)}
          onDismissSignIn={(row) => void dismissSignIn(row)}
          onAdd={(fleetKey, target) => void startAdd(fleetKey, target)}
        />
      ) : (
        <p className="text-muted-foreground text-sm">Not connected.</p>
      )}
    </section>
  );
}

function AccountsBody({
  environment,
  state,
  snapshot,
  nowMs,
  pending,
  flips,
  failure,
  pendingSignIn,
  signInFailure,
  addFlow,
  signIn,
  onStartSignIn,
  onStartShellOAuthSignIn,
  onRetry,
  onAction,
  onSignIn,
  onDismissSignIn,
  onAdd,
}: {
  readonly environment: EnvironmentPresentation;
  readonly state: ReturnType<typeof accountsPageState>;
  readonly snapshot: InfinitusSnapshot | null;
  readonly nowMs: number;
  readonly pending: ReadonlyArray<PendingCommand>;
  readonly flips: ReadonlyArray<PendingFlip>;
  readonly failure: (CommandTarget & { message: string }) | null;
  readonly pendingSignIn: string | null;
  readonly signInFailure: { readonly key: string; readonly message: string } | null;
  readonly addFlow: AddAccountFlow | null;
  /** The in-app sign-in, before the page's fleet and `offers` are known. */
  readonly signIn: Omit<FleetSignIn, "onStart">;
  readonly onStartSignIn: (fleetKey: string, target: AccountRowModel | null) => void;
  /** The shell's own sign-in (#1213); the fleet's provider names the flow. */
  readonly onStartShellOAuthSignIn: (
    fleetKey: string,
    provider: string,
    target: AccountRowModel | null,
  ) => void;
  readonly onRetry: () => void;
  readonly onAction: (
    fleetKey: string,
    row: AccountRowModel,
    action: AccountAction,
    alias?: string,
  ) => void;
  readonly onSignIn: (row: SignInRowModel) => void;
  readonly onDismissSignIn: (row: SignInRowModel) => void;
  readonly onAdd: (fleetKey: string, target: AccountRowModel | null) => void;
}) {
  if (state === "loading" || state === "unsupported" || snapshot === null) {
    return <AccountsSkeleton />;
  }
  if (state === "unavailable") {
    return (
      <AccountsUnavailable
        environment={environment}
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
        onDismiss={signInDismissSupported(snapshot) ? onDismissSignIn : null}
      />
    );
  if (state === "empty") {
    return (
      <div className="flex flex-col gap-6">
        <p className="text-muted-foreground text-sm">
          Infinitus is running, but no engine reports accounts — install and configure an engine
          (swapd) for Infinitus to manage them.
        </p>
        <div className="flex flex-wrap items-center gap-4">
          <Link
            to="/settings/engines"
            search={{ environmentId: environment.environmentId }}
            className="w-fit text-sm text-foreground underline underline-offset-2"
          >
            Open Settings › Engines
          </Link>
          <a
            href="https://github.com/deathemperor/infinitus/blob/main/docs/user/accounts.md"
            target="_blank"
            rel="noreferrer"
            className="text-sm text-foreground underline underline-offset-2"
          >
            Read the accounts setup guide
          </a>
        </div>
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
        // Only the engine whose sign-in is a loopback OAuth flow takes the
        // shell path; the others keep the app's.
        const shellOAuth = signIn.shellOAuth && fleetRunsShellOAuth(section.engineID);
        return (
          <FleetSection
            key={section.key}
            section={section}
            band={exhaustedBand(fleet, nowMs)}
            pending={pending.filter((entry) => entry.fleetKey === section.key)}
            flips={flips.filter((entry) => entry.fleetKey === section.key)}
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
              shellOAuth,
              flow: signIn.flow?.fleetKey === section.key ? signIn.flow : null,
              onStart: (target) =>
                shellOAuth
                  ? onStartShellOAuthSignIn(section.key, section.provider, target)
                  : onStartSignIn(section.key, target),
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
export function AccountsSkeleton() {
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
