import type { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusCommandInput } from "@t3tools/contracts/infinitus";
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
    the device id). A failed send forgets the token so the next chance re-sends. */
export function tokenSender(input: {
  readonly environmentId: EnvironmentId;
  readonly run: (input: {
    readonly environmentId: EnvironmentId;
    readonly input: InfinitusCommandInput;
  }) => Promise<{ readonly _tag: string }>;
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
      if (result._tag !== "Success") sent.delete(kind);
    } catch {
      sent.delete(kind);
    }
  };
}
