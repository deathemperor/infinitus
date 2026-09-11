import type { PairingApprovalRequest } from "@t3tools/contracts/infinitusPairing";

/**
 * The "Pairing requests" card on Settings › Infinitus › Devices (#710), as pure
 * state: one row per phone asking to be let in, with the code the user
 * matches against the phone's screen and how long the ask has left. The
 * stream carries metadata only — never the phone's secret or the credential —
 * so there is nothing here to hide.
 */

export interface PairingRequestRow {
  readonly id: string;
  readonly deviceName: string;
  /** "iOS 26 · 192.168.1.20", or whichever of the two the request carried. */
  readonly detail: string | null;
  readonly matchCode: string;
  readonly secondsLeft: number;
}

/** Rows in the order the server holds them (oldest ask first), each with
    its remaining life; an expired one stays until the sweep drops it, at 0. */
export function pairingRequestRows(
  requests: ReadonlyArray<PairingApprovalRequest>,
  nowMs: number,
): ReadonlyArray<PairingRequestRow> {
  return requests.map((request) => ({
    id: request.id,
    deviceName: request.deviceName,
    detail:
      [request.os, request.remoteAddress].filter((part) => part !== undefined).join(" · ") || null,
    matchCode: request.matchCode,
    secondsLeft: Math.max(0, Math.ceil((request.expiresAt.epochMilliseconds - nowMs) / 1000)),
  }));
}

/** What a decision's outcome tells the user, or null when there is nothing to
    say (the row simply leaves the list). `decided: false` is the server saying
    the request was already gone. */
export function decisionNotice(input: {
  readonly approve: boolean;
  readonly outcome:
    | { readonly kind: "decided"; readonly decided: boolean }
    | { readonly kind: "failed"; readonly message: string };
}): string | null {
  if (input.outcome.kind === "failed") {
    return `Could not ${input.approve ? "approve" : "deny"} that request: ${input.outcome.message}`;
  }
  return input.outcome.decided ? null : "That request had already expired.";
}

/** The requests not toasted yet, in stream order. Every request the desktop
    has not seen is news — including those already waiting when the page
    loads, since a pending ask needs the user within two minutes. */
export function unseenRequests(
  requests: ReadonlyArray<PairingApprovalRequest>,
  seen: ReadonlySet<string>,
): ReadonlyArray<PairingApprovalRequest> {
  return requests.filter((request) => !seen.has(request.id));
}
