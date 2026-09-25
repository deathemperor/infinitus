import * as Schema from "effect/Schema";
import * as HttpApiEndpoint from "effect/unstable/httpapi/HttpApiEndpoint";
import * as HttpApiGroup from "effect/unstable/httpapi/HttpApiGroup";
import * as OpenApi from "effect/unstable/httpapi/OpenApi";

import { EnvironmentId, ThreadId, TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Team on Infinitus Connect (#1592): a team is a relay row, a member a Clerk
 * user, an invite a one-use or reusable token the relay checks, what a member
 * shares a document the desktop server publishes with its environment
 * credential. Schemas and the two route groups only; `relay.ts` attaches the
 * auth middleware where it adds the groups to `RelayApi`, so this file never
 * imports `relay.ts` (which imports it). The bearer header schema is inlined
 * for the same reason.
 */

export const TeamId = TrimmedNonEmptyString.pipe(Schema.brand("TeamId"));
export type TeamId = typeof TeamId.Type;
export const TeamUserId = TrimmedNonEmptyString;
export const TeamRole = Schema.Literals(["leader", "member"]);
export type TeamRole = typeof TeamRole.Type;
export const TeamShareAudience = Schema.Literals(["off", "leaders", "team"]);
export type TeamShareAudience = typeof TeamShareAudience.Type;
export const TeamKind = Schema.Literals(["now", "fleet", "threads", "stats", "transcripts"]);
export type TeamKind = typeof TeamKind.Type;
export const TEAM_KINDS: ReadonlyArray<TeamKind> = ["now", "fleet", "threads", "stats", "transcripts"];
export const TeamShares = Schema.Record(TeamKind, TeamShareAudience);
export type TeamShares = typeof TeamShares.Type;
/** Every kind starts `off`; a member turns each on. */
export const DEFAULT_TEAM_SHARES: TeamShares = {
  now: "off",
  fleet: "off",
  threads: "off",
  stats: "off",
  transcripts: "off",
};
export const TeamPolicyRequests = Schema.Literals(["code", "off"]);
export type TeamPolicyRequests = typeof TeamPolicyRequests.Type;
export const TeamCapability = Schema.Literals(["view", "send", "interrupt", "new"]);
export type TeamCapability = typeof TeamCapability.Type;
export const TeamAudience = Schema.Union([Schema.Literals(["team", "leaders"]), Schema.Array(TeamUserId)]);
export type TeamAudience = typeof TeamAudience.Type;
export const TeamThreadsSelector = Schema.Union([Schema.Literal("all"), Schema.Array(ThreadId)]);
export type TeamThreadsSelector = typeof TeamThreadsSelector.Type;
export const TeamCommandAction = TeamCapability;
export type TeamCommandAction = typeof TeamCommandAction.Type;
export const TeamCommandStatus = Schema.Literals([
  "queued",
  "pending",
  "running",
  "done",
  "refused",
  "denied",
  "expired",
]);
export type TeamCommandStatus = typeof TeamCommandStatus.Type;
export const TeamCommandOutcome = Schema.Literals([
  "done",
  "refused",
  "pending",
  "notLive",
  "noGrant",
  "badRequest",
]);
export type TeamCommandOutcome = typeof TeamCommandOutcome.Type;

const MemberName = TrimmedNonEmptyString.check(Schema.isMaxLength(64));
const TeamName = TrimmedNonEmptyString.check(Schema.isMaxLength(64));
const Iso = Schema.String;

/** The `now` document a machine publishes every minute, opaque to the relay. */
export const TeamMachine = Schema.Struct({
  environmentId: EnvironmentId,
  label: Schema.String,
  now: Schema.optional(Schema.Unknown),
  lastPublished: Schema.NullOr(Iso),
});
export type TeamMachine = typeof TeamMachine.Type;
export const TeamMemberRow = Schema.Struct({
  userId: TeamUserId,
  name: MemberName,
  role: TeamRole,
  founder: Schema.Boolean,
  since: Iso,
  machines: Schema.Array(TeamMachine),
});
export type TeamMemberRow = typeof TeamMemberRow.Type;
export const TeamRequestRow = Schema.Struct({ userId: TeamUserId, name: MemberName, at: Iso });
export type TeamRequestRow = typeof TeamRequestRow.Type;
export const TeamInviteRow = Schema.Struct({
  inviteId: Schema.String,
  oneUse: Schema.Boolean,
  expiresAt: Iso,
  usedBy: Schema.NullOr(TeamUserId),
});
export type TeamInviteRow = typeof TeamInviteRow.Type;
export const TeamGrant = Schema.Struct({
  grantId: Schema.String,
  environmentId: EnvironmentId,
  audience: TeamAudience,
  threads: TeamThreadsSelector,
  capabilities: Schema.Array(TeamCapability),
  preauthorized: Schema.Array(TeamCapability),
  expiresAt: Schema.NullOr(Iso),
});
export type TeamGrant = typeof TeamGrant.Type;
export const TeamPendingCommand = Schema.Struct({
  commandId: Schema.String,
  fromUserId: TeamUserId,
  fromName: MemberName,
  environmentId: EnvironmentId,
  threadId: Schema.String,
  action: TeamCommandAction,
  text: Schema.optional(Schema.String),
  project: Schema.optional(Schema.String),
  expiresAt: Iso,
});
export type TeamPendingCommand = typeof TeamPendingCommand.Type;
export const TeamGrantToMe = Schema.Struct({
  grantorUserId: TeamUserId,
  environmentId: EnvironmentId,
  threads: TeamThreadsSelector,
  capabilities: Schema.Array(TeamCapability),
});
export type TeamGrantToMe = typeof TeamGrantToMe.Type;
export const TeamSnapshot = Schema.Struct({
  teamId: TeamId,
  name: Schema.String,
  role: TeamRole,
  policy: Schema.Struct({ requests: TeamPolicyRequests }),
  me: Schema.Struct({ name: MemberName, shares: TeamShares }),
  members: Schema.Array(TeamMemberRow),
  /** Leaders only; `[]` for a member. */
  requests: Schema.Array(TeamRequestRow),
  /** Leaders only, never the token. */
  invites: Schema.Array(TeamInviteRow),
  /** Mine. */
  grants: Schema.Array(TeamGrant),
  /** Waiting for my tap. */
  pending: Schema.Array(TeamPendingCommand),
  grantsToMe: Schema.Array(TeamGrantToMe),
});
export type TeamSnapshot = typeof TeamSnapshot.Type;

export const TeamListRow = Schema.Struct({ teamId: TeamId, name: Schema.String, role: TeamRole });
export type TeamListRow = typeof TeamListRow.Type;
export const TeamCreateRequest = Schema.Struct({ name: TeamName, memberName: MemberName });
export type TeamCreateRequest = typeof TeamCreateRequest.Type;
export const TeamJoinRequest = Schema.Struct({ token: TrimmedNonEmptyString, memberName: MemberName });
export type TeamJoinRequest = typeof TeamJoinRequest.Type;
export const TeamJoinResponse = Schema.Struct({
  teamId: TeamId,
  status: Schema.Literals(["member", "pending"]),
});
export type TeamJoinResponse = typeof TeamJoinResponse.Type;
export const TeamMeUpdate = Schema.Struct({
  name: Schema.optional(MemberName),
  shares: Schema.optional(TeamShares),
});
export type TeamMeUpdate = typeof TeamMeUpdate.Type;
export const TeamInviteCreate = Schema.Struct({
  days: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 3650 })),
  oneUse: Schema.Boolean,
});
export type TeamInviteCreate = typeof TeamInviteCreate.Type;
/** The token is shown once, never again: it is never on a snapshot or a log. */
export const TeamInviteCreated = Schema.Struct({
  inviteId: Schema.String,
  token: Schema.String,
  expiresAt: Iso,
});
export type TeamInviteCreated = typeof TeamInviteCreated.Type;
export const TeamPolicyUpdate = Schema.Struct({ requests: TeamPolicyRequests });
export type TeamPolicyUpdate = typeof TeamPolicyUpdate.Type;
export const TeamDocumentRow = Schema.Struct({
  userId: TeamUserId,
  environmentId: EnvironmentId,
  kind: TeamKind,
  key: Schema.String,
  body: Schema.Unknown,
  updatedAt: Iso,
});
export type TeamDocumentRow = typeof TeamDocumentRow.Type;
export const TeamDocumentsQuery = Schema.Struct({
  userId: Schema.optional(TeamUserId),
  environmentId: Schema.optional(EnvironmentId),
  kind: Schema.optional(TeamKind),
});
export type TeamDocumentsQuery = typeof TeamDocumentsQuery.Type;
export const TeamTranscriptChunkRow = Schema.Struct({
  seq: Schema.Int,
  rows: Schema.Int,
  bytes: Schema.Int,
  createdAt: Iso,
});
export type TeamTranscriptChunkRow = typeof TeamTranscriptChunkRow.Type;
export const TeamTranscriptChunk = Schema.Struct({ lines: Schema.String });
export type TeamTranscriptChunk = typeof TeamTranscriptChunk.Type;
export const TeamGrantCreate = Schema.Struct({
  environmentId: EnvironmentId,
  audience: TeamAudience,
  threads: TeamThreadsSelector,
  capabilities: Schema.Array(TeamCapability),
  preauthorized: Schema.optional(Schema.Array(TeamCapability)),
  expiresInSeconds: Schema.optional(Schema.Int.check(Schema.isGreaterThan(0))),
});
export type TeamGrantCreate = typeof TeamGrantCreate.Type;
export const TEAM_COMMAND_TEXT_MAX = 16_384;
export const TeamCommandCreate = Schema.Struct({
  toUserId: TeamUserId,
  environmentId: EnvironmentId,
  /** `-` for `new`, which targets the machine rather than a thread. */
  threadId: TrimmedNonEmptyString,
  action: TeamCommandAction,
  text: Schema.optional(Schema.String.check(Schema.isMaxLength(TEAM_COMMAND_TEXT_MAX))),
  project: Schema.optional(TrimmedNonEmptyString),
});
export type TeamCommandCreate = typeof TeamCommandCreate.Type;
export const TeamCommandAckBody = Schema.Struct({
  outcome: TeamCommandOutcome,
  detail: Schema.optional(Schema.String),
  result: Schema.optional(Schema.Unknown),
});
export type TeamCommandAckBody = typeof TeamCommandAckBody.Type;
export const TeamCommandState = Schema.Struct({
  commandId: Schema.String,
  status: TeamCommandStatus,
  ack: Schema.optional(TeamCommandAckBody),
});
export type TeamCommandState = typeof TeamCommandState.Type;
export const TeamOk = Schema.Struct({ ok: Schema.Literal(true) });
export type TeamOk = typeof TeamOk.Type;

/** Environment side (the desktop server, environment credential). */
export const TeamEnvironmentMembership = Schema.Struct({
  teamId: TeamId,
  shares: TeamShares,
  /** This environment's grants, for the command poller's local re-check. */
  grants: Schema.Array(TeamGrant),
  /** Rows already published per thread: the publisher resumes after them. */
  transcripts: Schema.Array(Schema.Struct({ threadId: Schema.String, rows: Schema.Int, nextSeq: Schema.Int })),
});
export type TeamEnvironmentMembership = typeof TeamEnvironmentMembership.Type;
export const TeamEnvironmentMemberships = Schema.Struct({
  userId: TeamUserId,
  teams: Schema.Array(TeamEnvironmentMembership),
});
export type TeamEnvironmentMemberships = typeof TeamEnvironmentMemberships.Type;
export const TEAM_DOCUMENTS_PER_PUBLISH = 40;
export const TEAM_DOCUMENT_MAX_BYTES = 262_144;
export const TeamDocumentPublish = Schema.Struct({
  kind: TeamKind,
  /** `-` for the single-document kinds, the day (`2026-09-25`) for `stats`. */
  key: TrimmedNonEmptyString.check(Schema.isMaxLength(32)),
  body: Schema.Unknown,
});
export type TeamDocumentPublish = typeof TeamDocumentPublish.Type;
export const TeamDocumentsPublish = Schema.Struct({
  userId: TeamUserId,
  documents: Schema.Array(TeamDocumentPublish).check(Schema.isMaxLength(TEAM_DOCUMENTS_PER_PUBLISH)),
});
export type TeamDocumentsPublish = typeof TeamDocumentsPublish.Type;
export const TEAM_TRANSCRIPT_CHUNK_MAX_BYTES = 1_048_576;
export const TeamTranscriptPublish = Schema.Struct({
  userId: TeamUserId,
  threadId: TrimmedNonEmptyString,
  seq: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  rows: Schema.Int.check(Schema.isGreaterThan(0)),
  lines: Schema.String.check(Schema.isMaxLength(TEAM_TRANSCRIPT_CHUNK_MAX_BYTES)),
});
export type TeamTranscriptPublish = typeof TeamTranscriptPublish.Type;
export const TeamQueuedCommand = Schema.Struct({
  commandId: Schema.String,
  teamId: TeamId,
  fromUserId: TeamUserId,
  threadId: Schema.String,
  action: TeamCommandAction,
  text: Schema.optional(Schema.String),
  project: Schema.optional(Schema.String),
  expiresAt: Iso,
  grant: TeamGrant,
});
export type TeamQueuedCommand = typeof TeamQueuedCommand.Type;
export const TeamCommandAck = Schema.Struct({
  userId: TeamUserId,
  outcome: TeamCommandOutcome,
  detail: Schema.optional(Schema.String),
  result: Schema.optional(Schema.Unknown),
});
export type TeamCommandAck = typeof TeamCommandAck.Type;

/** Everything the caller can fix: a refused join, a spent or expired invite, a
    policy refusal, an unknown team or member, the last leader leaving. The
    clients show `reason` verbatim. */
export class RelayInfinitusTeamRefusedError extends Schema.TaggedError<RelayInfinitusTeamRefusedError>()(
  "RelayInfinitusTeamRefusedError",
  {
    code: Schema.Literal("infinitus_team_refused"),
    reason: TrimmedNonEmptyString,
    traceId: TrimmedNonEmptyString,
  },
  { httpApiStatus: 409 },
) {
  override get message(): string {
    return this.reason;
  }
}

const Bearer = Schema.Struct({ authorization: TrimmedNonEmptyString });
/** The environment names its one linked user on the two reads that carry no
    payload; the relay checks the link for that user, environment and key. */
export const TEAM_USER_HEADER = "x-infinitus-user";
const BearerAndUser = Schema.Struct({
  authorization: TrimmedNonEmptyString,
  [TEAM_USER_HEADER]: TeamUserId,
});
const teamParams = Schema.Struct({ teamId: TeamId });
const memberParams = Schema.Struct({ teamId: TeamId, userId: TeamUserId });
const refused = RelayInfinitusTeamRefusedError;

export const RelayInfinitusTeamGroup = HttpApiGroup.make("infinitusTeam")
  .add(
    HttpApiEndpoint.get("listTeams", "/v1/infinitus/teams", {
      headers: Bearer,
      success: Schema.Array(TeamListRow),
    }).annotate(OpenApi.Summary, "List the teams the user is in"),
    HttpApiEndpoint.post("createTeam", "/v1/infinitus/teams", {
      headers: Bearer,
      payload: TeamCreateRequest,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Create a team; the caller is its founding leader"),
    HttpApiEndpoint.post("joinTeam", "/v1/infinitus/team-join", {
      headers: Bearer,
      payload: TeamJoinRequest,
      success: TeamJoinResponse,
      error: refused,
    }).annotate(OpenApi.Summary, "Join with an invite token: at once for a one-use invite, as a request otherwise"),
    HttpApiEndpoint.get("getTeam", "/v1/infinitus/teams/:teamId", {
      headers: Bearer,
      params: teamParams,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "The team as the caller sees it"),
    HttpApiEndpoint.put("updateMe", "/v1/infinitus/teams/:teamId/me", {
      headers: Bearer,
      params: teamParams,
      payload: TeamMeUpdate,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Change my name or what I share"),
    HttpApiEndpoint.post("leaveTeam", "/v1/infinitus/teams/:teamId/leave", {
      headers: Bearer,
      params: teamParams,
      success: TeamOk,
      error: refused,
    }).annotate(OpenApi.Summary, "Leave; never the last leader"),
    HttpApiEndpoint.post("createInvite", "/v1/infinitus/teams/:teamId/invites", {
      headers: Bearer,
      params: teamParams,
      payload: TeamInviteCreate,
      success: TeamInviteCreated,
      error: refused,
    }).annotate(OpenApi.Summary, "Mint an invite token (leaders); the token is answered once"),
    HttpApiEndpoint.delete("revokeInvite", "/v1/infinitus/teams/:teamId/invites/:inviteId", {
      headers: Bearer,
      params: Schema.Struct({ teamId: TeamId, inviteId: TrimmedNonEmptyString }),
      success: TeamOk,
      error: refused,
    }).annotate(OpenApi.Summary, "Revoke an invite (leaders)"),
    HttpApiEndpoint.post("approveRequest", "/v1/infinitus/teams/:teamId/requests/:userId/approve", {
      headers: Bearer,
      params: memberParams,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Approve a join request (leaders)"),
    HttpApiEndpoint.post("declineRequest", "/v1/infinitus/teams/:teamId/requests/:userId/decline", {
      headers: Bearer,
      params: memberParams,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Decline a join request (leaders)"),
    HttpApiEndpoint.post("promoteMember", "/v1/infinitus/teams/:teamId/members/:userId/promote", {
      headers: Bearer,
      params: memberParams,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Make a member a leader (leaders)"),
    HttpApiEndpoint.post("demoteMember", "/v1/infinitus/teams/:teamId/members/:userId/demote", {
      headers: Bearer,
      params: memberParams,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Make a leader a member (leaders); never the last leader"),
    HttpApiEndpoint.post("removeMember", "/v1/infinitus/teams/:teamId/members/:userId/remove", {
      headers: Bearer,
      params: memberParams,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Remove a member with everything they published (leaders); never the founder"),
    HttpApiEndpoint.put("updatePolicy", "/v1/infinitus/teams/:teamId/policy", {
      headers: Bearer,
      params: teamParams,
      payload: TeamPolicyUpdate,
      success: TeamSnapshot,
      error: refused,
    }).annotate(OpenApi.Summary, "Who may request to join (leaders)"),
    HttpApiEndpoint.get("listDocuments", "/v1/infinitus/teams/:teamId/documents", {
      headers: Bearer,
      params: teamParams,
      query: TeamDocumentsQuery,
      success: Schema.Array(TeamDocumentRow),
      error: refused,
    }).annotate(OpenApi.Summary, "Teammates' documents the caller may read, by the publisher's share and the caller's role"),
    HttpApiEndpoint.get(
      "listTranscriptChunks",
      "/v1/infinitus/teams/:teamId/transcripts/:userId/:environmentId/:threadId",
      {
        headers: Bearer,
        params: Schema.Struct({
          teamId: TeamId,
          userId: TeamUserId,
          environmentId: EnvironmentId,
          threadId: TrimmedNonEmptyString,
        }),
        success: Schema.Array(TeamTranscriptChunkRow),
        error: refused,
      },
    ).annotate(OpenApi.Summary, "A teammate's transcript chunks for one thread"),
    HttpApiEndpoint.get(
      "readTranscriptChunk",
      "/v1/infinitus/teams/:teamId/transcripts/:userId/:environmentId/:threadId/:seq",
      {
        headers: Bearer,
        params: Schema.Struct({
          teamId: TeamId,
          userId: TeamUserId,
          environmentId: EnvironmentId,
          threadId: TrimmedNonEmptyString,
          seq: Schema.NumberFromString,
        }),
        success: TeamTranscriptChunk,
        error: refused,
      },
    ).annotate(OpenApi.Summary, "One transcript chunk's lines"),
    HttpApiEndpoint.post("createGrant", "/v1/infinitus/teams/:teamId/grants", {
      headers: Bearer,
      params: teamParams,
      payload: TeamGrantCreate,
      success: TeamGrant,
      error: refused,
    }).annotate(OpenApi.Summary, "Let an audience drive my threads on one of my environments"),
    HttpApiEndpoint.delete("revokeGrant", "/v1/infinitus/teams/:teamId/grants/:grantId", {
      headers: Bearer,
      params: Schema.Struct({ teamId: TeamId, grantId: TrimmedNonEmptyString }),
      success: TeamOk,
      error: refused,
    }).annotate(OpenApi.Summary, "Take a grant back"),
    HttpApiEndpoint.post("createCommand", "/v1/infinitus/teams/:teamId/commands", {
      headers: Bearer,
      params: teamParams,
      payload: TeamCommandCreate,
      success: TeamCommandState,
      error: refused,
    }).annotate(OpenApi.Summary, "Queue a command on a teammate's thread under their grant"),
    HttpApiEndpoint.get("listPendingCommands", "/v1/infinitus/teams/:teamId/commands", {
      headers: Bearer,
      params: teamParams,
      success: Schema.Array(TeamPendingCommand),
      error: refused,
    }).annotate(OpenApi.Summary, "Commands waiting for my tap"),
    HttpApiEndpoint.get("getCommand", "/v1/infinitus/teams/:teamId/commands/:commandId", {
      headers: Bearer,
      params: Schema.Struct({ teamId: TeamId, commandId: TrimmedNonEmptyString }),
      success: TeamCommandState,
      error: refused,
    }).annotate(OpenApi.Summary, "A command's state (its sender or its grantor)"),
    HttpApiEndpoint.post("allowCommand", "/v1/infinitus/teams/:teamId/commands/:commandId/allow", {
      headers: Bearer,
      params: Schema.Struct({ teamId: TeamId, commandId: TrimmedNonEmptyString }),
      success: TeamCommandState,
      error: refused,
    }).annotate(OpenApi.Summary, "Run a waiting command (the grantor)"),
    HttpApiEndpoint.post("denyCommand", "/v1/infinitus/teams/:teamId/commands/:commandId/deny", {
      headers: Bearer,
      params: Schema.Struct({ teamId: TeamId, commandId: TrimmedNonEmptyString }),
      success: TeamCommandState,
      error: refused,
    }).annotate(OpenApi.Summary, "Refuse a waiting command (the grantor)"),
  )
  .annotate(
    OpenApi.Description,
    "Infinitus Team: membership, sharing and delegated control for the signed-in user.",
  );

const envParams = Schema.Struct({ environmentId: EnvironmentId });
const envTeamParams = Schema.Struct({ environmentId: EnvironmentId, teamId: TeamId });

export const RelayInfinitusTeamEnvironmentGroup = HttpApiGroup.make("infinitusTeamEnvironment")
  .add(
    HttpApiEndpoint.get("memberships", "/v1/environments/:environmentId/infinitus-team", {
      headers: BearerAndUser,
      params: envParams,
      success: TeamEnvironmentMemberships,
      error: refused,
    }).annotate(OpenApi.Summary, "The linked user's teams, shares, this environment's grants and transcript cursors"),
    HttpApiEndpoint.post(
      "publishDocuments",
      "/v1/environments/:environmentId/infinitus-team/:teamId/documents",
      {
        headers: Bearer,
        params: envTeamParams,
        payload: TeamDocumentsPublish,
        success: TeamOk,
        error: refused,
      },
    ).annotate(OpenApi.Summary, "Upsert this environment's documents for one team"),
    HttpApiEndpoint.post(
      "publishTranscript",
      "/v1/environments/:environmentId/infinitus-team/:teamId/transcripts",
      {
        headers: Bearer,
        params: envTeamParams,
        payload: TeamTranscriptPublish,
        success: TeamOk,
        error: refused,
      },
    ).annotate(OpenApi.Summary, "Append one transcript chunk; refused unless transcripts are shared"),
    HttpApiEndpoint.get("pollCommands", "/v1/environments/:environmentId/infinitus-team/commands", {
      headers: BearerAndUser,
      params: envParams,
      success: Schema.Array(TeamQueuedCommand),
      error: refused,
    }).annotate(OpenApi.Summary, "Queued commands for this environment; each is marked running"),
    HttpApiEndpoint.post(
      "ackCommand",
      "/v1/environments/:environmentId/infinitus-team/commands/:commandId/ack",
      {
        headers: Bearer,
        params: Schema.Struct({ environmentId: EnvironmentId, commandId: TrimmedNonEmptyString }),
        payload: TeamCommandAck,
        success: TeamOk,
        error: refused,
      },
    ).annotate(OpenApi.Summary, "A command's outcome; `pending` waits for the grantor's tap"),
  )
  .annotate(
    OpenApi.Description,
    "Infinitus Team: what a linked environment publishes and runs for its user.",
  );

/** Does `grant` let `from` run `action` on `threadId`? The relay checks this
    when a command is queued and again when it is polled; the desktop server
    checks it once more before running, on the grants the relay listed. */
export function teamGrantAllows(
  grant: TeamGrant,
  input: {
    readonly fromUserId: string;
    readonly fromRole: TeamRole;
    readonly threadId: string;
    readonly action: TeamCapability;
    readonly nowIso: string;
  },
): boolean {
  if (grant.expiresAt !== null && grant.expiresAt <= input.nowIso) return false;
  if (!grant.capabilities.includes(input.action)) return false;
  const audience = grant.audience;
  const inAudience =
    audience === "team" ||
    (audience === "leaders" && input.fromRole === "leader") ||
    (Array.isArray(audience) && audience.includes(input.fromUserId));
  if (!inAudience) return false;
  if (input.action === "new") return input.threadId === "-";
  if (input.threadId === "-") return false;
  return grant.threads === "all" || grant.threads.includes(input.threadId as ThreadId);
}

/** `interrupt` and `new` ask the grantor unless the grant preauthorizes them. */
export function teamCommandNeedsTap(grant: TeamGrant, action: TeamCapability): boolean {
  return (action === "interrupt" || action === "new") && !grant.preauthorized.includes(action);
}
