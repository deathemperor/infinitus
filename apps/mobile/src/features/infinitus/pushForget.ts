import type { EnvironmentId } from "@t3tools/contracts";
import { useEffect, useRef } from "react";

import { loadOrCreateAgentAwarenessDeviceId } from "../../persistence/imperative";
import type { LiveActivityTokenKind } from "./liveActivity.logic";
import { type ForgetRun, forgetTokens, macToForget, type SwitchState } from "./pushForget.logic";

/**
 * Fires `forgetTokens` at the Mac that was driving the phone the moment a
 * switch goes from on to off (#702), as `macToForget` decides. `enabled` is
 * null until the preferences have loaded, so the initial off never counts.
 */
export function useForgetOnSwitchOff(input: {
  readonly enabled: boolean | null;
  readonly environmentId: EnvironmentId | null;
  readonly kinds: ReadonlyArray<LiveActivityTokenKind>;
  readonly run: ForgetRun;
}): void {
  const { enabled, environmentId, kinds, run } = input;
  const previous = useRef<SwitchState | null>(null);
  useEffect(() => {
    const now: SwitchState | null = enabled === null ? null : { enabled, environmentId };
    const target = macToForget(previous.current, now);
    if (now !== null) previous.current = now;
    if (target === null) return;
    void forgetTokens({
      environmentId: target,
      kinds,
      run,
      loadDeviceId: loadOrCreateAgentAwarenessDeviceId,
    });
  }, [enabled, environmentId, kinds, run]);
}
