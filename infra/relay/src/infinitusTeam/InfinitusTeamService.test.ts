import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as TestClock from "effect/testing/TestClock";

import * as EnvironmentLinks from "../environments/EnvironmentLinks.ts";
import * as InMemory from "./inMemoryStore.ts";
import * as Service from "./InfinitusTeamService.ts";
import * as TranscriptStore from "./InfinitusTeamTranscriptStore.ts";

const KEY = "env-key";
const LINKS: Record<string, ReadonlyArray<{ environmentId: string; label: string }>> = {
  "user-1": [
    { environmentId: "env-1", label: "Loc's Mac" },
    { environmentId: "env-1b", label: "Loc's Linux box" },
  ],
  "user-2": [{ environmentId: "env-2", label: "Bo's Mac" }],
};

function harness() {
  const state = InMemory.emptyState();
  const objects = new Map<string, string>();
  const links = Layer.succeed(EnvironmentLinks.EnvironmentLinks, {
    upsert: () => Effect.die("unused"),
    listDeliveryUsersForEnvironment: () => Effect.die("unused"),
    listForUser: ({ userId }) =>
      Effect.succeed(
        (LINKS[userId] ?? []).map((l) => ({
          environmentId: l.environmentId as never,
          label: l.label,
          endpoint: {
            httpBaseUrl: "https://x",
            wsBaseUrl: "wss://x",
            providerKind: "cloudflare_tunnel" as const,
          },
          linkedAt: "2026-09-25T00:00:00.000Z",
        })),
      ),
    getForUser: ({ userId, environmentId }) =>
      Effect.succeed(
        (LINKS[userId] ?? []).some((l) => l.environmentId === environmentId)
          ? {
              environmentId: environmentId as never,
              label: "x",
              endpoint: {
                httpBaseUrl: "https://x",
                wsBaseUrl: "wss://x",
                providerKind: "cloudflare_tunnel" as const,
              },
              linkedAt: "2026-09-25T00:00:00.000Z",
              environmentPublicKey: KEY,
            }
          : null,
      ),
    revokeForUser: () => Effect.die("unused"),
  });
  const layer = Service.layer.pipe(
    Layer.provide(
      Layer.mergeAll(InMemory.layer(state), TranscriptStore.inMemoryLayer(objects), links),
    ),
    Layer.provideMerge(NodeServices.layer),
  );
  return { state, objects, layer };
}

const env = (userId: string, environmentId: string) => ({
  userId,
  environmentId,
  environmentPublicKey: KEY,
});

/** `it.effect` runs on the test clock, which starts in 1970: every fixture
    date below assumes today is 2026-09-25. */
const today = TestClock.setTime(Date.parse("2026-09-25T07:00:00.000Z"));

/** A team with Loc (founder) and Bo (member, joined by a one-use invite). */
const teamOfTwo = Effect.gen(function* () {
  yield* today;
  const service = yield* Service.InfinitusTeamService;
  const created = yield* service.createTeam({
    userId: "user-1",
    name: "Papaya",
    memberName: "Loc",
  });
  const invite = yield* service.createInvite({
    userId: "user-1",
    teamId: created.teamId,
    days: 7,
    oneUse: true,
  });
  yield* service.joinTeam({ userId: "user-2", token: invite.token, memberName: "Bo" });
  return { service, teamId: created.teamId as string };
});

const refusal = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
  Effect.flip(effect).pipe(Effect.map((e) => (e as { reason?: string }).reason));

describe("InfinitusTeamService", () => {
  it.effect("create makes the caller the founding leader with shares off", () => {
    const { layer } = harness();
    return Effect.gen(function* () {
      yield* today;
      const service = yield* Service.InfinitusTeamService;
      const snap = yield* service.createTeam({
        userId: "user-1",
        name: "Papaya",
        memberName: "Loc",
      });
      expect(snap.role).toBe("leader");
      expect(snap.members[0]).toMatchObject({
        userId: "user-1",
        name: "Loc",
        founder: true,
        machines: [],
      });
      expect(Object.values(snap.me.shares).every((v) => v === "off")).toBe(true);
      expect(yield* service.listTeams("user-1")).toEqual([
        { teamId: snap.teamId, name: "Papaya", role: "leader" },
      ]);
    }).pipe(Effect.provide(layer));
  });

  it.effect("join with a one-use token joins at once and spends it", () => {
    const { layer } = harness();
    return Effect.gen(function* () {
      yield* today;
      const service = yield* Service.InfinitusTeamService;
      const created = yield* service.createTeam({
        userId: "user-1",
        name: "Papaya",
        memberName: "Loc",
      });
      const invite = yield* service.createInvite({
        userId: "user-1",
        teamId: created.teamId,
        days: 1,
        oneUse: true,
      });
      const joined = yield* service.joinTeam({
        userId: "user-2",
        token: invite.token,
        memberName: "Bo",
      });
      expect(joined).toEqual({ teamId: created.teamId, status: "member" });
      expect(
        yield* refusal(
          service.joinTeam({ userId: "user-3", token: invite.token, memberName: "Cy" }),
        ),
      ).toBe("This invite was already used.");
      const snap = yield* service.getTeam({ userId: "user-1", teamId: created.teamId });
      expect(snap.invites[0]).toMatchObject({ inviteId: invite.inviteId, usedBy: "user-2" });
      expect(snap.invites[0]).not.toHaveProperty("token");
    }).pipe(Effect.provide(layer));
  });

  it.effect(
    "join with a reusable token creates a request that a leader approves or declines",
    () => {
      const { layer } = harness();
      return Effect.gen(function* () {
        yield* today;
        const service = yield* Service.InfinitusTeamService;
        const created = yield* service.createTeam({
          userId: "user-1",
          name: "Papaya",
          memberName: "Loc",
        });
        const code = yield* service.createInvite({
          userId: "user-1",
          teamId: created.teamId,
          days: 30,
          oneUse: false,
        });
        expect(
          yield* service.joinTeam({ userId: "user-2", token: code.token, memberName: "Bo" }),
        ).toEqual({
          teamId: created.teamId,
          status: "pending",
        });
        expect(
          yield* service.joinTeam({ userId: "user-3", token: code.token, memberName: "Cy" }),
        ).toMatchObject({
          status: "pending",
        });
        let snap = yield* service.getTeam({ userId: "user-1", teamId: created.teamId });
        expect(snap.requests.map((r) => r.name)).toEqual(["Bo", "Cy"]);
        snap = yield* service.approveRequest({
          userId: "user-1",
          teamId: created.teamId,
          targetUserId: "user-2",
        });
        expect(snap.members.map((m) => m.name)).toEqual(["Loc", "Bo"]);
        snap = yield* service.declineRequest({
          userId: "user-1",
          teamId: created.teamId,
          targetUserId: "user-3",
        });
        expect(snap.requests).toEqual([]);
        expect(
          yield* service.joinTeam({ userId: "user-2", token: code.token, memberName: "Bo" }),
        ).toMatchObject({
          status: "member",
        });
      }).pipe(Effect.provide(layer));
    },
  );

  it.effect("policy off refuses joins and new invites; expired and revoked invites refuse", () => {
    const { layer, state } = harness();
    return Effect.gen(function* () {
      yield* today;
      const service = yield* Service.InfinitusTeamService;
      const created = yield* service.createTeam({
        userId: "user-1",
        name: "Papaya",
        memberName: "Loc",
      });
      const code = yield* service.createInvite({
        userId: "user-1",
        teamId: created.teamId,
        days: 30,
        oneUse: false,
      });
      yield* service.updatePolicy({ userId: "user-1", teamId: created.teamId, requests: "off" });
      expect(
        yield* refusal(service.joinTeam({ userId: "user-2", token: code.token, memberName: "Bo" })),
      ).toBe("This team is not taking requests.");
      expect(
        yield* refusal(
          service.createInvite({
            userId: "user-1",
            teamId: created.teamId,
            days: 1,
            oneUse: false,
          }),
        ),
      ).toBe("This team is not taking requests.");
      yield* service.updatePolicy({ userId: "user-1", teamId: created.teamId, requests: "code" });
      yield* service.revokeInvite({
        userId: "user-1",
        teamId: created.teamId,
        inviteId: code.inviteId,
      });
      expect(
        yield* refusal(service.joinTeam({ userId: "user-2", token: code.token, memberName: "Bo" })),
      ).toBe("This invite was revoked.");
      const stale = yield* service.createInvite({
        userId: "user-1",
        teamId: created.teamId,
        days: 1,
        oneUse: false,
      });
      const record = state.invites.get(stale.inviteId)!;
      state.invites.set(stale.inviteId, { ...record, expiresAt: "2000-01-01T00:00:00.000Z" });
      expect(
        yield* refusal(
          service.joinTeam({ userId: "user-2", token: stale.token, memberName: "Bo" }),
        ),
      ).toBe("This invite has expired.");
      expect(
        yield* refusal(service.joinTeam({ userId: "user-2", token: "nonsense", memberName: "Bo" })),
      ).toBe("This invite is not valid.");
    }).pipe(Effect.provide(layer));
  });

  it.effect(
    "leaders: the last one cannot leave or be demoted, the founder cannot be removed, members cannot promote",
    () => {
      const { layer } = harness();
      return Effect.gen(function* () {
        const { service, teamId } = yield* teamOfTwo;
        expect(yield* refusal(service.leaveTeam({ userId: "user-1", teamId }))).toBe(
          "You are the last leader: promote someone before you leave.",
        );
        expect(
          yield* refusal(
            service.demoteMember({ userId: "user-1", teamId, targetUserId: "user-1" }),
          ),
        ).toBe("A team keeps at least one leader.");
        expect(
          yield* refusal(
            service.promoteMember({ userId: "user-2", teamId, targetUserId: "user-2" }),
          ),
        ).toBe("Only a leader can do that.");
        expect(
          yield* refusal(
            service.removeMember({ userId: "user-1", teamId, targetUserId: "user-1" }),
          ),
        ).toBe("The founder cannot be removed.");
        yield* service.promoteMember({ userId: "user-1", teamId, targetUserId: "user-2" });
        yield* service.leaveTeam({ userId: "user-1", teamId });
        const snap = yield* service.getTeam({ userId: "user-2", teamId });
        expect(snap.members.map((m) => m.userId)).toEqual(["user-2"]);
        expect(snap.role).toBe("leader");
      }).pipe(Effect.provide(layer));
    },
  );

  it.effect("snapshot hides requests and invites from members", () => {
    const { layer } = harness();
    return Effect.gen(function* () {
      const { service, teamId } = yield* teamOfTwo;
      yield* service.createInvite({ userId: "user-1", teamId, days: 1, oneUse: false });
      const asMember = yield* service.getTeam({ userId: "user-2", teamId });
      expect(asMember.invites).toEqual([]);
      expect(asMember.requests).toEqual([]);
      expect(
        yield* refusal(service.createInvite({ userId: "user-2", teamId, days: 1, oneUse: false })),
      ).toBe("Only a leader can do that.");
    }).pipe(Effect.provide(layer));
  });

  it.effect("listDocuments honours share × role, and off hides existing documents", () => {
    const { layer } = harness();
    return Effect.gen(function* () {
      const { service, teamId } = yield* teamOfTwo;
      yield* service.promoteMember({ userId: "user-1", teamId, targetUserId: "user-2" });
      const created = yield* service.createTeam({
        userId: "user-3",
        name: "Other",
        memberName: "Cy",
      });
      void created;
      // Bo (now a leader) publishes threads to leaders, fleet to the team; Loc reads.
      yield* service.updateMe({
        userId: "user-2",
        teamId,
        shares: {
          now: "team",
          fleet: "team",
          threads: "leaders",
          stats: "off",
          transcripts: "off",
        },
      });
      yield* service.publishDocuments({
        ...env("user-2", "env-2"),
        teamId,
        documents: [
          { kind: "fleet", key: "-", body: { fleets: [] } },
          { kind: "threads", key: "-", body: { threads: [] } },
          { kind: "stats", key: "2026-09-25", body: { usd: 1 } },
        ],
      });
      const asLeader = yield* service.listDocuments({ userId: "user-1", teamId });
      expect(asLeader.map((d) => d.kind).sort()).toEqual(["fleet", "threads"]);
      yield* service
        .demoteMember({ userId: "user-1", teamId, targetUserId: "user-1" })
        .pipe(Effect.ignore);
      yield* service.demoteMember({ userId: "user-2", teamId, targetUserId: "user-1" });
      const asMember = yield* service.listDocuments({ userId: "user-1", teamId });
      expect(asMember.map((d) => d.kind)).toEqual(["fleet"]);
      yield* service.updateMe({
        userId: "user-2",
        teamId,
        shares: { now: "off", fleet: "off", threads: "off", stats: "off", transcripts: "off" },
      });
      expect(yield* service.listDocuments({ userId: "user-1", teamId })).toEqual([]);
      expect((yield* service.listDocuments({ userId: "user-2", teamId })).length).toBe(2);
    }).pipe(Effect.provide(layer));
  });

  it.effect(
    "two machines fold under one member, and a now older than ten minutes is offline",
    () => {
      const { layer, state } = harness();
      return Effect.gen(function* () {
        const { service, teamId } = yield* teamOfTwo;
        yield* service.updateMe({
          userId: "user-1",
          teamId,
          shares: { now: "team", fleet: "off", threads: "off", stats: "off", transcripts: "off" },
        });
        yield* service.publishDocuments({
          ...env("user-1", "env-1"),
          teamId,
          documents: [{ kind: "now", key: "-", body: { at: 1 } }],
        });
        yield* service.publishDocuments({
          ...env("user-1", "env-1b"),
          teamId,
          documents: [{ kind: "now", key: "-", body: { at: 2 } }],
        });
        let snap = yield* service.getTeam({ userId: "user-2", teamId });
        const loc = snap.members.find((m) => m.userId === "user-1")!;
        expect(loc.machines.map((m) => m.label).sort()).toEqual(["Loc's Linux box", "Loc's Mac"]);
        expect(loc.machines.every((m) => m.now !== undefined)).toBe(true);
        for (const [key, doc] of state.documents) {
          if (doc.environmentId === "env-1b")
            state.documents.set(key, { ...doc, updatedAt: "2026-01-01T00:00:00.000Z" });
        }
        snap = yield* service.getTeam({ userId: "user-2", teamId });
        const stale = snap.members
          .find((m) => m.userId === "user-1")!
          .machines.find((m) => m.environmentId === "env-1b")!;
        expect(stale.now).toBeUndefined();
        expect(stale.lastPublished).toBe("2026-01-01T00:00:00.000Z");
      }).pipe(Effect.provide(layer));
    },
  );

  it.effect(
    "transcripts: refused when shared off, sequenced, readable by share, deleted with the member",
    () => {
      const { layer, objects } = harness();
      return Effect.gen(function* () {
        const { service, teamId } = yield* teamOfTwo;
        const chunk = {
          ...env("user-2", "env-2"),
          teamId,
          threadId: "thread-1",
          seq: 0,
          rows: 2,
          lines: "a\nb\n",
        };
        expect(yield* refusal(service.publishTranscript(chunk))).toBe(
          "Transcripts are not shared.",
        );
        yield* service.updateMe({
          userId: "user-2",
          teamId,
          shares: {
            now: "off",
            fleet: "off",
            threads: "off",
            stats: "off",
            transcripts: "leaders",
          },
        });
        yield* service.publishTranscript(chunk);
        expect(yield* refusal(service.publishTranscript(chunk))).toBe("The next chunk is 1.");
        yield* service.publishTranscript({ ...chunk, seq: 1, rows: 1, lines: "c\n" });
        const memberships = yield* service.memberships(env("user-2", "env-2"));
        expect(memberships.teams[0]?.transcripts).toEqual([
          { threadId: "thread-1", rows: 3, nextSeq: 2 },
        ]);
        const read = {
          userId: "user-1",
          teamId,
          ownerUserId: "user-2",
          environmentId: "env-2",
          threadId: "thread-1",
        };
        expect((yield* service.listTranscriptChunks(read)).map((c) => c.seq)).toEqual([0, 1]);
        expect(yield* service.readTranscriptChunk({ ...read, seq: 1 })).toBe("c\n");
        yield* service.promoteMember({ userId: "user-1", teamId, targetUserId: "user-2" });
        yield* service.demoteMember({ userId: "user-2", teamId, targetUserId: "user-1" });
        expect(yield* refusal(service.listTranscriptChunks(read))).toBe(
          "Transcripts are not shared with you.",
        );
        expect(objects.size).toBe(2);
        yield* service.leaveTeam({ userId: "user-2", teamId }).pipe(Effect.ignore); // last leader now: refused
        yield* service.promoteMember({ userId: "user-2", teamId, targetUserId: "user-1" });
        yield* service.removeMember({ userId: "user-1", teamId, targetUserId: "user-2" });
        expect(objects.size).toBe(0);
      }).pipe(Effect.provide(layer));
    },
  );

  it.effect("commands: the grant is checked, taps are pending, allow queues, deny refuses", () => {
    const { layer } = harness();
    return Effect.gen(function* () {
      const { service, teamId } = yield* teamOfTwo;
      expect(
        yield* refusal(
          service.createCommand({
            userId: "user-1",
            teamId,
            toUserId: "user-2",
            environmentId: "env-2",
            threadId: "t-1",
            action: "send",
            text: "hi",
          }),
        ),
      ).toBe("They have not let you do that.");
      const grant = yield* service.createGrant({
        userId: "user-2",
        teamId,
        environmentId: "env-2" as never,
        audience: "leaders",
        threads: "all",
        capabilities: ["send", "interrupt"],
      });
      const sent = yield* service.createCommand({
        userId: "user-1",
        teamId,
        toUserId: "user-2",
        environmentId: "env-2",
        threadId: "t-1",
        action: "send",
        text: "hi",
      });
      expect(sent.status).toBe("queued");
      const interrupt = yield* service.createCommand({
        userId: "user-1",
        teamId,
        toUserId: "user-2",
        environmentId: "env-2",
        threadId: "t-1",
        action: "interrupt",
      });
      expect(interrupt.status).toBe("pending");
      const pending = yield* service.listPendingCommands({ userId: "user-2", teamId });
      expect(pending.map((p) => p.commandId)).toEqual([interrupt.commandId]);
      expect(pending[0]?.fromName).toBe("Loc");
      expect(
        yield* refusal(
          service.allowCommand({ userId: "user-1", teamId, commandId: interrupt.commandId }),
        ),
      ).toBe("That command is not waiting for you.");
      expect(
        (yield* service.allowCommand({ userId: "user-2", teamId, commandId: interrupt.commandId }))
          .status,
      ).toBe("queued");
      const second = yield* service.createCommand({
        userId: "user-1",
        teamId,
        toUserId: "user-2",
        environmentId: "env-2",
        threadId: "t-1",
        action: "interrupt",
      });
      const denied = yield* service.denyCommand({
        userId: "user-2",
        teamId,
        commandId: second.commandId,
      });
      expect(denied).toMatchObject({ status: "denied", ack: { outcome: "refused" } });
      expect(
        (yield* service.getCommand({ userId: "user-1", teamId, commandId: second.commandId }))
          .status,
      ).toBe("denied");
      expect(
        yield* refusal(
          service.getCommand({ userId: "user-3", teamId, commandId: second.commandId }),
        ),
      ).toBe("That command is not yours.");
      // The environment polls: both queued commands come back with the grant, marked running.
      const polled = yield* service.pollCommands(env("user-2", "env-2"));
      expect(polled.map((c) => c.commandId).sort()).toEqual(
        [sent.commandId, interrupt.commandId].sort(),
      );
      expect(polled[0]?.grant.grantId).toBe(grant.grantId);
      expect(yield* service.pollCommands(env("user-2", "env-2"))).toEqual([]);
      yield* service.ackCommand({
        ...env("user-2", "env-2"),
        commandId: sent.commandId,
        outcome: "done",
      });
      expect(
        (yield* service.getCommand({ userId: "user-1", teamId, commandId: sent.commandId })).status,
      ).toBe("done");
      yield* service.ackCommand({
        ...env("user-2", "env-2"),
        commandId: interrupt.commandId,
        outcome: "pending",
      });
      expect(
        (yield* service.getCommand({ userId: "user-1", teamId, commandId: interrupt.commandId }))
          .status,
      ).toBe("pending");
    }).pipe(Effect.provide(layer));
  });

  it.effect("a revoked grant refuses a queued command at the poll", () => {
    const { layer } = harness();
    return Effect.gen(function* () {
      const { service, teamId } = yield* teamOfTwo;
      const grant = yield* service.createGrant({
        userId: "user-2",
        teamId,
        environmentId: "env-2" as never,
        audience: ["user-1"],
        threads: ["t-1"] as never,
        capabilities: ["send"],
      });
      const sent = yield* service.createCommand({
        userId: "user-1",
        teamId,
        toUserId: "user-2",
        environmentId: "env-2",
        threadId: "t-1",
        action: "send",
        text: "hi",
      });
      yield* service.revokeGrant({ userId: "user-2", teamId, grantId: grant.grantId });
      expect(yield* service.pollCommands(env("user-2", "env-2"))).toEqual([]);
      expect(
        yield* service.getCommand({ userId: "user-1", teamId, commandId: sent.commandId }),
      ).toMatchObject({
        status: "refused",
        ack: { outcome: "noGrant" },
      });
    }).pipe(Effect.provide(layer));
  });

  it.effect("environment calls need a live link for that user, environment and key", () => {
    const { layer } = harness();
    return Effect.gen(function* () {
      const { service, teamId } = yield* teamOfTwo;
      expect(yield* refusal(service.memberships(env("user-2", "env-1")))).toBe(
        "This environment is not linked to that user.",
      );
      expect(
        yield* refusal(
          service.publishDocuments({
            ...env("user-1", "env-1"),
            environmentPublicKey: "other",
            teamId,
            documents: [],
          }),
        ),
      ).toBe("This environment is not linked to that user.");
      const memberships = yield* service.memberships(env("user-1", "env-1"));
      expect(memberships.teams.map((t) => t.teamId)).toEqual([teamId]);
    }).pipe(Effect.provide(layer));
  });

  it.effect("prune expires commands and deletes transcripts past retention or over the cap", () => {
    const { layer, state, objects } = harness();
    return Effect.gen(function* () {
      const { service, teamId } = yield* teamOfTwo;
      yield* service.updateMe({
        userId: "user-2",
        teamId,
        shares: { now: "off", fleet: "off", threads: "off", stats: "off", transcripts: "team" },
      });
      yield* service.publishTranscript({
        ...env("user-2", "env-2"),
        teamId,
        threadId: "old",
        seq: 0,
        rows: 1,
        lines: "x",
      });
      yield* service.publishTranscript({
        ...env("user-2", "env-2"),
        teamId,
        threadId: "big",
        seq: 0,
        rows: 1,
        lines: "y",
      });
      for (const [key, t] of state.transcripts) {
        if (t.threadId === "old")
          state.transcripts.set(key, { ...t, createdAt: "2020-01-01T00:00:00.000Z" });
        if (t.threadId === "big")
          state.transcripts.set(key, { ...t, bytes: Service.TRANSCRIPT_MEMBER_BYTES + 1 });
      }
      yield* service.createGrant({
        userId: "user-2",
        teamId,
        environmentId: "env-2" as never,
        audience: "team",
        threads: "all",
        capabilities: ["send"],
      });
      const sent = yield* service.createCommand({
        userId: "user-1",
        teamId,
        toUserId: "user-2",
        environmentId: "env-2",
        threadId: "t",
        action: "send",
        text: "hi",
      });
      state.commands.set(sent.commandId, {
        ...state.commands.get(sent.commandId)!,
        expiresAt: "2020-01-01T00:00:00.000Z",
      });
      const result = yield* service.prune;
      expect(result.transcriptsDeleted).toBe(2);
      expect(objects.size).toBe(0);
      expect(state.commands.get(sent.commandId)?.status).toBe("expired");
    }).pipe(Effect.provide(layer));
  });
});
