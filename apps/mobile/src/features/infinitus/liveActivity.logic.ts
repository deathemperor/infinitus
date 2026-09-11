import type { EnvironmentId } from "@t3tools/contracts";
import {
  InfinitusActivityPushRegistration,
  type InfinitusCommandInput,
} from "@t3tools/contracts/infinitus";
import * as Schema from "effect/Schema";

import type { InfinitusMac } from "../accounts/accountsRoute.logic";

/** The token kinds this app registers: the four Live Activity ones and the
    plain notification token (`alert`, #702), all through the same verb. */
export type LiveActivityTokenKind =
  | "working-start"
  | "working"
  | "revival-start"
  | "revival"
  | "alert";

/** Tokens are re-sent no more often than this unless they change. */
export const TOKEN_RESEND_INTERVAL_MS = 60_000;

const encodeRegistration = Schema.encodeSync(InfinitusActivityPushRegistration);

/** The Mac that drives this phone's cards: the one the preference names when
    it is still paired and runs Infinitus, else the first such Mac. */
export function pusherMac(
  preferredEnvironmentId: string | undefined,
  macs: ReadonlyArray<InfinitusMac>,
): InfinitusMac | null {
  if (preferredEnvironmentId !== undefined) {
    const preferred = macs.find((mac) => mac.environmentId === preferredEnvironmentId);
    if (preferred !== undefined) return preferred;
  }
  return macs[0] ?? null;
}

/** One token registration as the Mac's `activities-token` verb reads it:
    `layout: "expo"` asks for expo-widgets' `{name, props}` envelope, `macId`
    is the environment id the phone files the Mac under. */
export function registrationBody(input: {
  readonly kind: LiveActivityTokenKind;
  readonly token: string;
  readonly deviceId: string;
  readonly deviceName: string;
  readonly environmentId: EnvironmentId;
  readonly sandbox: boolean;
  readonly now: Date;
}): InfinitusActivityPushRegistration {
  return {
    kind: input.kind,
    token: input.token,
    deviceId: input.deviceId,
    deviceName: input.deviceName,
    environment: input.sandbox ? "sandbox" : "production",
    themeID: null,
    registeredAt: input.now.toISOString(),
    macId: input.environmentId,
    layout: "expo",
  };
}

/** The control command carrying a registration: the body rides `--body`. */
export function registrationCommand(
  body: InfinitusActivityPushRegistration,
): InfinitusCommandInput {
  return {
    command: "activities-token",
    args: [],
    options: { body: JSON.stringify(encodeRegistration(body)) },
  };
}

export interface SentToken {
  readonly token: string;
  readonly at: number;
}

/** Whether a token is worth sending: it is new for its kind, or the last send
    is older than the resend interval (the Mac may have restarted since). */
export function shouldSendToken(
  sent: ReadonlyMap<LiveActivityTokenKind, SentToken>,
  kind: LiveActivityTokenKind,
  token: string,
  now: number,
): boolean {
  const last = sent.get(kind);
  if (last === undefined || last.token !== token) return true;
  return now - last.at >= TOKEN_RESEND_INTERVAL_MS;
}
