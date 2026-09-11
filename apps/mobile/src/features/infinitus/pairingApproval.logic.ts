/**
 * Approve-on-Mac pairing (#710), the pure pieces: where the phone's two
 * unauthenticated requests go, what their replies have to look like, and the
 * words for each way the wait can end. The wire itself (fetch, the poll loop,
 * timers) lives in `pairingApproval.ts`.
 *
 * The phone never types a code. It asks the desktop server for approval with a
 * secret it made up, shows the short match code the server answered with, and
 * polls until the Mac's Devices card approves or denies the request. Approval
 * hands over the same one-time pairing credential a typed code would carry, so
 * the rest of the flow is the existing `connectAndClose`.
 */
import {
  PairingApprovalCreated,
  PairingApprovalPollResult,
} from "@t3tools/contracts/infinitusPairing";
import { Option, Schema } from "effect";

import { buildPairingUrl } from "../connection/pairing";

export const PAIRING_APPROVAL_PATH = "/api/infinitus/pairing-approval";
export const PAIRING_APPROVAL_POLL_PATH = "/api/infinitus/pairing-approval/poll";

/** Between polls while the request is pending. */
export const POLL_INTERVAL_MS = 2000;
/** How long the phone keeps polling when nothing answers: the server's 2 min
    TTL plus slack. Measured on the phone's own clock, so a phone and a Mac that
    disagree on the time cannot end the wait early — the server's 404 is the
    real verdict, this is only the safety net. */
export const WAIT_CAP_MS = 150_000;

const DEVICE_NAME_MAX = 64;

/**
 * The server's origin for what the Host field holds, on the same scheme rule
 * as the pairing URL the credential is later exchanged through (`http` for an
 * IP literal, `https` otherwise) — the approval and the exchange must reach the
 * same server. Null when the field does not hold a host.
 */
export function approvalOrigin(host: string): string | null {
  const url = buildPairingUrl(host, "probe");
  if (url === "") return null;
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

/** What the Mac lists the request as: the phone's name, within the contract's
    length, "iPhone" when the device has none. */
export function deviceLabel(deviceName: string | null | undefined): string {
  const trimmed = deviceName?.trim() ?? "";
  return (trimmed === "" ? "iPhone" : trimmed).slice(0, DEVICE_NAME_MAX);
}

// The bodies arrive as parsed JSON, so `expiresAt` is an ISO string: the JSON
// codec is what turns it into the `DateTime.Utc` the contract declares.
const decodeCreated = Schema.decodeUnknownOption(Schema.toCodecJson(PairingApprovalCreated));
const decodePollResult = Schema.decodeUnknownOption(Schema.toCodecJson(PairingApprovalPollResult));

/** A create reply as the waiting state needs it, or null for anything else. */
export function createdFromReply(
  body: unknown,
): { readonly id: string; readonly matchCode: string } | null {
  const created = decodeCreated(body);
  if (Option.isNone(created)) return null;
  return { id: created.value.id, matchCode: created.value.matchCode };
}

export type PollReply =
  | { readonly state: "pending" }
  | { readonly state: "approved"; readonly credential: string }
  | { readonly state: "denied" };

/** A poll reply, or null for a body that is not one. */
export function pollReplyFromBody(body: unknown): PollReply | null {
  const result = decodePollResult(body);
  if (Option.isNone(result)) return null;
  return result.value.state === "approved"
    ? { state: "approved", credential: result.value.credential }
    : { state: result.value.state };
}

export type ApprovalOutcome =
  | { readonly kind: "approved"; readonly credential: string }
  | { readonly kind: "denied" }
  | { readonly kind: "expired" }
  /** The server has too many requests waiting (429). */
  | { readonly kind: "refused" }
  /** Nothing answered at that host, or what did is not a fork server. */
  | { readonly kind: "unreachable" }
  | { readonly kind: "cancelled" };

/** The banner for an ended wait; null when there is nothing to say. */
export function outcomeMessage(outcome: ApprovalOutcome, host: string): string | null {
  switch (outcome.kind) {
    case "approved":
    case "cancelled":
      return null;
    case "denied":
      return "The Mac declined this request.";
    case "expired":
      return "The Mac did not answer within two minutes. Ask again.";
    case "refused":
      return "The Mac has too many requests waiting. Try again in a couple of minutes.";
    case "unreachable":
      return `No Infinitus server answered at ${host.trim()}. Check the host, and that Network access is on in the Mac's Devices card.`;
  }
}
