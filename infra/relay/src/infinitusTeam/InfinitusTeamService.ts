import {
  DEFAULT_TEAM_SHARES,
  TEAM_KINDS,
  type TeamCapability,
  type TeamCommandAckBody,
  type TeamCommandState,
  type TeamDocumentRow,
  type TeamEnvironmentMemberships,
  type TeamGrant,
  type TeamGrantCreate,
  type TeamId,
  type TeamInviteCreated,
  type TeamJoinResponse,
  type TeamKind,
  type TeamListRow,
  type TeamMachine,
  type TeamPendingCommand,
  type TeamPolicyRequests,
  type TeamQueuedCommand,
  type TeamRole,
  type TeamShares,
  type TeamSnapshot,
  type TeamTranscriptChunkRow,
  type TeamCommandOutcome,
  teamCommandNeedsTap,
  teamGrantAllows,
} from "@infinitus/contracts/relayInfinitusTeam";
import type { EnvironmentId } from "@infinitus/contracts";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Encoding from "effect/Encoding";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

import * as EnvironmentLinks from "../environments/EnvironmentLinks.ts";
import {
  type CommandRecord,
  type GrantRecord,
  InfinitusTeamStore,
  type InfinitusTeamPersistenceError,
  type MemberRecord,
  type TranscriptRecord,
} from "./InfinitusTeamStore.ts";
import {
  InfinitusTeamTranscriptStore,
  type InfinitusTeamTranscriptStoreError,
  objectKey,
} from "./InfinitusTeamTranscriptStore.ts";

/**
 * Team on Infinitus Connect (#1592): every rule, on top of the store. A
 * refusal the caller can fix is `TeamRefused` with a sentence the clients
 * show verbatim; the API layer turns it into `RelayInfinitusTeamRefusedError`.
 * Times are ISO strings compared lexically, as the relay's other tables do.
 */
export class TeamRefused extends Schema.TaggedError<TeamRefused>()("TeamRefused", {
  reason: Schema.String,
}) {
  override get message(): string {
    return this.reason;
  }
}

export type TeamServiceError =
  | TeamRefused
  | InfinitusTeamPersistenceError
  | InfinitusTeamTranscriptStoreError
  | EnvironmentLinks.EnvironmentLinkListPersistenceError
  | EnvironmentLinks.EnvironmentLinkLookupPersistenceError;

type E<A> = Effect.Effect<A, TeamServiceError>;

/** A `now` older than this reads as offline: the machine row stays, its `now` goes. */
export const NOW_FRESH_MS = 10 * 60 * 1_000;
export const PENDING_TTL_SECONDS = 120;
export const QUEUED_TTL_SECONDS = 600;
export const TRANSCRIPT_RETENTION_DAYS = 90;
export const TRANSCRIPT_MEMBER_BYTES = 200 * 1024 * 1024;

export class InfinitusTeamService extends Context.Service<
  InfinitusTeamService,
  {
    readonly listTeams: (userId: string) => E<ReadonlyArray<TeamListRow>>;
    readonly createTeam: (input: { userId: string; name: string; memberName: string }) => E<TeamSnapshot>;
    readonly joinTeam: (input: { userId: string; token: string; memberName: string }) => E<TeamJoinResponse>;
    readonly getTeam: (input: { userId: string; teamId: string }) => E<TeamSnapshot>;
    readonly updateMe: (input: { userId: string; teamId: string; name?: string; shares?: TeamShares }) => E<TeamSnapshot>;
    readonly leaveTeam: (input: { userId: string; teamId: string }) => E<void>;
    readonly createInvite: (input: { userId: string; teamId: string; days: number; oneUse: boolean }) => E<TeamInviteCreated>;
    readonly revokeInvite: (input: { userId: string; teamId: string; inviteId: string }) => E<void>;
    readonly approveRequest: (input: { userId: string; teamId: string; targetUserId: string }) => E<TeamSnapshot>;
    readonly declineRequest: (input: { userId: string; teamId: string; targetUserId: string }) => E<TeamSnapshot>;
    readonly promoteMember: (input: { userId: string; teamId: string; targetUserId: string }) => E<TeamSnapshot>;
    readonly demoteMember: (input: { userId: string; teamId: string; targetUserId: string }) => E<TeamSnapshot>;
    readonly removeMember: (input: { userId: string; teamId: string; targetUserId: string }) => E<TeamSnapshot>;
    readonly updatePolicy: (input: { userId: string; teamId: string; requests: TeamPolicyRequests }) => E<TeamSnapshot>;
    readonly listDocuments: (input: {
      userId: string;
      teamId: string;
      ownerUserId?: string;
      environmentId?: string;
      kind?: TeamKind;
    }) => E<ReadonlyArray<TeamDocumentRow>>;
    readonly listTranscriptChunks: (input: {
      userId: string;
      teamId: string;
      ownerUserId: string;
      environmentId: string;
      threadId: string;
    }) => E<ReadonlyArray<TeamTranscriptChunkRow>>;
    readonly readTranscriptChunk: (input: {
      userId: string;
      teamId: string;
      ownerUserId: string;
      environmentId: string;
      threadId: string;
      seq: number;
    }) => E<string>;
    readonly createGrant: (input: { userId: string; teamId: string } & TeamGrantCreate) => E<TeamGrant>;
    readonly revokeGrant: (input: { userId: string; teamId: string; grantId: string }) => E<void>;
    readonly createCommand: (input: {
      userId: string;
      teamId: string;
      toUserId: string;
      environmentId: string;
      threadId: string;
      action: TeamCapability;
      text?: string;
      project?: string;
    }) => E<TeamCommandState>;
    readonly listPendingCommands: (input: { userId: string; teamId: string }) => E<ReadonlyArray<TeamPendingCommand>>;
    readonly getCommand: (input: { userId: string; teamId: string; commandId: string }) => E<TeamCommandState>;
    readonly allowCommand: (input: { userId: string; teamId: string; commandId: string }) => E<TeamCommandState>;
    readonly denyCommand: (input: { userId: string; teamId: string; commandId: string }) => E<TeamCommandState>;

    /** Environment side. Every call first proves the link for that user, environment and key. */
    readonly memberships: (input: {
      userId: string;
      environmentId: string;
      environmentPublicKey: string;
    }) => E<TeamEnvironmentMemberships>;
    readonly publishDocuments: (input: {
      userId: string;
      environmentId: string;
      environmentPublicKey: string;
      teamId: string;
      documents: ReadonlyArray<{ kind: TeamKind; key: string; body: unknown }>;
    }) => E<void>;
    readonly publishTranscript: (input: {
      userId: string;
      environmentId: string;
      environmentPublicKey: string;
      teamId: string;
      threadId: string;
      seq: number;
      rows: number;
      lines: string;
    }) => E<void>;
    readonly pollCommands: (input: {
      userId: string;
      environmentId: string;
      environmentPublicKey: string;
    }) => E<ReadonlyArray<TeamQueuedCommand>>;
    readonly ackCommand: (input: {
      userId: string;
      environmentId: string;
      environmentPublicKey: string;
      commandId: string;
      outcome: TeamCommandOutcome;
      detail?: string;
      result?: unknown;
    }) => E<void>;
    /** The cron: expired commands, transcripts past retention or over the per-member cap. */
    readonly prune: E<{ readonly transcriptsDeleted: number }>;
  }
>()("infinitus-relay/infinitusTeam/InfinitusTeamService") {}

const refuse = (reason: string) => new TeamRefused({ reason });

const grantOf = (record: GrantRecord): TeamGrant => ({
  grantId: record.grantId,
  environmentId: record.environmentId as EnvironmentId,
  audience: record.audience,
  threads: record.threads,
  capabilities: record.capabilities,
  preauthorized: record.preauthorized,
  expiresAt: record.expiresAt,
});

const commandState = (record: CommandRecord): TeamCommandState => ({
  commandId: record.commandId,
  status: record.status,
  ...(record.ack ? { ack: record.ack } : {}),
});

const normalizeShares = (shares: TeamShares | Record<string, string> | undefined): TeamShares => {
  const out = { ...DEFAULT_TEAM_SHARES };
  for (const kind of TEAM_KINDS) {
    const value = shares?.[kind];
    if (value === "off" || value === "leaders" || value === "team") out[kind] = value;
  }
  return out;
};

/** May `reader` see `publisher`'s `kind`? The publisher always sees their own. */
export const readable = (publisher: MemberRecord, reader: MemberRecord, kind: TeamKind): boolean => {
  if (publisher.userId === reader.userId) return true;
  const share = normalizeShares(publisher.shares)[kind];
  return share === "team" || (share === "leaders" && reader.role === "leader");
};

export const make = Effect.gen(function* () {
  const store = yield* InfinitusTeamStore;
  const transcripts = yield* InfinitusTeamTranscriptStore;
  const links = yield* EnvironmentLinks.EnvironmentLinks;
  const crypto = yield* Crypto.Crypto;

  const nowIso = DateTime.now.pipe(Effect.map(DateTime.formatIso));
  const plusSeconds = (iso: string, seconds: number) =>
    DateTime.formatIso(
      seconds < 0
        ? DateTime.subtract(DateTime.makeUnsafe(iso), { seconds: -seconds })
        : DateTime.add(DateTime.makeUnsafe(iso), { seconds }),
    );
  const uuid = crypto.randomUUIDv4.pipe(Effect.orDie);
  const hashToken = (token: string) =>
    crypto
      .digest("SHA-256", new TextEncoder().encode(token))
      .pipe(Effect.map(Encoding.encodeBase64Url), Effect.orDie);

  const requireTeam = (teamId: string) =>
    store.getTeam(teamId).pipe(
      Effect.flatMap((team) => (team ? Effect.succeed(team) : Effect.fail(refuse("This team does not exist.")))),
    );
  const requireMember = (teamId: string, userId: string) =>
    store.getMember(teamId, userId).pipe(
      Effect.flatMap((member) =>
        member ? Effect.succeed(member) : Effect.fail(refuse("You are not in this team.")),
      ),
    );
  const requireLeader = (teamId: string, userId: string) =>
    requireMember(teamId, userId).pipe(
      Effect.flatMap((member) =>
        member.role === "leader" ? Effect.succeed(member) : Effect.fail(refuse("Only a leader can do that.")),
      ),
    );
  const requireTarget = (teamId: string, targetUserId: string) =>
    store.getMember(teamId, targetUserId).pipe(
      Effect.flatMap((member) =>
        member ? Effect.succeed(member) : Effect.fail(refuse("That person is not in this team.")),
      ),
    );
  const leaderCount = (members: ReadonlyArray<MemberRecord>) => members.filter((m) => m.role === "leader").length;

  const deleteTranscriptObjects = (records: ReadonlyArray<TranscriptRecord>) =>
    records.length === 0 ? Effect.void : transcripts.delete(records.map((r) => r.objectKey));

  const snapshot = Effect.fn("relay.infinitus_team.snapshot")(function* (teamId: string, userId: string) {
    const team = yield* requireTeam(teamId);
    const me = yield* requireMember(teamId, userId);
    const members = yield* store.listMembers(teamId);
    const documents = yield* store.listDocuments({ teamId });
    const grants = yield* store.listGrantsForTeam(teamId);
    const now = yield* nowIso;
    const freshFloor = plusSeconds(now, -NOW_FRESH_MS / 1_000);

    const rows: Array<TeamSnapshot["members"][number]> = [];
    for (const member of [...members].sort((a, b) => (a.since < b.since ? -1 : 1))) {
      const visible = documents.filter((d) => d.userId === member.userId && readable(member, me, d.kind));
      const environmentIds = [...new Set(visible.map((d) => d.environmentId))];
      const linked = environmentIds.length === 0 ? [] : yield* links.listForUser({ userId: member.userId });
      const machines: Array<TeamMachine> = environmentIds.map((environmentId) => {
        const nowDoc = visible.find((d) => d.environmentId === environmentId && d.kind === "now");
        const latest = visible
          .filter((d) => d.environmentId === environmentId)
          .reduce<string | null>((acc, d) => (acc === null || d.updatedAt > acc ? d.updatedAt : acc), null);
        return {
          environmentId: environmentId as EnvironmentId,
          label: linked.find((l) => l.environmentId === environmentId)?.label ?? "Machine",
          ...(nowDoc && nowDoc.updatedAt >= freshFloor ? { now: nowDoc.body } : {}),
          lastPublished: latest,
        };
      });
      rows.push({
        userId: member.userId,
        name: member.name,
        role: member.role,
        founder: member.userId === team.founderUserId,
        since: member.since,
        machines,
      });
    }

    const leader = me.role === "leader";
    const requests = leader ? yield* store.listRequests(teamId) : [];
    const invites = leader ? yield* store.listInvites(teamId) : [];
    const pending = yield* store.listPendingForUser(teamId, userId);
    const memberName = (id: string) => members.find((m) => m.userId === id)?.name ?? id;

    return {
      teamId: team.teamId as TeamId,
      name: team.name,
      role: me.role,
      policy: { requests: team.policyRequests },
      me: { name: me.name, shares: normalizeShares(me.shares) },
      members: rows,
      requests: requests.map((r) => ({ userId: r.userId, name: r.name, at: r.createdAt })),
      invites: invites
        .filter((i) => i.revokedAt === null && i.expiresAt > now)
        .map((i) => ({ inviteId: i.inviteId, oneUse: i.oneUse, expiresAt: i.expiresAt, usedBy: i.usedByUserId })),
      grants: grants.filter((g) => g.userId === userId).map(grantOf),
      pending: pending.map((c) => ({
        commandId: c.commandId,
        fromUserId: c.fromUserId,
        fromName: memberName(c.fromUserId),
        environmentId: c.environmentId as EnvironmentId,
        threadId: c.threadId,
        action: c.action,
        ...(c.text === null ? {} : { text: c.text }),
        ...(c.project === null ? {} : { project: c.project }),
        expiresAt: c.expiresAt,
      })),
      grantsToMe: grants
        .filter(
          (g) =>
            g.userId !== userId &&
            (g.expiresAt === null || g.expiresAt > now) &&
            (g.audience === "team" ||
              (g.audience === "leaders" && leader) ||
              (Array.isArray(g.audience) && g.audience.includes(userId))),
        )
        .map((g) => ({
          grantorUserId: g.userId,
          environmentId: g.environmentId as EnvironmentId,
          threads: g.threads,
          capabilities: g.capabilities,
        })),
    } satisfies TeamSnapshot;
  });

  const assertEnvironmentUser = Effect.fn("relay.infinitus_team.assert_environment_user")(function* (input: {
    userId: string;
    environmentId: string;
    environmentPublicKey: string;
  }) {
    const link = yield* links.getForUser({ userId: input.userId, environmentId: input.environmentId });
    if (link === null || link.environmentPublicKey !== input.environmentPublicKey) {
      return yield* refuse("This environment is not linked to that user.");
    }
  });

  const finishCommand = (record: CommandRecord, now: string, ack: TeamCommandAckBody) =>
    store.updateCommand(record.commandId, {
      status: ack.outcome === "done" ? "done" : "refused",
      ack,
      answeredAt: now,
    });

  return InfinitusTeamService.of({
    listTeams: (userId) =>
      store.listTeamsForUser(userId).pipe(
        Effect.map((rows) => rows.map((r) => ({ teamId: r.teamId as TeamId, name: r.name, role: r.role }))),
      ),

    createTeam: Effect.fn("relay.infinitus_team.create")(function* (input) {
      const now = yield* nowIso;
      const teamId = yield* uuid;
      yield* store.createTeam({ teamId, name: input.name, founderUserId: input.userId, now });
      yield* store.upsertMember({
        teamId,
        userId: input.userId,
        role: "leader",
        name: input.memberName,
        shares: DEFAULT_TEAM_SHARES,
        since: now,
        now,
      });
      return yield* snapshot(teamId, input.userId);
    }),

    joinTeam: Effect.fn("relay.infinitus_team.join")(function* (input) {
      const now = yield* nowIso;
      const invite = yield* store.getInviteByHash(yield* hashToken(input.token.trim()));
      if (invite === null) return yield* refuse("This invite is not valid.");
      if (invite.revokedAt !== null) return yield* refuse("This invite was revoked.");
      if (invite.expiresAt <= now) return yield* refuse("This invite has expired.");
      if (invite.oneUse && invite.usedByUserId !== null) return yield* refuse("This invite was already used.");
      const team = yield* requireTeam(invite.teamId);
      const existing = yield* store.getMember(team.teamId, input.userId);
      if (existing) return { teamId: team.teamId as TeamId, status: "member" as const };
      if (team.policyRequests === "off") return yield* refuse("This team is not taking requests.");
      if (invite.oneUse) {
        yield* store.upsertMember({
          teamId: team.teamId,
          userId: input.userId,
          role: "member",
          name: input.memberName,
          shares: DEFAULT_TEAM_SHARES,
          since: now,
          now,
        });
        yield* store.markInviteUsed(invite.inviteId, input.userId);
        yield* store.deleteRequest(team.teamId, input.userId);
        return { teamId: team.teamId as TeamId, status: "member" as const };
      }
      yield* store.upsertRequest({
        teamId: team.teamId,
        userId: input.userId,
        name: input.memberName,
        inviteId: invite.inviteId,
        createdAt: now,
      });
      return { teamId: team.teamId as TeamId, status: "pending" as const };
    }),

    getTeam: (input) => snapshot(input.teamId, input.userId),

    updateMe: Effect.fn("relay.infinitus_team.update_me")(function* (input) {
      yield* requireMember(input.teamId, input.userId);
      const now = yield* nowIso;
      yield* store.updateMember(
        input.teamId,
        input.userId,
        {
          ...(input.name === undefined ? {} : { name: input.name }),
          ...(input.shares === undefined ? {} : { shares: normalizeShares(input.shares) }),
        },
        now,
      );
      return yield* snapshot(input.teamId, input.userId);
    }),

    leaveTeam: Effect.fn("relay.infinitus_team.leave")(function* (input) {
      const me = yield* requireMember(input.teamId, input.userId);
      const members = yield* store.listMembers(input.teamId);
      if (me.role === "leader" && leaderCount(members) === 1) {
        return yield* refuse("You are the last leader: promote someone before you leave.");
      }
      const gone = yield* store.deleteMember(input.teamId, input.userId);
      yield* deleteTranscriptObjects(gone);
    }),

    createInvite: Effect.fn("relay.infinitus_team.create_invite")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      const team = yield* requireTeam(input.teamId);
      if (team.policyRequests === "off") return yield* refuse("This team is not taking requests.");
      const now = yield* nowIso;
      const token = Encoding.encodeBase64Url(yield* crypto.randomBytes(32).pipe(Effect.orDie));
      const inviteId = yield* uuid;
      const expiresAt = plusSeconds(now, input.days * 86_400);
      yield* store.createInvite({
        inviteId,
        teamId: input.teamId,
        tokenHash: yield* hashToken(token),
        createdByUserId: input.userId,
        oneUse: input.oneUse,
        expiresAt,
        createdAt: now,
      });
      return { inviteId, token, expiresAt };
    }),

    revokeInvite: Effect.fn("relay.infinitus_team.revoke_invite")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      const revoked = yield* store.revokeInvite(input.teamId, input.inviteId, yield* nowIso);
      if (!revoked) return yield* refuse("That invite does not exist.");
    }),

    approveRequest: Effect.fn("relay.infinitus_team.approve")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      const request = yield* store.getRequest(input.teamId, input.targetUserId);
      if (request === null) return yield* refuse("That request is gone.");
      const now = yield* nowIso;
      yield* store.upsertMember({
        teamId: input.teamId,
        userId: request.userId,
        role: "member",
        name: request.name,
        shares: DEFAULT_TEAM_SHARES,
        since: now,
        now,
      });
      yield* store.deleteRequest(input.teamId, request.userId);
      return yield* snapshot(input.teamId, input.userId);
    }),

    declineRequest: Effect.fn("relay.infinitus_team.decline")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      yield* store.deleteRequest(input.teamId, input.targetUserId);
      return yield* snapshot(input.teamId, input.userId);
    }),

    promoteMember: Effect.fn("relay.infinitus_team.promote")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      yield* requireTarget(input.teamId, input.targetUserId);
      yield* store.updateMember(input.teamId, input.targetUserId, { role: "leader" }, yield* nowIso);
      return yield* snapshot(input.teamId, input.userId);
    }),

    demoteMember: Effect.fn("relay.infinitus_team.demote")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      const target = yield* requireTarget(input.teamId, input.targetUserId);
      const members = yield* store.listMembers(input.teamId);
      if (target.role === "leader" && leaderCount(members) === 1) {
        return yield* refuse("A team keeps at least one leader.");
      }
      yield* store.updateMember(input.teamId, input.targetUserId, { role: "member" }, yield* nowIso);
      return yield* snapshot(input.teamId, input.userId);
    }),

    removeMember: Effect.fn("relay.infinitus_team.remove")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      const team = yield* requireTeam(input.teamId);
      if (input.targetUserId === team.founderUserId) return yield* refuse("The founder cannot be removed.");
      if (input.targetUserId === input.userId) return yield* refuse("Leave the team instead of removing yourself.");
      yield* requireTarget(input.teamId, input.targetUserId);
      const gone = yield* store.deleteMember(input.teamId, input.targetUserId);
      yield* deleteTranscriptObjects(gone);
      return yield* snapshot(input.teamId, input.userId);
    }),

    updatePolicy: Effect.fn("relay.infinitus_team.update_policy")(function* (input) {
      yield* requireLeader(input.teamId, input.userId);
      yield* store.updateTeamPolicy(input.teamId, input.requests, yield* nowIso);
      return yield* snapshot(input.teamId, input.userId);
    }),

    listDocuments: Effect.fn("relay.infinitus_team.list_documents")(function* (input) {
      const me = yield* requireMember(input.teamId, input.userId);
      const members = yield* store.listMembers(input.teamId);
      const byUser = new Map(members.map((m) => [m.userId, m]));
      const rows = yield* store.listDocuments({
        teamId: input.teamId,
        ...(input.ownerUserId === undefined ? {} : { userId: input.ownerUserId }),
        ...(input.environmentId === undefined ? {} : { environmentId: input.environmentId }),
        ...(input.kind === undefined ? {} : { kind: input.kind }),
      });
      return rows
        .filter((d) => {
          const publisher = byUser.get(d.userId);
          return publisher !== undefined && readable(publisher, me, d.kind);
        })
        .map((d) => ({
          userId: d.userId,
          environmentId: d.environmentId as EnvironmentId,
          kind: d.kind,
          key: d.key,
          body: d.body,
          updatedAt: d.updatedAt,
        }));
    }),

    listTranscriptChunks: Effect.fn("relay.infinitus_team.list_transcript_chunks")(function* (input) {
      const me = yield* requireMember(input.teamId, input.userId);
      const owner = yield* requireTarget(input.teamId, input.ownerUserId);
      if (!readable(owner, me, "transcripts")) return yield* refuse("Transcripts are not shared with you.");
      const rows = yield* store.listTranscriptChunks({
        teamId: input.teamId,
        userId: input.ownerUserId,
        environmentId: input.environmentId,
        threadId: input.threadId,
      });
      return rows.map((r) => ({ seq: r.seq, rows: r.rows, bytes: r.bytes, createdAt: r.createdAt }));
    }),

    readTranscriptChunk: Effect.fn("relay.infinitus_team.read_transcript_chunk")(function* (input) {
      const me = yield* requireMember(input.teamId, input.userId);
      const owner = yield* requireTarget(input.teamId, input.ownerUserId);
      if (!readable(owner, me, "transcripts")) return yield* refuse("Transcripts are not shared with you.");
      const lines = yield* transcripts.get(
        objectKey({
          teamId: input.teamId,
          userId: input.ownerUserId,
          environmentId: input.environmentId,
          threadId: input.threadId,
          seq: input.seq,
        }),
      );
      if (lines === null) return yield* refuse("That transcript chunk is gone.");
      return lines;
    }),

    createGrant: Effect.fn("relay.infinitus_team.create_grant")(function* (input) {
      yield* requireMember(input.teamId, input.userId);
      const link = yield* links.getForUser({ userId: input.userId, environmentId: input.environmentId });
      if (link === null) return yield* refuse("That machine is not linked to you.");
      if (input.capabilities.length === 0) return yield* refuse("A grant needs at least one capability.");
      const now = yield* nowIso;
      const record: GrantRecord = {
        grantId: yield* uuid,
        teamId: input.teamId,
        userId: input.userId,
        environmentId: input.environmentId,
        audience: input.audience,
        threads: input.threads,
        capabilities: input.capabilities,
        preauthorized: (input.preauthorized ?? []).filter((c) => input.capabilities.includes(c)),
        expiresAt: input.expiresInSeconds === undefined ? null : plusSeconds(now, input.expiresInSeconds),
        createdAt: now,
      };
      yield* store.createGrant(record);
      return grantOf(record);
    }),

    revokeGrant: Effect.fn("relay.infinitus_team.revoke_grant")(function* (input) {
      yield* requireMember(input.teamId, input.userId);
      const removed = yield* store.deleteGrant(input.teamId, input.grantId, input.userId);
      if (!removed) return yield* refuse("That grant does not exist.");
    }),

    createCommand: Effect.fn("relay.infinitus_team.create_command")(function* (input) {
      const me = yield* requireMember(input.teamId, input.userId);
      yield* requireTarget(input.teamId, input.toUserId);
      if (input.action !== "new" && input.threadId === "-") return yield* refuse("Name a thread.");
      if (input.action === "new" && input.threadId !== "-") return yield* refuse("A new thread targets the machine, not a thread.");
      if ((input.action === "send" || input.action === "new") && !input.text?.trim()) {
        return yield* refuse("Say what to send.");
      }
      const now = yield* nowIso;
      const grants = yield* store.listGrantsForTeam(input.teamId);
      const grant = grants.find(
        (g) =>
          g.userId === input.toUserId &&
          g.environmentId === input.environmentId &&
          teamGrantAllows(grantOf(g), {
            fromUserId: input.userId,
            fromRole: me.role,
            threadId: input.threadId,
            action: input.action,
            nowIso: now,
          }),
      );
      if (grant === undefined) return yield* refuse("They have not let you do that.");
      const pending = teamCommandNeedsTap(grantOf(grant), input.action);
      const record: CommandRecord = {
        commandId: yield* uuid,
        teamId: input.teamId,
        fromUserId: input.userId,
        toUserId: input.toUserId,
        environmentId: input.environmentId,
        grantId: grant.grantId,
        threadId: input.threadId,
        action: input.action,
        text: input.text ?? null,
        project: input.project ?? null,
        status: pending ? "pending" : "queued",
        ack: null,
        createdAt: now,
        expiresAt: plusSeconds(now, pending ? PENDING_TTL_SECONDS : QUEUED_TTL_SECONDS),
        answeredAt: null,
      };
      yield* store.createCommand(record);
      return commandState(record);
    }),

    listPendingCommands: Effect.fn("relay.infinitus_team.list_pending")(function* (input) {
      yield* requireMember(input.teamId, input.userId);
      const members = yield* store.listMembers(input.teamId);
      const rows = yield* store.listPendingForUser(input.teamId, input.userId);
      return rows.map((c) => ({
        commandId: c.commandId,
        fromUserId: c.fromUserId,
        fromName: members.find((m) => m.userId === c.fromUserId)?.name ?? c.fromUserId,
        environmentId: c.environmentId as EnvironmentId,
        threadId: c.threadId,
        action: c.action,
        ...(c.text === null ? {} : { text: c.text }),
        ...(c.project === null ? {} : { project: c.project }),
        expiresAt: c.expiresAt,
      }));
    }),

    getCommand: Effect.fn("relay.infinitus_team.get_command")(function* (input) {
      const command = yield* store.getCommand(input.commandId);
      if (command === null || command.teamId !== input.teamId) return yield* refuse("That command does not exist.");
      if (command.fromUserId !== input.userId && command.toUserId !== input.userId) {
        return yield* refuse("That command is not yours.");
      }
      return commandState(command);
    }),

    allowCommand: Effect.fn("relay.infinitus_team.allow_command")(function* (input) {
      const command = yield* store.getCommand(input.commandId);
      if (command === null || command.teamId !== input.teamId || command.toUserId !== input.userId) {
        return yield* refuse("That command is not waiting for you.");
      }
      if (command.status !== "pending") return yield* refuse("That command is no longer waiting.");
      const now = yield* nowIso;
      yield* store.updateCommand(command.commandId, {
        status: "queued",
        expiresAt: plusSeconds(now, QUEUED_TTL_SECONDS),
      });
      return commandState({ ...command, status: "queued" });
    }),

    denyCommand: Effect.fn("relay.infinitus_team.deny_command")(function* (input) {
      const command = yield* store.getCommand(input.commandId);
      if (command === null || command.teamId !== input.teamId || command.toUserId !== input.userId) {
        return yield* refuse("That command is not waiting for you.");
      }
      if (command.status !== "pending") return yield* refuse("That command is no longer waiting.");
      const now = yield* nowIso;
      const ack: TeamCommandAckBody = { outcome: "refused", detail: "Denied by the grantor." };
      yield* store.updateCommand(command.commandId, { status: "denied", ack, answeredAt: now });
      return commandState({ ...command, status: "denied", ack });
    }),

    memberships: Effect.fn("relay.infinitus_team.memberships")(function* (input) {
      yield* assertEnvironmentUser(input);
      const teams = yield* store.listTeamsForUser(input.userId);
      const out: Array<TeamEnvironmentMemberships["teams"][number]> = [];
      for (const team of teams) {
        const member = yield* store.getMember(team.teamId, input.userId);
        if (member === null) continue;
        const grants = yield* store.listGrantsForTeam(team.teamId);
        const chunks = yield* store.listTranscriptsForMember(team.teamId, input.userId);
        const cursors = new Map<string, { rows: number; nextSeq: number }>();
        for (const chunk of chunks) {
          if (chunk.environmentId !== input.environmentId) continue;
          const cursor = cursors.get(chunk.threadId) ?? { rows: 0, nextSeq: 0 };
          cursors.set(chunk.threadId, {
            rows: cursor.rows + chunk.rows,
            nextSeq: Math.max(cursor.nextSeq, chunk.seq + 1),
          });
        }
        out.push({
          teamId: team.teamId as TeamId,
          shares: normalizeShares(member.shares),
          grants: grants
            .filter((g) => g.userId === input.userId && g.environmentId === input.environmentId)
            .map(grantOf),
          transcripts: [...cursors].map(([threadId, c]) => ({ threadId, rows: c.rows, nextSeq: c.nextSeq })),
        });
      }
      return { userId: input.userId, teams: out };
    }),

    publishDocuments: Effect.fn("relay.infinitus_team.publish_documents")(function* (input) {
      yield* assertEnvironmentUser(input);
      const member = yield* requireMember(input.teamId, input.userId);
      const shares = normalizeShares(member.shares);
      const allowed = input.documents.filter((d) => d.kind !== "transcripts" && shares[d.kind] !== "off");
      if (allowed.length === 0) return;
      yield* store.upsertDocuments({
        teamId: input.teamId,
        userId: input.userId,
        environmentId: input.environmentId,
        documents: allowed,
        now: yield* nowIso,
      });
    }),

    publishTranscript: Effect.fn("relay.infinitus_team.publish_transcript")(function* (input) {
      yield* assertEnvironmentUser(input);
      const member = yield* requireMember(input.teamId, input.userId);
      if (normalizeShares(member.shares).transcripts === "off") return yield* refuse("Transcripts are not shared.");
      const existing = yield* store.listTranscriptChunks({
        teamId: input.teamId,
        userId: input.userId,
        environmentId: input.environmentId,
        threadId: input.threadId,
      });
      const nextSeq = existing.reduce((acc, c) => Math.max(acc, c.seq + 1), 0);
      if (input.seq !== nextSeq) return yield* refuse(`The next chunk is ${nextSeq}.`);
      const key = objectKey({
        teamId: input.teamId,
        userId: input.userId,
        environmentId: input.environmentId,
        threadId: input.threadId,
        seq: input.seq,
      });
      yield* transcripts.put(key, input.lines);
      yield* store.insertTranscriptChunk({
        teamId: input.teamId,
        userId: input.userId,
        environmentId: input.environmentId,
        threadId: input.threadId,
        seq: input.seq,
        rows: input.rows,
        bytes: new TextEncoder().encode(input.lines).byteLength,
        objectKey: key,
        createdAt: yield* nowIso,
      });
    }),

    pollCommands: Effect.fn("relay.infinitus_team.poll_commands")(function* (input) {
      yield* assertEnvironmentUser(input);
      const now = yield* nowIso;
      const taken = yield* store.takeQueuedForEnvironment(input.environmentId, now);
      const out: Array<TeamQueuedCommand> = [];
      for (const command of taken) {
        if (command.toUserId !== input.userId) continue;
        const grant = yield* store.getGrant(command.grantId);
        const from = yield* store.getMember(command.teamId, command.fromUserId);
        const allowed =
          grant !== null &&
          from !== null &&
          teamGrantAllows(grantOf(grant), {
            fromUserId: command.fromUserId,
            fromRole: from.role,
            threadId: command.threadId,
            action: command.action,
            nowIso: now,
          });
        if (!allowed) {
          yield* finishCommand(command, now, { outcome: "noGrant", detail: "The grant is gone." });
          continue;
        }
        out.push({
          commandId: command.commandId,
          teamId: command.teamId as TeamId,
          fromUserId: command.fromUserId,
          threadId: command.threadId,
          action: command.action,
          ...(command.text === null ? {} : { text: command.text }),
          ...(command.project === null ? {} : { project: command.project }),
          expiresAt: command.expiresAt,
          grant: grantOf(grant),
        });
      }
      return out;
    }),

    ackCommand: Effect.fn("relay.infinitus_team.ack_command")(function* (input) {
      yield* assertEnvironmentUser(input);
      const command = yield* store.getCommand(input.commandId);
      if (command === null || command.environmentId !== input.environmentId || command.toUserId !== input.userId) {
        return yield* refuse("That command is not this machine's.");
      }
      const now = yield* nowIso;
      if (input.outcome === "pending") {
        yield* store.updateCommand(command.commandId, {
          status: "pending",
          expiresAt: plusSeconds(now, PENDING_TTL_SECONDS),
        });
        return;
      }
      yield* finishCommand(command, now, {
        outcome: input.outcome,
        ...(input.detail === undefined ? {} : { detail: input.detail }),
        ...(input.result === undefined ? {} : { result: input.result }),
      });
    }),

    prune: Effect.gen(function* () {
      const now = yield* nowIso;
      yield* store.expireCommands(now);
      const floor = plusSeconds(now, -TRANSCRIPT_RETENTION_DAYS * 86_400);
      const aged = yield* store.listTranscriptsOlderThan(floor);
      const over: Array<TranscriptRecord> = [];
      for (const total of yield* store.listTranscriptBytesByMember()) {
        if (total.bytes <= TRANSCRIPT_MEMBER_BYTES) continue;
        let excess = total.bytes - TRANSCRIPT_MEMBER_BYTES;
        for (const chunk of yield* store.listTranscriptsForMember(total.teamId, total.userId)) {
          if (excess <= 0) break;
          over.push(chunk);
          excess -= chunk.bytes;
        }
      }
      const seen = new Set<string>();
      const doomed = [...aged, ...over].filter((r) => (seen.has(r.objectKey) ? false : (seen.add(r.objectKey), true)));
      if (doomed.length > 0) {
        yield* transcripts.delete(doomed.map((r) => r.objectKey));
        yield* store.deleteTranscriptChunks(doomed);
      }
      return { transcriptsDeleted: doomed.length };
    }).pipe(Effect.withSpan("relay.infinitus_team.prune")),
  });
});

export const layer = Layer.effect(InfinitusTeamService, make);
