import * as Schema from "effect/Schema";
import * as HttpApiEndpoint from "effect/unstable/httpapi/HttpApiEndpoint";
import * as HttpApiGroup from "effect/unstable/httpapi/HttpApiGroup";

/**
 * Team delegated control (#1313, spec §8): a teammate's Mac posts one sealed
 * command envelope to this desktop, which hands it to the Mac's `team-inbox`
 * verb and answers the sealed ack. Unauthenticated like the pairing routes:
 * the envelope is what authenticates — signed by a roster member, sealed to
 * this Mac's identity, replay- and rate-checked on the Mac — and an
 * unverifiable one answers `ack: null`, never a reason. Nothing about a
 * request reaches a span or a log beyond its size.
 */

/** A sealed envelope, base64. A command is a few hundred bytes; the cap keeps
    an unauthenticated POST from carrying anything else. */
export const TeamControlEnvelope = Schema.String.check(
  Schema.isMinLength(1),
  Schema.isMaxLength(64 * 1024),
);

/** Body of `POST /api/infinitus/team/command`. */
export const TeamControlCommandInput = Schema.Struct({
  envelope: TeamControlEnvelope,
});
export type TeamControlCommandInput = typeof TeamControlCommandInput.Type;

/** The Mac's sealed ack (base64), or null when it had nobody to answer. */
export const TeamControlCommandResult = Schema.Struct({
  ack: Schema.NullOr(Schema.String),
});
export type TeamControlCommandResult = typeof TeamControlCommandResult.Type;

/** The Mac is not running, or did not answer: the driver falls to the store
    lane. No detail on purpose. */
export class TeamControlUnavailable extends Schema.TaggedError<TeamControlUnavailable>()(
  "TeamControlUnavailable",
  {},
  { httpApiStatus: 503 },
) {}

export class InfinitusTeamControlHttpApi extends HttpApiGroup.make("infinitusTeamControl").add(
  HttpApiEndpoint.post("teamCommand", "/api/infinitus/team/command", {
    payload: TeamControlCommandInput,
    success: TeamControlCommandResult,
    error: TeamControlUnavailable,
  }),
) {}
