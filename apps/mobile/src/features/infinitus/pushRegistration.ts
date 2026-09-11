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

/** One token sender per bridge: it throttles repeats with `shouldSendToken`
    and files every kind under the SAME device id and APNs environment, so the
    Mac sees one phone whichever token it looks at (its revival dedup keys on
    the device id). A failed send forgets the token so the next chance re-sends,
    and says why in the console — the bridges run with `reportFailure: false`,
    so this is the only trace of a Mac refusing the verb (#845). */
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
  return async (kind: LiveActivityTokenKind, token: string) => {
    const now = Date.now();
    if (!shouldSendToken(sent, kind, token, now)) return;
    sent.set(kind, { token, at: now });
    try {
      const deviceId = await loadOrCreateAgentAwarenessDeviceId();
      const apnsEnvironment = await resolveApnsEnvironment();
      if (input.isCancelled()) return;
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
      if (result._tag !== "Success") {
        sent.delete(kind);
        warnRefused(kind, input.environmentId, Cause.squash(result.cause));
      }
    } catch (error) {
      sent.delete(kind);
      warnRefused(kind, input.environmentId, error);
    }
  };
}

function warnRefused(kind: LiveActivityTokenKind, environmentId: EnvironmentId, error: unknown) {
  console.warn("[infinitus-push] token registration failed", {
    kind,
    environmentId,
    error: error instanceof Error ? `${error.name}: ${error.message}` : String(error),
  });
}
