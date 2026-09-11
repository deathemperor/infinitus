import * as Schema from "effect/Schema";
import * as HttpApiEndpoint from "effect/unstable/httpapi/HttpApiEndpoint";
import * as HttpApiGroup from "effect/unstable/httpapi/HttpApiGroup";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Approve-on-Mac pairing (#710). A phone that found the server on the LAN asks
 * to be let in; the desktop approves; the phone collects the same one-time
 * pairing credential a QR code would have carried and runs the ordinary
 * `/oauth/token` exchange. The requester secret is the phone's proof that a
 * poll comes from the device that asked; the match code is what the user
 * compares between the two screens. Neither ever appears in a log, a span or
 * the Infinitus snapshot; the desktop's stream carries the match code because
 * showing it is the point.
 */

/** Opaque id the server assigns to one pending request. */
export const PairingApprovalRequestId = TrimmedNonEmptyString.check(Schema.isMaxLength(64));
export type PairingApprovalRequestId = typeof PairingApprovalRequestId.Type;

/** Random string the phone generates and keeps; presented on every poll. */
export const PairingApprovalSecret = Schema.String.check(
  Schema.isMinLength(16),
  Schema.isMaxLength(128),
);

/** Body of `POST /api/infinitus/pairing-approval`, unauthenticated. */
export const PairingApprovalCreateInput = Schema.Struct({
  deviceName: TrimmedNonEmptyString.check(Schema.isMaxLength(64)),
  os: Schema.optionalKey(TrimmedNonEmptyString.check(Schema.isMaxLength(32))),
  secret: PairingApprovalSecret,
});
export type PairingApprovalCreateInput = typeof PairingApprovalCreateInput.Type;

/** What the phone shows while it waits: the code the user matches on the Mac. */
export const PairingApprovalCreated = Schema.Struct({
  id: PairingApprovalRequestId,
  matchCode: TrimmedNonEmptyString,
  expiresAt: Schema.DateTimeUtc,
});
export type PairingApprovalCreated = typeof PairingApprovalCreated.Type;

/** Body of `POST /api/infinitus/pairing-approval/poll`, unauthenticated. */
export const PairingApprovalPollInput = Schema.Struct({
  id: PairingApprovalRequestId,
  secret: PairingApprovalSecret,
});
export type PairingApprovalPollInput = typeof PairingApprovalPollInput.Type;

/** The request's fate. `approved` carries the one-time pairing credential on
    every poll until the request expires: the grant store makes it single-use,
    so a dropped response is retried rather than stranding the phone. */
export const PairingApprovalPollResult = Schema.Union([
  Schema.Struct({ state: Schema.Literal("pending") }),
  Schema.Struct({
    state: Schema.Literal("approved"),
    credential: TrimmedNonEmptyString,
    expiresAt: Schema.DateTimeUtc,
  }),
  Schema.Struct({ state: Schema.Literal("denied") }),
]);
export type PairingApprovalPollResult = typeof PairingApprovalPollResult.Type;

/** One pending request as the desktop sees it: metadata only, never the
    secret, never the credential. */
export const PairingApprovalRequest = Schema.Struct({
  id: PairingApprovalRequestId,
  deviceName: TrimmedNonEmptyString,
  os: Schema.optionalKey(TrimmedNonEmptyString),
  remoteAddress: Schema.optionalKey(TrimmedNonEmptyString),
  matchCode: TrimmedNonEmptyString,
  createdAt: Schema.DateTimeUtc,
  expiresAt: Schema.DateTimeUtc,
});
export type PairingApprovalRequest = typeof PairingApprovalRequest.Type;

/** The current pending list, resent whole on every change. */
export const PairingApprovalPendingRequests = Schema.Array(PairingApprovalRequest);

/** `approve: false` denies. */
export const PairingApprovalDecideInput = Schema.Struct({
  id: PairingApprovalRequestId,
  approve: Schema.Boolean,
});
export type PairingApprovalDecideInput = typeof PairingApprovalDecideInput.Type;

/** `decided: false` means the request was gone (expired or already decided). */
export const PairingApprovalDecideResult = Schema.Struct({
  decided: Schema.Boolean,
});
export type PairingApprovalDecideResult = typeof PairingApprovalDecideResult.Type;

/** The server is holding as many requests as it will (overall or from this
    address); the phone should wait for one to expire and ask again. */
export class PairingApprovalRefused extends Schema.TaggedError<PairingApprovalRefused>()(
  "PairingApprovalRefused",
  { reason: Schema.Literals(["too_many_pending", "too_many_from_address"]) },
  { httpApiStatus: 429 },
) {}

/** No request with that id and secret: never created, expired, or the secret
    did not match (the two are not told apart on purpose). */
export class PairingApprovalNotFound extends Schema.TaggedError<PairingApprovalNotFound>()(
  "PairingApprovalNotFound",
  {},
  { httpApiStatus: 404 },
) {}

/** Approval passed every check but the credential could not be minted. */
export class PairingApprovalIssueFailed extends Schema.TaggedError<PairingApprovalIssueFailed>()(
  "PairingApprovalIssueFailed",
  { message: Schema.String },
) {}

/** The two phone-facing routes. No middleware: like `/oauth/token`, they are
    reached before the phone has any credential. */
export class InfinitusPairingHttpApi extends HttpApiGroup.make("infinitusPairing")
  .add(
    HttpApiEndpoint.post("pairingApprovalCreate", "/api/infinitus/pairing-approval", {
      payload: PairingApprovalCreateInput,
      success: PairingApprovalCreated,
      error: PairingApprovalRefused,
    }),
  )
  .add(
    HttpApiEndpoint.post("pairingApprovalPoll", "/api/infinitus/pairing-approval/poll", {
      payload: PairingApprovalPollInput,
      success: PairingApprovalPollResult,
      error: PairingApprovalNotFound,
    }),
  ) {}
