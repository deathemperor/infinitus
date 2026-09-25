import type {
  TeamAudience,
  TeamCapability,
  TeamCommandAckBody,
  TeamCommandStatus,
  TeamKind,
  TeamPolicyRequests,
  TeamRole,
  TeamShares,
  TeamThreadsSelector,
} from "@infinitus/contracts/relayInfinitusTeam";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { and, desc, eq, inArray, lt, sql } from "drizzle-orm";

import * as RelayDb from "../db.ts";
import {
  infinitusTeamCommands,
  infinitusTeamDocuments,
  infinitusTeamGrants,
  infinitusTeamInvites,
  infinitusTeamMembers,
  infinitusTeamRequests,
  infinitusTeamTranscripts,
  infinitusTeams,
} from "./schema.ts";

/**
 * Team on Infinitus Connect (#1592): the rows, nothing else. Every rule (who
 * may do what, when a join is a request) lives in `InfinitusTeamService`; this
 * layer only reads and writes, so the service's tests run on `inMemoryStore`
 * and this file's tests check the queries hit the right tables.
 */

export interface TeamRecord {
  readonly teamId: string;
  readonly name: string;
  readonly founderUserId: string;
  readonly policyRequests: TeamPolicyRequests;
  readonly createdAt: string;
}
export interface MemberRecord {
  readonly teamId: string;
  readonly userId: string;
  readonly role: TeamRole;
  readonly name: string;
  readonly shares: TeamShares;
  readonly since: string;
}
export interface InviteRecord {
  readonly inviteId: string;
  readonly teamId: string;
  readonly tokenHash: string;
  readonly createdByUserId: string;
  readonly oneUse: boolean;
  readonly usedByUserId: string | null;
  readonly expiresAt: string;
  readonly revokedAt: string | null;
  readonly createdAt: string;
}
export interface RequestRecord {
  readonly teamId: string;
  readonly userId: string;
  readonly name: string;
  readonly inviteId: string;
  readonly createdAt: string;
}
export interface DocumentRecord {
  readonly teamId: string;
  readonly userId: string;
  readonly environmentId: string;
  readonly kind: TeamKind;
  readonly key: string;
  readonly body: unknown;
  readonly updatedAt: string;
}
export interface TranscriptRecord {
  readonly teamId: string;
  readonly userId: string;
  readonly environmentId: string;
  readonly threadId: string;
  readonly seq: number;
  readonly rows: number;
  readonly bytes: number;
  readonly objectKey: string;
  readonly createdAt: string;
}
export interface TranscriptKey {
  readonly teamId: string;
  readonly userId: string;
  readonly environmentId: string;
  readonly threadId: string;
  readonly seq: number;
}
export interface GrantRecord {
  readonly grantId: string;
  readonly teamId: string;
  readonly userId: string;
  readonly environmentId: string;
  readonly audience: TeamAudience;
  readonly threads: TeamThreadsSelector;
  readonly capabilities: ReadonlyArray<TeamCapability>;
  readonly preauthorized: ReadonlyArray<TeamCapability>;
  readonly expiresAt: string | null;
  readonly createdAt: string;
}
export interface CommandRecord {
  readonly commandId: string;
  readonly teamId: string;
  readonly fromUserId: string;
  readonly toUserId: string;
  readonly environmentId: string;
  readonly grantId: string;
  readonly threadId: string;
  readonly action: TeamCapability;
  readonly text: string | null;
  readonly project: string | null;
  readonly status: TeamCommandStatus;
  readonly ack: TeamCommandAckBody | null;
  readonly createdAt: string;
  readonly expiresAt: string;
  readonly answeredAt: string | null;
}

export class InfinitusTeamPersistenceError extends Schema.TaggedError<InfinitusTeamPersistenceError>()(
  "InfinitusTeamPersistenceError",
  { op: Schema.String, cause: Schema.Defect() },
) {
  override get message(): string {
    return `Infinitus Team query '${this.op}' failed`;
  }
}

type E<A> = Effect.Effect<A, InfinitusTeamPersistenceError>;

export class InfinitusTeamStore extends Context.Service<
  InfinitusTeamStore,
  {
    readonly getTeam: (teamId: string) => E<TeamRecord | null>;
    readonly createTeam: (input: {
      readonly teamId: string;
      readonly name: string;
      readonly founderUserId: string;
      readonly now: string;
    }) => E<void>;
    readonly updateTeamPolicy: (teamId: string, requests: TeamPolicyRequests, now: string) => E<void>;
    readonly listTeamsForUser: (userId: string) => E<ReadonlyArray<{ teamId: string; name: string; role: TeamRole }>>;
    readonly listMembers: (teamId: string) => E<ReadonlyArray<MemberRecord>>;
    readonly getMember: (teamId: string, userId: string) => E<MemberRecord | null>;
    readonly upsertMember: (input: MemberRecord & { readonly now: string }) => E<void>;
    readonly updateMember: (
      teamId: string,
      userId: string,
      patch: { readonly name?: string; readonly shares?: TeamShares; readonly role?: TeamRole },
      now: string,
    ) => E<void>;
    /** The member and everything they published, granted or queued. */
    readonly deleteMember: (teamId: string, userId: string) => E<ReadonlyArray<TranscriptRecord>>;
    readonly createInvite: (input: Omit<InviteRecord, "usedByUserId" | "revokedAt">) => E<void>;
    readonly getInviteByHash: (tokenHash: string) => E<InviteRecord | null>;
    readonly markInviteUsed: (inviteId: string, userId: string) => E<void>;
    readonly revokeInvite: (teamId: string, inviteId: string, now: string) => E<boolean>;
    readonly listInvites: (teamId: string) => E<ReadonlyArray<InviteRecord>>;
    readonly upsertRequest: (input: RequestRecord) => E<void>;
    readonly getRequest: (teamId: string, userId: string) => E<RequestRecord | null>;
    readonly listRequests: (teamId: string) => E<ReadonlyArray<RequestRecord>>;
    readonly deleteRequest: (teamId: string, userId: string) => E<void>;
    readonly upsertDocuments: (input: {
      readonly teamId: string;
      readonly userId: string;
      readonly environmentId: string;
      readonly documents: ReadonlyArray<{ readonly kind: TeamKind; readonly key: string; readonly body: unknown }>;
      readonly now: string;
    }) => E<void>;
    readonly listDocuments: (input: {
      readonly teamId: string;
      readonly userId?: string;
      readonly environmentId?: string;
      readonly kind?: TeamKind;
    }) => E<ReadonlyArray<DocumentRecord>>;
    readonly insertTranscriptChunk: (input: TranscriptRecord) => E<void>;
    readonly listTranscriptChunks: (input: {
      readonly teamId: string;
      readonly userId: string;
      readonly environmentId: string;
      readonly threadId: string;
    }) => E<ReadonlyArray<TranscriptRecord>>;
    readonly listTranscriptsForMember: (teamId: string, userId: string) => E<ReadonlyArray<TranscriptRecord>>;
    readonly listTranscriptsOlderThan: (createdBefore: string) => E<ReadonlyArray<TranscriptRecord>>;
    readonly listTranscriptBytesByMember: () => E<ReadonlyArray<{ teamId: string; userId: string; bytes: number }>>;
    readonly deleteTranscriptChunks: (keys: ReadonlyArray<TranscriptKey>) => E<void>;
    readonly createGrant: (input: GrantRecord) => E<void>;
    readonly getGrant: (grantId: string) => E<GrantRecord | null>;
    readonly listGrantsForTeam: (teamId: string) => E<ReadonlyArray<GrantRecord>>;
    readonly deleteGrant: (teamId: string, grantId: string, userId: string) => E<boolean>;
    readonly createCommand: (input: CommandRecord) => E<void>;
    readonly getCommand: (commandId: string) => E<CommandRecord | null>;
    /** Flips the environment's queued, unexpired commands to running and returns them. */
    readonly takeQueuedForEnvironment: (environmentId: string, now: string) => E<ReadonlyArray<CommandRecord>>;
    readonly listPendingForUser: (teamId: string, toUserId: string) => E<ReadonlyArray<CommandRecord>>;
    readonly updateCommand: (
      commandId: string,
      patch: {
        readonly status: TeamCommandStatus;
        readonly ack?: TeamCommandAckBody | null;
        readonly expiresAt?: string;
        readonly answeredAt?: string | null;
      },
    ) => E<void>;
    readonly expireCommands: (now: string) => E<void>;
  }
>()("infinitus-relay/infinitusTeam/InfinitusTeamStore") {}

const failing = (op: string) => (cause: unknown) => new InfinitusTeamPersistenceError({ op, cause });

const memberRow = (row: typeof infinitusTeamMembers.$inferSelect): MemberRecord => ({
  teamId: row.teamId,
  userId: row.userId,
  role: row.role as TeamRole,
  name: row.name,
  shares: row.sharesJson as TeamShares,
  since: row.since,
});
const inviteRow = (row: typeof infinitusTeamInvites.$inferSelect): InviteRecord => ({
  inviteId: row.inviteId,
  teamId: row.teamId,
  tokenHash: row.tokenHash,
  createdByUserId: row.createdByUserId,
  oneUse: row.oneUse,
  usedByUserId: row.usedByUserId,
  expiresAt: row.expiresAt,
  revokedAt: row.revokedAt,
  createdAt: row.createdAt,
});
const documentRow = (row: typeof infinitusTeamDocuments.$inferSelect): DocumentRecord => ({
  teamId: row.teamId,
  userId: row.userId,
  environmentId: row.environmentId,
  kind: row.kind as TeamKind,
  key: row.key,
  body: row.bodyJson,
  updatedAt: row.updatedAt,
});
const transcriptRow = (row: typeof infinitusTeamTranscripts.$inferSelect): TranscriptRecord => ({
  teamId: row.teamId,
  userId: row.userId,
  environmentId: row.environmentId,
  threadId: row.threadId,
  seq: row.seq,
  rows: row.rows,
  bytes: row.bytes,
  objectKey: row.objectKey,
  createdAt: row.createdAt,
});
const grantRow = (row: typeof infinitusTeamGrants.$inferSelect): GrantRecord => ({
  grantId: row.grantId,
  teamId: row.teamId,
  userId: row.userId,
  environmentId: row.environmentId,
  audience: row.audienceJson as TeamAudience,
  threads: row.threadsJson as TeamThreadsSelector,
  capabilities: row.capabilitiesJson as ReadonlyArray<TeamCapability>,
  preauthorized: row.preauthorizedJson as ReadonlyArray<TeamCapability>,
  expiresAt: row.expiresAt,
  createdAt: row.createdAt,
});
const commandRow = (row: typeof infinitusTeamCommands.$inferSelect): CommandRecord => ({
  commandId: row.commandId,
  teamId: row.teamId,
  fromUserId: row.fromUserId,
  toUserId: row.toUserId,
  environmentId: row.environmentId,
  grantId: row.grantId,
  threadId: row.threadId,
  action: row.action as TeamCapability,
  text: row.text,
  project: row.project,
  status: row.status as TeamCommandStatus,
  ack: (row.ackJson as TeamCommandAckBody | null) ?? null,
  createdAt: row.createdAt,
  expiresAt: row.expiresAt,
  answeredAt: row.answeredAt,
});

const make = Effect.gen(function* () {
  const db = yield* RelayDb.RelayDb;

  const memberFilter = (teamId: string, userId: string) =>
    and(eq(infinitusTeamMembers.teamId, teamId), eq(infinitusTeamMembers.userId, userId));

  return InfinitusTeamStore.of({
    getTeam: Effect.fn("relay.infinitus_team.get_team")(function* (teamId) {
      const rows = yield* db
        .select()
        .from(infinitusTeams)
        .where(eq(infinitusTeams.teamId, teamId))
        .limit(1)
        .pipe(Effect.mapError(failing("get_team")));
      const row = rows[0];
      return row
        ? {
            teamId: row.teamId,
            name: row.name,
            founderUserId: row.founderUserId,
            policyRequests: row.policyRequests as TeamPolicyRequests,
            createdAt: row.createdAt,
          }
        : null;
    }),
    createTeam: Effect.fn("relay.infinitus_team.create_team")(function* (input) {
      yield* db
        .insert(infinitusTeams)
        .values({
          teamId: input.teamId,
          name: input.name,
          founderUserId: input.founderUserId,
          policyRequests: "code",
          createdAt: input.now,
          updatedAt: input.now,
        })
        .pipe(Effect.mapError(failing("create_team")));
    }),
    updateTeamPolicy: Effect.fn("relay.infinitus_team.update_policy")(function* (teamId, requests, now) {
      yield* db
        .update(infinitusTeams)
        .set({ policyRequests: requests, updatedAt: now })
        .where(eq(infinitusTeams.teamId, teamId))
        .pipe(Effect.mapError(failing("update_policy")));
    }),
    listTeamsForUser: Effect.fn("relay.infinitus_team.list_teams_for_user")(function* (userId) {
      const rows = yield* db
        .select({ teamId: infinitusTeams.teamId, name: infinitusTeams.name, role: infinitusTeamMembers.role })
        .from(infinitusTeamMembers)
        .innerJoin(infinitusTeams, eq(infinitusTeams.teamId, infinitusTeamMembers.teamId))
        .where(eq(infinitusTeamMembers.userId, userId))
        .pipe(Effect.mapError(failing("list_teams_for_user")));
      return rows.map((row) => ({ teamId: row.teamId, name: row.name, role: row.role as TeamRole }));
    }),
    listMembers: Effect.fn("relay.infinitus_team.list_members")(function* (teamId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamMembers)
        .where(eq(infinitusTeamMembers.teamId, teamId))
        .pipe(Effect.mapError(failing("list_members")));
      return rows.map(memberRow);
    }),
    getMember: Effect.fn("relay.infinitus_team.get_member")(function* (teamId, userId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamMembers)
        .where(memberFilter(teamId, userId))
        .limit(1)
        .pipe(Effect.mapError(failing("get_member")));
      return rows[0] ? memberRow(rows[0]) : null;
    }),
    upsertMember: Effect.fn("relay.infinitus_team.upsert_member")(function* (input) {
      yield* db
        .insert(infinitusTeamMembers)
        .values({
          teamId: input.teamId,
          userId: input.userId,
          role: input.role,
          name: input.name,
          sharesJson: input.shares,
          since: input.since,
          updatedAt: input.now,
        })
        .onConflictDoUpdate({
          target: [infinitusTeamMembers.teamId, infinitusTeamMembers.userId],
          set: { role: input.role, name: input.name, sharesJson: input.shares, updatedAt: input.now },
        })
        .pipe(Effect.mapError(failing("upsert_member")));
    }),
    updateMember: Effect.fn("relay.infinitus_team.update_member")(function* (teamId, userId, patch, now) {
      yield* db
        .update(infinitusTeamMembers)
        .set({
          ...(patch.name === undefined ? {} : { name: patch.name }),
          ...(patch.shares === undefined ? {} : { sharesJson: patch.shares }),
          ...(patch.role === undefined ? {} : { role: patch.role }),
          updatedAt: now,
        })
        .where(memberFilter(teamId, userId))
        .pipe(Effect.mapError(failing("update_member")));
    }),
    deleteMember: Effect.fn("relay.infinitus_team.delete_member")(function* (teamId, userId) {
      const fail = failing("delete_member");
      const transcripts = yield* db
        .select()
        .from(infinitusTeamTranscripts)
        .where(and(eq(infinitusTeamTranscripts.teamId, teamId), eq(infinitusTeamTranscripts.userId, userId)))
        .pipe(Effect.mapError(fail));
      yield* db
        .delete(infinitusTeamTranscripts)
        .where(and(eq(infinitusTeamTranscripts.teamId, teamId), eq(infinitusTeamTranscripts.userId, userId)))
        .pipe(Effect.mapError(fail));
      yield* db
        .delete(infinitusTeamDocuments)
        .where(and(eq(infinitusTeamDocuments.teamId, teamId), eq(infinitusTeamDocuments.userId, userId)))
        .pipe(Effect.mapError(fail));
      yield* db
        .delete(infinitusTeamGrants)
        .where(and(eq(infinitusTeamGrants.teamId, teamId), eq(infinitusTeamGrants.userId, userId)))
        .pipe(Effect.mapError(fail));
      yield* db
        .delete(infinitusTeamCommands)
        .where(
          and(
            eq(infinitusTeamCommands.teamId, teamId),
            sql`(${infinitusTeamCommands.fromUserId} = ${userId} or ${infinitusTeamCommands.toUserId} = ${userId})`,
          ),
        )
        .pipe(Effect.mapError(fail));
      yield* db
        .delete(infinitusTeamRequests)
        .where(and(eq(infinitusTeamRequests.teamId, teamId), eq(infinitusTeamRequests.userId, userId)))
        .pipe(Effect.mapError(fail));
      yield* db.delete(infinitusTeamMembers).where(memberFilter(teamId, userId)).pipe(Effect.mapError(fail));
      return transcripts.map(transcriptRow);
    }),
    createInvite: Effect.fn("relay.infinitus_team.create_invite")(function* (input) {
      yield* db
        .insert(infinitusTeamInvites)
        .values({
          inviteId: input.inviteId,
          teamId: input.teamId,
          tokenHash: input.tokenHash,
          createdByUserId: input.createdByUserId,
          oneUse: input.oneUse,
          usedByUserId: null,
          expiresAt: input.expiresAt,
          revokedAt: null,
          createdAt: input.createdAt,
        })
        .pipe(Effect.mapError(failing("create_invite")));
    }),
    getInviteByHash: Effect.fn("relay.infinitus_team.get_invite")(function* (tokenHash) {
      const rows = yield* db
        .select()
        .from(infinitusTeamInvites)
        .where(eq(infinitusTeamInvites.tokenHash, tokenHash))
        .limit(1)
        .pipe(Effect.mapError(failing("get_invite")));
      return rows[0] ? inviteRow(rows[0]) : null;
    }),
    markInviteUsed: Effect.fn("relay.infinitus_team.mark_invite_used")(function* (inviteId, userId) {
      yield* db
        .update(infinitusTeamInvites)
        .set({ usedByUserId: userId })
        .where(eq(infinitusTeamInvites.inviteId, inviteId))
        .pipe(Effect.mapError(failing("mark_invite_used")));
    }),
    revokeInvite: Effect.fn("relay.infinitus_team.revoke_invite")(function* (teamId, inviteId, now) {
      const rows = yield* db
        .update(infinitusTeamInvites)
        .set({ revokedAt: now })
        .where(and(eq(infinitusTeamInvites.teamId, teamId), eq(infinitusTeamInvites.inviteId, inviteId)))
        .returning({ inviteId: infinitusTeamInvites.inviteId })
        .pipe(Effect.mapError(failing("revoke_invite")));
      return rows.length > 0;
    }),
    listInvites: Effect.fn("relay.infinitus_team.list_invites")(function* (teamId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamInvites)
        .where(eq(infinitusTeamInvites.teamId, teamId))
        .orderBy(desc(infinitusTeamInvites.createdAt))
        .pipe(Effect.mapError(failing("list_invites")));
      return rows.map(inviteRow);
    }),
    upsertRequest: Effect.fn("relay.infinitus_team.upsert_request")(function* (input) {
      yield* db
        .insert(infinitusTeamRequests)
        .values({
          teamId: input.teamId,
          userId: input.userId,
          name: input.name,
          inviteId: input.inviteId,
          createdAt: input.createdAt,
        })
        .onConflictDoUpdate({
          target: [infinitusTeamRequests.teamId, infinitusTeamRequests.userId],
          set: { name: input.name, inviteId: input.inviteId, createdAt: input.createdAt },
        })
        .pipe(Effect.mapError(failing("upsert_request")));
    }),
    getRequest: Effect.fn("relay.infinitus_team.get_request")(function* (teamId, userId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamRequests)
        .where(and(eq(infinitusTeamRequests.teamId, teamId), eq(infinitusTeamRequests.userId, userId)))
        .limit(1)
        .pipe(Effect.mapError(failing("get_request")));
      return rows[0] ?? null;
    }),
    listRequests: Effect.fn("relay.infinitus_team.list_requests")(function* (teamId) {
      return yield* db
        .select()
        .from(infinitusTeamRequests)
        .where(eq(infinitusTeamRequests.teamId, teamId))
        .orderBy(infinitusTeamRequests.createdAt)
        .pipe(Effect.mapError(failing("list_requests")));
    }),
    deleteRequest: Effect.fn("relay.infinitus_team.delete_request")(function* (teamId, userId) {
      yield* db
        .delete(infinitusTeamRequests)
        .where(and(eq(infinitusTeamRequests.teamId, teamId), eq(infinitusTeamRequests.userId, userId)))
        .pipe(Effect.mapError(failing("delete_request")));
    }),
    upsertDocuments: Effect.fn("relay.infinitus_team.upsert_documents")(function* (input) {
      for (const document of input.documents) {
        yield* db
          .insert(infinitusTeamDocuments)
          .values({
            teamId: input.teamId,
            userId: input.userId,
            environmentId: input.environmentId,
            kind: document.kind,
            key: document.key,
            bodyJson: document.body,
            updatedAt: input.now,
          })
          .onConflictDoUpdate({
            target: [
              infinitusTeamDocuments.teamId,
              infinitusTeamDocuments.userId,
              infinitusTeamDocuments.environmentId,
              infinitusTeamDocuments.kind,
              infinitusTeamDocuments.key,
            ],
            set: { bodyJson: document.body, updatedAt: input.now },
          })
          .pipe(Effect.mapError(failing("upsert_documents")));
      }
    }),
    listDocuments: Effect.fn("relay.infinitus_team.list_documents")(function* (input) {
      const rows = yield* db
        .select()
        .from(infinitusTeamDocuments)
        .where(
          and(
            eq(infinitusTeamDocuments.teamId, input.teamId),
            ...(input.userId === undefined ? [] : [eq(infinitusTeamDocuments.userId, input.userId)]),
            ...(input.environmentId === undefined
              ? []
              : [eq(infinitusTeamDocuments.environmentId, input.environmentId)]),
            ...(input.kind === undefined ? [] : [eq(infinitusTeamDocuments.kind, input.kind)]),
          ),
        )
        .pipe(Effect.mapError(failing("list_documents")));
      return rows.map(documentRow);
    }),
    insertTranscriptChunk: Effect.fn("relay.infinitus_team.insert_transcript")(function* (input) {
      yield* db
        .insert(infinitusTeamTranscripts)
        .values({
          teamId: input.teamId,
          userId: input.userId,
          environmentId: input.environmentId,
          threadId: input.threadId,
          seq: input.seq,
          rows: input.rows,
          bytes: input.bytes,
          objectKey: input.objectKey,
          createdAt: input.createdAt,
        })
        .pipe(Effect.mapError(failing("insert_transcript")));
    }),
    listTranscriptChunks: Effect.fn("relay.infinitus_team.list_transcript_chunks")(function* (input) {
      const rows = yield* db
        .select()
        .from(infinitusTeamTranscripts)
        .where(
          and(
            eq(infinitusTeamTranscripts.teamId, input.teamId),
            eq(infinitusTeamTranscripts.userId, input.userId),
            eq(infinitusTeamTranscripts.environmentId, input.environmentId),
            eq(infinitusTeamTranscripts.threadId, input.threadId),
          ),
        )
        .orderBy(infinitusTeamTranscripts.seq)
        .pipe(Effect.mapError(failing("list_transcript_chunks")));
      return rows.map(transcriptRow);
    }),
    listTranscriptsForMember: Effect.fn("relay.infinitus_team.list_transcripts_for_member")(function* (
      teamId,
      userId,
    ) {
      const rows = yield* db
        .select()
        .from(infinitusTeamTranscripts)
        .where(and(eq(infinitusTeamTranscripts.teamId, teamId), eq(infinitusTeamTranscripts.userId, userId)))
        .orderBy(infinitusTeamTranscripts.createdAt)
        .pipe(Effect.mapError(failing("list_transcripts_for_member")));
      return rows.map(transcriptRow);
    }),
    listTranscriptsOlderThan: Effect.fn("relay.infinitus_team.list_transcripts_older_than")(function* (createdBefore) {
      const rows = yield* db
        .select()
        .from(infinitusTeamTranscripts)
        .where(lt(infinitusTeamTranscripts.createdAt, createdBefore))
        .pipe(Effect.mapError(failing("list_transcripts_older_than")));
      return rows.map(transcriptRow);
    }),
    listTranscriptBytesByMember: Effect.fn("relay.infinitus_team.list_transcript_bytes")(function* () {
      const rows = yield* db
        .select({
          teamId: infinitusTeamTranscripts.teamId,
          userId: infinitusTeamTranscripts.userId,
          bytes: sql<number>`coalesce(sum(${infinitusTeamTranscripts.bytes}), 0)::int`,
        })
        .from(infinitusTeamTranscripts)
        .groupBy(infinitusTeamTranscripts.teamId, infinitusTeamTranscripts.userId)
        .pipe(Effect.mapError(failing("list_transcript_bytes")));
      return rows.map((row) => ({ teamId: row.teamId, userId: row.userId, bytes: Number(row.bytes) }));
    }),
    deleteTranscriptChunks: Effect.fn("relay.infinitus_team.delete_transcripts")(function* (keys) {
      for (const key of keys) {
        yield* db
          .delete(infinitusTeamTranscripts)
          .where(
            and(
              eq(infinitusTeamTranscripts.teamId, key.teamId),
              eq(infinitusTeamTranscripts.userId, key.userId),
              eq(infinitusTeamTranscripts.environmentId, key.environmentId),
              eq(infinitusTeamTranscripts.threadId, key.threadId),
              eq(infinitusTeamTranscripts.seq, key.seq),
            ),
          )
          .pipe(Effect.mapError(failing("delete_transcripts")));
      }
    }),
    createGrant: Effect.fn("relay.infinitus_team.create_grant")(function* (input) {
      yield* db
        .insert(infinitusTeamGrants)
        .values({
          grantId: input.grantId,
          teamId: input.teamId,
          userId: input.userId,
          environmentId: input.environmentId,
          audienceJson: input.audience,
          threadsJson: input.threads,
          capabilitiesJson: input.capabilities,
          preauthorizedJson: input.preauthorized,
          expiresAt: input.expiresAt,
          createdAt: input.createdAt,
        })
        .pipe(Effect.mapError(failing("create_grant")));
    }),
    getGrant: Effect.fn("relay.infinitus_team.get_grant")(function* (grantId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamGrants)
        .where(eq(infinitusTeamGrants.grantId, grantId))
        .limit(1)
        .pipe(Effect.mapError(failing("get_grant")));
      return rows[0] ? grantRow(rows[0]) : null;
    }),
    listGrantsForTeam: Effect.fn("relay.infinitus_team.list_grants")(function* (teamId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamGrants)
        .where(eq(infinitusTeamGrants.teamId, teamId))
        .pipe(Effect.mapError(failing("list_grants")));
      return rows.map(grantRow);
    }),
    deleteGrant: Effect.fn("relay.infinitus_team.delete_grant")(function* (teamId, grantId, userId) {
      const rows = yield* db
        .delete(infinitusTeamGrants)
        .where(
          and(
            eq(infinitusTeamGrants.teamId, teamId),
            eq(infinitusTeamGrants.grantId, grantId),
            eq(infinitusTeamGrants.userId, userId),
          ),
        )
        .returning({ grantId: infinitusTeamGrants.grantId })
        .pipe(Effect.mapError(failing("delete_grant")));
      return rows.length > 0;
    }),
    createCommand: Effect.fn("relay.infinitus_team.create_command")(function* (input) {
      yield* db
        .insert(infinitusTeamCommands)
        .values({
          commandId: input.commandId,
          teamId: input.teamId,
          fromUserId: input.fromUserId,
          toUserId: input.toUserId,
          environmentId: input.environmentId,
          grantId: input.grantId,
          threadId: input.threadId,
          action: input.action,
          text: input.text,
          project: input.project,
          status: input.status,
          ackJson: input.ack,
          createdAt: input.createdAt,
          expiresAt: input.expiresAt,
          answeredAt: input.answeredAt,
        })
        .pipe(Effect.mapError(failing("create_command")));
    }),
    getCommand: Effect.fn("relay.infinitus_team.get_command")(function* (commandId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamCommands)
        .where(eq(infinitusTeamCommands.commandId, commandId))
        .limit(1)
        .pipe(Effect.mapError(failing("get_command")));
      return rows[0] ? commandRow(rows[0]) : null;
    }),
    takeQueuedForEnvironment: Effect.fn("relay.infinitus_team.take_queued")(function* (environmentId, now) {
      const rows = yield* db
        .update(infinitusTeamCommands)
        .set({ status: "running" })
        .where(
          and(
            eq(infinitusTeamCommands.environmentId, environmentId),
            eq(infinitusTeamCommands.status, "queued"),
            sql`${infinitusTeamCommands.expiresAt} > ${now}`,
          ),
        )
        .returning()
        .pipe(Effect.mapError(failing("take_queued")));
      return rows.map(commandRow);
    }),
    listPendingForUser: Effect.fn("relay.infinitus_team.list_pending")(function* (teamId, toUserId) {
      const rows = yield* db
        .select()
        .from(infinitusTeamCommands)
        .where(
          and(
            eq(infinitusTeamCommands.teamId, teamId),
            eq(infinitusTeamCommands.toUserId, toUserId),
            eq(infinitusTeamCommands.status, "pending"),
          ),
        )
        .orderBy(infinitusTeamCommands.createdAt)
        .pipe(Effect.mapError(failing("list_pending")));
      return rows.map(commandRow);
    }),
    updateCommand: Effect.fn("relay.infinitus_team.update_command")(function* (commandId, patch) {
      yield* db
        .update(infinitusTeamCommands)
        .set({
          status: patch.status,
          ...(patch.ack === undefined ? {} : { ackJson: patch.ack }),
          ...(patch.expiresAt === undefined ? {} : { expiresAt: patch.expiresAt }),
          ...(patch.answeredAt === undefined ? {} : { answeredAt: patch.answeredAt }),
        })
        .where(eq(infinitusTeamCommands.commandId, commandId))
        .pipe(Effect.mapError(failing("update_command")));
    }),
    expireCommands: Effect.fn("relay.infinitus_team.expire_commands")(function* (now) {
      yield* db
        .update(infinitusTeamCommands)
        .set({ status: "expired", answeredAt: now })
        .where(
          and(
            inArray(infinitusTeamCommands.status, ["queued", "pending", "running"]),
            lt(infinitusTeamCommands.expiresAt, now),
          ),
        )
        .pipe(Effect.mapError(failing("expire_commands")));
    }),
  });
});

export const layer = Layer.effect(InfinitusTeamStore, make);
