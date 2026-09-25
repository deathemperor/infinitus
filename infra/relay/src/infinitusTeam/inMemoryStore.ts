import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import {
  type CommandRecord,
  type DocumentRecord,
  type GrantRecord,
  InfinitusTeamStore,
  type InviteRecord,
  type MemberRecord,
  type RequestRecord,
  type TeamRecord,
  type TranscriptRecord,
} from "./InfinitusTeamStore.ts";

/**
 * `InfinitusTeamStore` over Maps, for the service's and the handlers' tests:
 * the same contract as the Drizzle layer, in memory, so a rule is tested on
 * rows and never on SQL. `state` is exposed so a test can seed or inspect.
 */
export interface InMemoryTeamState {
  readonly teams: Map<string, TeamRecord>;
  readonly members: Map<string, MemberRecord>;
  readonly invites: Map<string, InviteRecord>;
  readonly requests: Map<string, RequestRecord>;
  readonly documents: Map<string, DocumentRecord>;
  readonly transcripts: Map<string, TranscriptRecord>;
  readonly grants: Map<string, GrantRecord>;
  readonly commands: Map<string, CommandRecord>;
}

export const emptyState = (): InMemoryTeamState => ({
  teams: new Map(),
  members: new Map(),
  invites: new Map(),
  requests: new Map(),
  documents: new Map(),
  transcripts: new Map(),
  grants: new Map(),
  commands: new Map(),
});

const memberKey = (teamId: string, userId: string) => `${teamId}\u0000${userId}`;
const documentKey = (d: {
  teamId: string;
  userId: string;
  environmentId: string;
  kind: string;
  key: string;
}) => [d.teamId, d.userId, d.environmentId, d.kind, d.key].join("\u0000");
const transcriptKey = (t: {
  teamId: string;
  userId: string;
  environmentId: string;
  threadId: string;
  seq: number;
}) => [t.teamId, t.userId, t.environmentId, t.threadId, String(t.seq)].join("\u0000");

export const make = (state: InMemoryTeamState = emptyState()) =>
  InfinitusTeamStore.of({
    getTeam: (teamId) => Effect.sync(() => state.teams.get(teamId) ?? null),
    createTeam: (input) =>
      Effect.sync(() => {
        state.teams.set(input.teamId, {
          teamId: input.teamId,
          name: input.name,
          founderUserId: input.founderUserId,
          policyRequests: "code",
          createdAt: input.now,
        });
      }),
    updateTeamPolicy: (teamId, requests) =>
      Effect.sync(() => {
        const team = state.teams.get(teamId);
        if (team) state.teams.set(teamId, { ...team, policyRequests: requests });
      }),
    listTeamsForUser: (userId) =>
      Effect.sync(() =>
        [...state.members.values()]
          .filter((m) => m.userId === userId)
          .flatMap((m) => {
            const team = state.teams.get(m.teamId);
            return team ? [{ teamId: team.teamId, name: team.name, role: m.role }] : [];
          }),
      ),
    listMembers: (teamId) =>
      Effect.sync(() => [...state.members.values()].filter((m) => m.teamId === teamId)),
    getMember: (teamId, userId) =>
      Effect.sync(() => state.members.get(memberKey(teamId, userId)) ?? null),
    upsertMember: (input) =>
      Effect.sync(() => {
        const { now: _now, ...record } = input;
        state.members.set(memberKey(input.teamId, input.userId), record);
      }),
    updateMember: (teamId, userId, patch) =>
      Effect.sync(() => {
        const key = memberKey(teamId, userId);
        const member = state.members.get(key);
        if (!member) return;
        state.members.set(key, {
          ...member,
          ...(patch.name === undefined ? {} : { name: patch.name }),
          ...(patch.shares === undefined ? {} : { shares: patch.shares }),
          ...(patch.role === undefined ? {} : { role: patch.role }),
        });
      }),
    deleteMember: (teamId, userId) =>
      Effect.sync(() => {
        const transcripts = [...state.transcripts.values()].filter(
          (t) => t.teamId === teamId && t.userId === userId,
        );
        for (const t of transcripts) state.transcripts.delete(transcriptKey(t));
        for (const [key, d] of state.documents)
          if (d.teamId === teamId && d.userId === userId) state.documents.delete(key);
        for (const [key, g] of state.grants)
          if (g.teamId === teamId && g.userId === userId) state.grants.delete(key);
        for (const [key, c] of state.commands) {
          if (c.teamId === teamId && (c.fromUserId === userId || c.toUserId === userId))
            state.commands.delete(key);
        }
        state.requests.delete(memberKey(teamId, userId));
        state.members.delete(memberKey(teamId, userId));
        return transcripts;
      }),
    createInvite: (input) =>
      Effect.sync(() => {
        state.invites.set(input.inviteId, { ...input, usedByUserId: null, revokedAt: null });
      }),
    getInviteByHash: (tokenHash) =>
      Effect.sync(() => [...state.invites.values()].find((i) => i.tokenHash === tokenHash) ?? null),
    markInviteUsed: (inviteId, userId) =>
      Effect.sync(() => {
        const invite = state.invites.get(inviteId);
        if (invite) state.invites.set(inviteId, { ...invite, usedByUserId: userId });
      }),
    revokeInvite: (teamId, inviteId, now) =>
      Effect.sync(() => {
        const invite = state.invites.get(inviteId);
        if (!invite || invite.teamId !== teamId) return false;
        state.invites.set(inviteId, { ...invite, revokedAt: now });
        return true;
      }),
    listInvites: (teamId) =>
      Effect.sync(() =>
        [...state.invites.values()]
          .filter((i) => i.teamId === teamId)
          .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1)),
      ),
    upsertRequest: (input) =>
      Effect.sync(() => {
        state.requests.set(memberKey(input.teamId, input.userId), input);
      }),
    getRequest: (teamId, userId) =>
      Effect.sync(() => state.requests.get(memberKey(teamId, userId)) ?? null),
    listRequests: (teamId) =>
      Effect.sync(() =>
        [...state.requests.values()]
          .filter((r) => r.teamId === teamId)
          .sort((a, b) => (a.createdAt < b.createdAt ? -1 : 1)),
      ),
    deleteRequest: (teamId, userId) =>
      Effect.sync(() => {
        state.requests.delete(memberKey(teamId, userId));
      }),
    upsertDocuments: (input) =>
      Effect.sync(() => {
        for (const document of input.documents) {
          const record: DocumentRecord = {
            teamId: input.teamId,
            userId: input.userId,
            environmentId: input.environmentId,
            kind: document.kind,
            key: document.key,
            body: document.body,
            updatedAt: input.now,
          };
          state.documents.set(documentKey(record), record);
        }
      }),
    listDocuments: (input) =>
      Effect.sync(() =>
        [...state.documents.values()].filter(
          (d) =>
            d.teamId === input.teamId &&
            (input.userId === undefined || d.userId === input.userId) &&
            (input.environmentId === undefined || d.environmentId === input.environmentId) &&
            (input.kind === undefined || d.kind === input.kind),
        ),
      ),
    insertTranscriptChunk: (input) =>
      Effect.sync(() => {
        state.transcripts.set(transcriptKey(input), input);
      }),
    listTranscriptChunks: (input) =>
      Effect.sync(() =>
        [...state.transcripts.values()]
          .filter(
            (t) =>
              t.teamId === input.teamId &&
              t.userId === input.userId &&
              t.environmentId === input.environmentId &&
              t.threadId === input.threadId,
          )
          .sort((a, b) => a.seq - b.seq),
      ),
    listTranscriptsForMember: (teamId, userId) =>
      Effect.sync(() =>
        [...state.transcripts.values()]
          .filter((t) => t.teamId === teamId && t.userId === userId)
          .sort((a, b) =>
            a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : a.seq - b.seq,
          ),
      ),
    listTranscriptsOlderThan: (createdBefore) =>
      Effect.sync(() => [...state.transcripts.values()].filter((t) => t.createdAt < createdBefore)),
    listTranscriptBytesByMember: () =>
      Effect.sync(() => {
        const totals = new Map<string, { teamId: string; userId: string; bytes: number }>();
        for (const t of state.transcripts.values()) {
          const key = memberKey(t.teamId, t.userId);
          const total = totals.get(key) ?? { teamId: t.teamId, userId: t.userId, bytes: 0 };
          totals.set(key, { ...total, bytes: total.bytes + t.bytes });
        }
        return [...totals.values()];
      }),
    deleteTranscriptChunks: (keys) =>
      Effect.sync(() => {
        for (const key of keys) state.transcripts.delete(transcriptKey(key));
      }),
    createGrant: (input) =>
      Effect.sync(() => {
        state.grants.set(input.grantId, input);
      }),
    getGrant: (grantId) => Effect.sync(() => state.grants.get(grantId) ?? null),
    listGrantsForTeam: (teamId) =>
      Effect.sync(() => [...state.grants.values()].filter((g) => g.teamId === teamId)),
    deleteGrant: (teamId, grantId, userId) =>
      Effect.sync(() => {
        const grant = state.grants.get(grantId);
        if (!grant || grant.teamId !== teamId || grant.userId !== userId) return false;
        state.grants.delete(grantId);
        return true;
      }),
    createCommand: (input) =>
      Effect.sync(() => {
        state.commands.set(input.commandId, input);
      }),
    getCommand: (commandId) => Effect.sync(() => state.commands.get(commandId) ?? null),
    takeQueuedForEnvironment: (environmentId, now) =>
      Effect.sync(() => {
        const taken: Array<CommandRecord> = [];
        for (const [key, c] of state.commands) {
          if (c.environmentId === environmentId && c.status === "queued" && c.expiresAt > now) {
            const running = { ...c, status: "running" as const };
            state.commands.set(key, running);
            taken.push(running);
          }
        }
        return taken;
      }),
    listPendingForUser: (teamId, toUserId) =>
      Effect.sync(() =>
        [...state.commands.values()]
          .filter((c) => c.teamId === teamId && c.toUserId === toUserId && c.status === "pending")
          .sort((a, b) => (a.createdAt < b.createdAt ? -1 : 1)),
      ),
    updateCommand: (commandId, patch) =>
      Effect.sync(() => {
        const command = state.commands.get(commandId);
        if (!command) return;
        state.commands.set(commandId, {
          ...command,
          status: patch.status,
          ...(patch.ack === undefined ? {} : { ack: patch.ack }),
          ...(patch.expiresAt === undefined ? {} : { expiresAt: patch.expiresAt }),
          ...(patch.answeredAt === undefined ? {} : { answeredAt: patch.answeredAt }),
        });
      }),
    expireCommands: (now) =>
      Effect.sync(() => {
        for (const [key, c] of state.commands) {
          if (
            (c.status === "queued" || c.status === "pending" || c.status === "running") &&
            c.expiresAt < now
          ) {
            state.commands.set(key, { ...c, status: "expired", answeredAt: now });
          }
        }
      }),
  });

export const layer = (state: InMemoryTeamState = emptyState()) =>
  Layer.succeed(InfinitusTeamStore, make(state));
