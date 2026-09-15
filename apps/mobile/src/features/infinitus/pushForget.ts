import type { EnvironmentId } from "@t3tools/contracts";
import { useEffect, useRef } from "react";
import { AppState } from "react-native";

import { loadOrCreateAgentAwarenessDeviceId } from "../../persistence/imperative";
import type { LiveActivityTokenKind } from "./liveActivity.logic";
import {
  type ForgetOutcome,
  type ForgetRun,
  forgetTokensOutcome,
  macToForget,
  type SwitchState,
} from "./pushForget.logic";

interface ForgetTarget {
  readonly environmentId: EnvironmentId;
  readonly kinds: ReadonlyArray<LiveActivityTokenKind>;
}

/**
 * Withdraws the phone's registrations from the Mac that was driving it the
 * moment a switch goes from on to off (#702), as `macToForget` decides.
 * `enabled` is null until the preferences have loaded, so the initial off
 * never counts. A withdrawal the Mac never saw (the environment unreachable)
 * is sent again on the next foreground, and dropped if the switch comes back
 * on first — the bridge then registers afresh, and a late forget would wipe
 * that (#1265). Each outcome reaches `onOutcome`, for the Settings row.
 */
export function useForgetOnSwitchOff(input: {
  readonly enabled: boolean | null;
  readonly environmentId: EnvironmentId | null;
  readonly kinds: ReadonlyArray<LiveActivityTokenKind>;
  readonly run: ForgetRun;
  readonly onOutcome?: (outcome: ForgetOutcome, at: Date) => void;
}): void {
  const { enabled, environmentId, kinds, run, onOutcome } = input;
  const previous = useRef<SwitchState | null>(null);
  const pending = useRef<ForgetTarget | null>(null);
  const onOutcomeRef = useRef(onOutcome);
  onOutcomeRef.current = onOutcome;
  const runRef = useRef(run);
  runRef.current = run;

  const attempt = useRef(async (target: ForgetTarget) => {
    pending.current = null;
    const outcome = await forgetTokensOutcome({
      ...target,
      run: runRef.current,
      loadDeviceId: loadOrCreateAgentAwarenessDeviceId,
    });
    if (outcome.outcome === "unreachable") pending.current = target;
    onOutcomeRef.current?.(outcome, new Date());
  });

  useEffect(() => {
    const now: SwitchState | null = enabled === null ? null : { enabled, environmentId };
    const target = macToForget(previous.current, now);
    if (now !== null) previous.current = now;
    if (now?.enabled) pending.current = null;
    if (target === null) return;
    void attempt.current({ environmentId: target, kinds });
  }, [enabled, environmentId, kinds, run]);

  useEffect(() => {
    const subscription = AppState.addEventListener("change", (state) => {
      if (state !== "active" || pending.current === null) return;
      void attempt.current(pending.current);
    });
    return () => subscription.remove();
  }, []);
}
