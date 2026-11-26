import type { AccountRowModel } from "@infinitus/client-runtime/state/infinitusAccounts";
import {
  SIGN_IN_POLL_MS,
  type SignInFlow,
  signInBeginCommandArgs,
  signInBeginReply,
  signInCancelCommandArgs,
  signInCodeReply,
  signInCodeSecretArgs,
  signInEnded,
  signInStatusCommandArgs,
  signInStatusReply,
} from "@infinitus/client-runtime/state/infinitusSignIn";
import type { EnvironmentId } from "@infinitus/contracts";
import * as Redacted from "effect/Redacted";
import * as WebBrowser from "expo-web-browser";
import { useCallback, useEffect, useRef, useState } from "react";
import { Linking } from "react-native";

import { infinitusEnvironment } from "../../state/infinitus";
import { useAtomCommand } from "../../state/use-atom-command";
import {
  awaitLoopbackRedirect,
  listenForLoopbackRedirect,
  loopbackCatchSupported,
  stopLoopbackCatch,
} from "../infinitus/loopbackCatch";
import { commandFailureMessage, signInPollFailureEnds } from "./accountsRoute.logic";

const UNEXPECTED = "Infinitus answered unexpectedly.";

/** One Mac's account sign-in from this phone, the web page's `signin-begin` flow (#677, #747).
    A loopback redirect is caught here where `loopbackCatch.ts` can, and sent as `signin-code`;
    anywhere else the page opens in the browser and the user pastes the code or the address it
    ended on. One flow per Mac, as the Mac runs one at a time. */
export function useFleetSignIn(environmentId: EnvironmentId) {
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });
  const [flow, setFlow] = useState<SignInFlow | null>(null);
  /** Bumped on every start, cancel and unmount: an older flow's poll and catch stop. */
  const runRef = useRef(0);
  /** The flow the Mac is still running, for the unmount below to cancel. */
  const liveFlowIdRef = useRef<string | null>(null);

  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- on unmount, frees the phone's loopback port and cancels the Mac's flow, which would otherwise block the next sign-in until it times out
  useEffect(
    () => () => {
      runRef.current += 1;
      void stopLoopbackCatch();
      const flowId = liveFlowIdRef.current;
      liveFlowIdRef.current = null;
      if (flowId !== null) {
        void run({ environmentId, input: signInCancelCommandArgs(flowId) });
      }
    },
    [environmentId, run],
  );

  const update = useCallback(
    (flowId: string, change: (current: SignInFlow) => SignInFlow) =>
      setFlow((current) =>
        current === null || current.flowId !== flowId ? current : change(current),
      ),
    [],
  );

  /** The code or address over `infinitus.secret`; the reply carries the CLI's wording only. */
  const sendCode = useCallback(
    async (flowId: string, code: string): Promise<{ ok: boolean; error?: string }> => {
      const answer = await runSecret({
        environmentId,
        input: { ...signInCodeSecretArgs(flowId), secret: Redacted.make(code) },
      });
      if (answer._tag !== "Success")
        return { ok: false, error: commandFailureMessage(answer.cause) };
      return signInCodeReply(answer.value.result) ?? { ok: false, error: UNEXPECTED };
    },
    [environmentId, runSecret],
  );

  /** Opens the provider's page. With a loopback port and the catcher, in the system auth
      session with this phone listening on that port; closing the sheet leaves the flow
      waiting, to open again or cancel. A held port falls back to the browser and the field. */
  const openPage = useCallback(
    async (opened: SignInFlow) => {
      const { flowId, url, redirectPort } = opened;
      if (flowId === null || url === null) return;
      const runAtOpen = runRef.current;
      const live = () => runRef.current === runAtOpen;
      if (redirectPort === null || !loopbackCatchSupported) {
        void Linking.openURL(url);
        return;
      }
      const refused = await listenForLoopbackRedirect(redirectPort).then(
        () => null,
        (cause: unknown) =>
          cause instanceof Error ? cause.message : `Port ${redirectPort} is taken.`,
      );
      if (refused !== null) {
        if (!live()) return;
        update(flowId, (current) => ({ ...current, redirectListening: false, codeError: refused }));
        void Linking.openURL(url);
        return;
      }
      const redirect = awaitLoopbackRedirect();
      // The redirect goes to localhost, which the session never treats as its end; the catch
      // closes it.
      void WebBrowser.openAuthSessionAsync(url, null).finally(() => void stopLoopbackCatch());
      const caught = await redirect;
      WebBrowser.dismissAuthSession();
      if (caught === null || !live()) return;
      update(flowId, (current) => ({ ...current, codeBusy: true, codeError: null }));
      const result = await sendCode(flowId, caught);
      if (!live()) return;
      update(flowId, (current) => ({
        ...current,
        codeBusy: false,
        codeError: result.ok ? null : (result.error ?? "The address was not accepted."),
      }));
    },
    [sendCode, update],
  );

  const start = useCallback(
    async (fleetKey: string, target: AccountRowModel | null) => {
      const runAtStart = ++runRef.current;
      const live = () => runRef.current === runAtStart;
      const base: SignInFlow = {
        kind: "app",
        fleetKey,
        target: target?.label ?? null,
        flowId: null,
        url: null,
        pasteCode: false,
        redirectPort: null,
        redirectListening: false,
        phase: "starting",
        error: null,
        account: null,
        codeError: null,
        codeBusy: false,
      };
      setFlow(base);
      const begun = await run({
        environmentId,
        input: signInBeginCommandArgs(fleetKey, target?.email ?? null),
      });
      if (!live()) return;
      const reply = begun._tag === "Success" ? signInBeginReply(begun.value.result) : null;
      if (reply === null) {
        setFlow({
          ...base,
          phase: "failed",
          error: begun._tag === "Success" ? UNEXPECTED : commandFailureMessage(begun.cause),
        });
        return;
      }
      liveFlowIdRef.current = reply.flowId;
      const redirectPort = reply.redirectPort ?? null;
      const begunFlow: SignInFlow = {
        ...base,
        flowId: reply.flowId,
        url: reply.url,
        pasteCode: reply.pasteCode,
        redirectPort,
        redirectListening: redirectPort !== null && loopbackCatchSupported,
      };
      setFlow(begunFlow);
      void openPage(begunFlow);
      while (live()) {
        await new Promise((resolve) => setTimeout(resolve, SIGN_IN_POLL_MS));
        if (!live()) return;
        const answer = await run({ environmentId, input: signInStatusCommandArgs(reply.flowId) });
        if (!live()) return;
        if (answer._tag !== "Success" && !signInPollFailureEnds(answer.cause)) continue;
        const status = answer._tag === "Success" ? signInStatusReply(answer.value.result) : null;
        // Every status answer is the whole of where the flow stands; this device's own fields
        // (the catch, the field's state) carry over.
        const next: SignInFlow =
          status === null
            ? {
                ...begunFlow,
                phase: "failed",
                error: answer._tag === "Success" ? UNEXPECTED : commandFailureMessage(answer.cause),
              }
            : {
                ...begunFlow,
                phase: status.phase,
                error: status.error,
                account: status.account,
                redirectPort: status.redirectPort ?? begunFlow.redirectPort,
              };
        setFlow((current) =>
          current === null
            ? current
            : {
                ...next,
                redirectListening: current.redirectListening,
                codeError: current.codeError,
                codeBusy: current.codeBusy,
              },
        );
        if (signInEnded(next.phase)) {
          liveFlowIdRef.current = null;
          void stopLoopbackCatch();
          WebBrowser.dismissAuthSession();
          if (next.phase === "done") {
            await run({ environmentId, input: { command: "refresh", args: [], options: {} } });
          }
          return;
        }
      }
    },
    [environmentId, openPage, run],
  );

  const cancel = useCallback(async () => {
    const current = flow;
    runRef.current += 1;
    setFlow(null);
    void stopLoopbackCatch();
    WebBrowser.dismissAuthSession();
    if (current?.flowId == null) return;
    if (liveFlowIdRef.current === current.flowId) liveFlowIdRef.current = null;
    await run({ environmentId, input: signInCancelCommandArgs(current.flowId) });
  }, [environmentId, flow, run]);

  /** The pasted code or address: masked in its field, dropped once sent. */
  const submit = useCallback(
    async (text: string) => {
      const flowId = flow?.flowId ?? null;
      const value = text.trim();
      if (flowId === null || value === "") return;
      update(flowId, (current) => ({ ...current, codeBusy: true, codeError: null }));
      const result = await sendCode(flowId, value);
      update(flowId, (current) => ({
        ...current,
        codeBusy: false,
        codeError: result.ok ? null : (result.error ?? "The code was not accepted."),
      }));
    },
    [flow, sendCode, update],
  );

  const reopen = useCallback(() => {
    if (flow !== null) void openPage(flow);
  }, [flow, openPage]);

  return { flow, start, cancel, submit, reopen };
}
