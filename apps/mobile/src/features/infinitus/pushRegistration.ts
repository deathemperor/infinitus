import type { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusCommandInput } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import Constants from "expo-constants";

import { loadOrCreateAgentAwarenessDeviceId } from "../../persistence/imperative";
import { resolveApnsEnvironment } from "./apnsEnvironment";
import {
  type LiveActivityTokenKind,
  registrationBody,
  registrationCommand,
  type SentToken,
  shouldSendToken,
} from "./liveActivity.logic";
import { noteTokenFailed, noteTokenRegistered } from "./pushDiagnostics";
import { isEnvironmentUnreachable } from "./pushRetry.logic";

/** One token sender per bridge: it throttles repeats with `shouldSendToken`
    and files every kind under the SAME device id and APNs environment, so the
    Mac sees one phone whichever token it looks at (its revival dedup keys on
    the device id). A failed send forgets the token so the next chance re-sends,
    and says why in the console — the bridges run with `reportFailure: false`,
    so nothing else surfaces one (#845). Both outcomes are also recorded for
    the Settings row (#941): a Release build shows the console to nobody.
    Answers whether the token is on file with the Mac — a throttled repeat is,
    a failed send is not — which is what the bridge retries by (#941). */
export function tokenSender(input: {
  readonly environmentId: EnvironmentId;
  readonly run: (input: {
    readonly environmentId: EnvironmentId;
    readonly input: InfinitusCommandInput;
  }) => Promise<
    | { readonly _tag: "Success" }
    | { readonly _tag: "Failure"; readonly cause: Cause.Cause<unknown> }
  >;
  readonly isCancelled: () => boolean;
}) {
  const sent = new Map<LiveActivityTokenKind, SentToken>();
  return async (kind: LiveActivityTokenKind, token: string): Promise<boolean> => {
    const now = Date.now();
    if (!shouldSendToken(sent, kind, token, now)) return true;
    sent.set(kind, { token, at: now });
    try {
      const deviceId = await loadOrCreateAgentAwarenessDeviceId();
      const apnsEnvironment = await resolveApnsEnvironment();
      if (input.isCancelled()) return true;
      const body = registrationBody({
        kind,
        token,
        deviceId,
        deviceName: Constants.deviceName?.trim() || "iPhone",
        environmentId: input.environmentId,
        sandbox: apnsEnvironment === "sandbox",
        now: new Date(now),
      });
      const result = await input.run({
        environmentId: input.environmentId,
        input: registrationCommand(body),
      });
      if (result._tag === "Success") {
        noteTokenRegistered(kind, new Date());
        return true;
      }
      sent.delete(kind);
      warnFailed(kind, input.environmentId, Cause.squash(result.cause));
      return false;
    } catch (error) {
      sent.delete(kind);
      warnFailed(kind, input.environmentId, error);
      return false;
    }
  };
}

/** A send that did not land, told apart at the door: an environment the RPC
    could not reach means the Mac never saw the token, which reads nothing
    like a Mac that answered `ok: false` (#941). */
function warnFailed(kind: LiveActivityTokenKind, environmentId: EnvironmentId, error: unknown) {
  const unreachable = isEnvironmentUnreachable(error);
  const detail = failureDetail(error, unreachable);
  noteTokenFailed(kind, new Date(), unreachable ? "unreachable" : "refused", detail);
  console.warn("[infinitus-push] token registration failed", {
    kind,
    environmentId,
    outcome: unreachable ? "unreachable" : "refused",
    error: detail,
  });
}

/** The failure in its own words. An unreachable environment says which Mac is
    not connected, which is the whole sentence; anything else is named too,
    since its message alone can be as bare as "An error occurred". */
function failureDetail(error: unknown, unreachable: boolean): string {
  if (!(error instanceof Error)) return String(error);
  return unreachable ? error.message : `${error.name}: ${error.message}`;
}
