# Team on Infinitus Connect — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Team joins, shares and configures through the Infinitus Connect relay under the user's Clerk identity; the git store, per-Mac identity and sealed envelopes go.

**Architecture:** Seven new Postgres tables and one R2 bucket on the relay behind two new `RelayApi` groups (client-bearer and environment-credential). A reactor in the desktop server publishes documents and transcripts with the environment credential and polls a command queue. Web and phone read the relay directly with the user's Clerk token. The Mac keeps three verbs: the folded stats days and the private-project list.

**Tech Stack:** Effect (smol) + `effect/unstable/httpapi`, Drizzle `pg-core` on Neon via Hyperdrive, Alchemy (`Cloudflare.R2`), Clerk, React (web), React Native (phone), Swift (Mac).

**Spec:** `apps/mac/docs/superpowers/specs/2026-09-25-team-on-connect-design.md` — read it first; the plan argues from it.

## Global Constraints

- INFINITUS.md: one API (the Mac talks to nothing but the control socket); PR-only `main`; every commit carries the `Co-Authored-By` trailer; every PR carries `apps/mac/changelog.d/<pr>.md` (`Surface: sentence` per line); ledgers `docs/internals/fork-registration-points.md` and `fork-only-files.md` get a bullet per upstream file edited / fork file added; no `git stash`; after merging main run `git fetch origin main && git merge-base --is-ancestor origin/main HEAD || echo STALE`.
- AGENTS.md: no repo-wide checks; `vp test run <files>` and targeted typecheck only; Effect code follows `.repos/effect-smol/LLMS.md`.
- #1565: fork edits to upstream files stay at registration points. New relay code lives in `infra/relay/src/infinitusTeam/`; `worker.ts`, `persistence/schema.ts` and `packages/contracts/src/relay.ts` get one-line registrations.
- `worker.ts`'s runtime `pipe` and `server.ts`'s `ReactorCoreLayerLive` are at twenty stages: a new layer joins an existing stage (worker) or the second chained list `ReactorLayerLive` (server).
- Relay migrations are generated locally and committed: from `infra/relay`, `npx drizzle-kit generate --dialect postgresql --schema ./src/persistence/schema.ts --out ./migrations/postgres --name infinitus_team`; commit `migration.sql` and `snapshot.json`.
- The relay deploys on every merge to `main` (`deploy-relay.yml`); slice 2's deploy run must be green before slice 3 merges.
- Document bodies ≤ 256 KiB, transcript chunks ≤ 1 MiB, ≤ 40 documents per publish call, invite days 1..3650 (default 7), command TTL 120 s pending, 90 days / 200 MB transcript retention, `now` older than 10 min reads as offline.
- Secrets: an invite token is shown once, never logged, never on a span; the Join field is a password input cleared on submit.
- Naming: "Infinitus Connect" in copy (`CONNECT_NAME`); never "T3", never "fork" in anything user-facing.

## Review Focus

1. A user linked to two environments publishes from both; the pane must show two machines under one member, and a `now` from a stopped machine must read as offline after ten minutes, not vanish. (Task 3.4 test `two machines fold under one member`, Task 2.6 test `now older than ten minutes is offline`.)
2. A member narrows a share from `team` to `off` while a teammate has the pane open; the next document read must return nothing for that kind, and the publisher must stop sending it on its next cycle. (Task 2.4 test `off hides existing documents`, Task 3.2 test `skips kinds shared off`.)
3. The last leader tries to leave, and a leader tries to demote themselves as the last leader; both refuse with a sentence. (Task 2.4 tests `last leader cannot leave` and `last leader cannot be demoted`.)
4. A one-use invite is redeemed twice, and a reusable code is used after the policy flipped to `off`. (Task 2.4 tests `one-use token spent`, `policy off refuses joins`.)
5. A command whose grant was revoked between queueing and the poll must not run. (Task 3.3 test `revoked grant refuses a queued command`.)

---

## Slice 2 — Relay (one PR: `infinitus/team-relay`)

### Task 2.1: Contracts

**Files:**
- Create: `packages/contracts/src/relayInfinitusTeam.ts`
- Modify: `packages/contracts/package.json` (subpath export `./relayInfinitusTeam`, beside `./relayInfinitusAlert`)
- Modify: `packages/contracts/src/relay.ts` (two imports, two `.add` lines — the `RelayInfinitusAlertGroup` registration point)
- Test: `packages/contracts/src/relayInfinitusTeam.test.ts`

**Interfaces:**
- Produces: every schema below, `RelayInfinitusTeamGroup`, `RelayInfinitusTeamEnvironmentGroup` (groups without middleware; `relay.ts` attaches it), `RelayInfinitusTeamRefusedError`.

- [ ] **Step 1: Write the schema file**

```ts
// packages/contracts/src/relayInfinitusTeam.ts
import * as Schema from "effect/Schema";
import * as HttpApiEndpoint from "effect/unstable/httpapi/HttpApiEndpoint";
import * as HttpApiGroup from "effect/unstable/httpapi/HttpApiGroup";
import * as HttpApiSchema from "effect/unstable/httpapi/HttpApiSchema";
import * as OpenApi from "effect/unstable/httpapi/OpenApi";

import { EnvironmentId, ThreadId } from "./baseSchemas.ts";

/** Team on Infinitus Connect (#1592): a team is a relay row, a member a Clerk
    user, an invite a one-use or reusable token the relay checks. Schemas only;
    `relay.ts` attaches the auth middleware and adds the groups to `RelayApi`. */

export const TeamId = Schema.String.pipe(Schema.brand("TeamId"));
export type TeamId = typeof TeamId.Type;
export const TeamUserId = Schema.String;
export const TeamRole = Schema.Literals(["leader", "member"]);
export const TeamShareAudience = Schema.Literals(["off", "leaders", "team"]);
export type TeamShareAudience = typeof TeamShareAudience.Type;
export const TeamKind = Schema.Literals(["now", "fleet", "threads", "stats", "transcripts"]);
export type TeamKind = typeof TeamKind.Type;
export const TeamShares = Schema.Record(TeamKind, TeamShareAudience);
export type TeamShares = typeof TeamShares.Type;
/** Every kind starts `off`; a member turns each on. */
export const DEFAULT_TEAM_SHARES: TeamShares = { now: "off", fleet: "off", threads: "off", stats: "off", transcripts: "off" };
export const TeamPolicyRequests = Schema.Literals(["code", "off"]);
export const TeamCapability = Schema.Literals(["view", "send", "interrupt", "new"]);
export type TeamCapability = typeof TeamCapability.Type;
export const TeamAudience = Schema.Union([Schema.Literals(["team", "leaders"]), Schema.Array(TeamUserId)]);
export const TeamThreadsSelector = Schema.Union([Schema.Literal("all"), Schema.Array(ThreadId)]);
export const TeamCommandAction = TeamCapability;
export const TeamCommandStatus = Schema.Literals(["queued", "pending", "running", "done", "refused", "denied", "expired"]);
export const TeamCommandOutcome = Schema.Literals(["done", "refused", "pending", "notLive", "noGrant", "badRequest"]);

const MemberName = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(64));
const Iso = Schema.String;

export const TeamMachine = Schema.Struct({
  environmentId: EnvironmentId,
  label: Schema.String,
  now: Schema.optional(Schema.Unknown),
  lastPublished: Schema.NullOr(Iso),
});
export const TeamMemberRow = Schema.Struct({
  userId: TeamUserId, name: MemberName, role: TeamRole, founder: Schema.Boolean, since: Iso,
  machines: Schema.Array(TeamMachine),
});
export const TeamRequestRow = Schema.Struct({ userId: TeamUserId, name: MemberName, at: Iso });
export const TeamInviteRow = Schema.Struct({
  inviteId: Schema.String, oneUse: Schema.Boolean, expiresAt: Iso, usedBy: Schema.NullOr(TeamUserId),
});
export const TeamGrant = Schema.Struct({
  grantId: Schema.String, environmentId: EnvironmentId, audience: TeamAudience, threads: TeamThreadsSelector,
  capabilities: Schema.Array(TeamCapability), preauthorized: Schema.Array(TeamCapability), expiresAt: Schema.NullOr(Iso),
});
export const TeamPendingCommand = Schema.Struct({
  commandId: Schema.String, fromUserId: TeamUserId, fromName: MemberName, environmentId: EnvironmentId,
  threadId: Schema.String, action: TeamCommandAction, text: Schema.optional(Schema.String),
  project: Schema.optional(Schema.String), expiresAt: Iso,
});
export const TeamGrantToMe = Schema.Struct({
  grantorUserId: TeamUserId, environmentId: EnvironmentId, threads: TeamThreadsSelector, capabilities: Schema.Array(TeamCapability),
});
export const TeamSnapshot = Schema.Struct({
  teamId: TeamId, name: Schema.String, role: TeamRole,
  policy: Schema.Struct({ requests: TeamPolicyRequests }),
  me: Schema.Struct({ name: MemberName, shares: TeamShares }),
  members: Schema.Array(TeamMemberRow),
  requests: Schema.Array(TeamRequestRow),
  invites: Schema.Array(TeamInviteRow),
  grants: Schema.Array(TeamGrant),
  pending: Schema.Array(TeamPendingCommand),
  grantsToMe: Schema.Array(TeamGrantToMe),
});
export type TeamSnapshot = typeof TeamSnapshot.Type;

export const TeamListRow = Schema.Struct({ teamId: TeamId, name: Schema.String, role: TeamRole });
export const TeamCreateRequest = Schema.Struct({ name: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(64)), memberName: MemberName });
export const TeamJoinRequest = Schema.Struct({ token: Schema.String, memberName: MemberName });
export const TeamJoinResponse = Schema.Struct({ teamId: TeamId, status: Schema.Literals(["member", "pending"]) });
export const TeamMeUpdate = Schema.Struct({ name: Schema.optional(MemberName), shares: Schema.optional(TeamShares) });
export const TeamInviteCreate = Schema.Struct({
  days: Schema.Number.pipe(Schema.int(), Schema.between(1, 3650)), oneUse: Schema.Boolean,
});
export const TeamInviteCreated = Schema.Struct({ inviteId: Schema.String, token: Schema.String, expiresAt: Iso });
export const TeamPolicyUpdate = Schema.Struct({ requests: TeamPolicyRequests });
export const TeamDocumentRow = Schema.Struct({
  userId: TeamUserId, environmentId: EnvironmentId, kind: TeamKind, key: Schema.String, body: Schema.Unknown, updatedAt: Iso,
});
export const TeamTranscriptChunkRow = Schema.Struct({ seq: Schema.Number, rows: Schema.Number, bytes: Schema.Number, createdAt: Iso });
export const TeamTranscriptChunk = Schema.Struct({ lines: Schema.String });
export const TeamGrantCreate = Schema.Struct({
  environmentId: EnvironmentId, audience: TeamAudience, threads: TeamThreadsSelector,
  capabilities: Schema.Array(TeamCapability), preauthorized: Schema.optional(Schema.Array(TeamCapability)),
  expiresInSeconds: Schema.optional(Schema.Number.pipe(Schema.int(), Schema.positive())),
});
export const TeamCommandCreate = Schema.Struct({
  toUserId: TeamUserId, environmentId: EnvironmentId, threadId: Schema.String, action: TeamCommandAction,
  text: Schema.optional(Schema.String.pipe(Schema.maxLength(16_384))), project: Schema.optional(Schema.String),
});
export const TeamCommandState = Schema.Struct({
  commandId: Schema.String, status: TeamCommandStatus,
  ack: Schema.optional(Schema.Struct({ outcome: TeamCommandOutcome, detail: Schema.optional(Schema.String), result: Schema.optional(Schema.Unknown) })),
});
export const TeamOk = Schema.Struct({ ok: Schema.Literal(true) });

/** Environment side (the desktop server, environment credential). */
export const TeamEnvironmentMemberships = Schema.Struct({
  userId: TeamUserId,
  teams: Schema.Array(Schema.Struct({
    teamId: TeamId, shares: TeamShares, grants: Schema.Array(TeamGrant),
    transcripts: Schema.Array(Schema.Struct({ threadId: Schema.String, rows: Schema.Number })),
  })),
});
export const TeamDocumentsPublish = Schema.Struct({
  userId: TeamUserId,
  documents: Schema.Array(Schema.Struct({ kind: TeamKind, key: Schema.String, body: Schema.Unknown })).pipe(Schema.maxLength(40)),
});
export const TeamTranscriptPublish = Schema.Struct({
  userId: TeamUserId, threadId: Schema.String, seq: Schema.Number.pipe(Schema.int(), Schema.nonNegative()),
  rows: Schema.Number.pipe(Schema.int(), Schema.positive()), lines: Schema.String.pipe(Schema.maxLength(1_048_576)),
});
export const TeamQueuedCommand = Schema.Struct({
  commandId: Schema.String, teamId: TeamId, fromUserId: TeamUserId, threadId: Schema.String, action: TeamCommandAction,
  text: Schema.optional(Schema.String), project: Schema.optional(Schema.String), expiresAt: Iso,
  grant: TeamGrant,
});
export const TeamCommandAck = Schema.Struct({
  userId: TeamUserId, outcome: TeamCommandOutcome, detail: Schema.optional(Schema.String), result: Schema.optional(Schema.Unknown),
});
export const TeamUserHeader = Schema.Struct({ "x-infinitus-user": TeamUserId });

export class RelayInfinitusTeamRefusedError extends Schema.TaggedError<RelayInfinitusTeamRefusedError>()(
  "RelayInfinitusTeamRefusedError",
  { code: Schema.Literal("infinitus_team_refused"), reason: Schema.String, traceId: Schema.String },
  HttpApiSchema.annotations({ status: 409 }),
) {}

const teamParams = Schema.Struct({ teamId: TeamId });
const memberParams = Schema.Struct({ teamId: TeamId, userId: TeamUserId });

/** Groups without middleware: `relay.ts` adds `.middleware(RelayClientAuth)` and
    `.middleware(RelayEnvironmentAuth)` where it adds them to `RelayApi`, so this
    file never imports `relay.ts` (which imports it). The bearer header schema is
    inlined for the same reason. */
const Bearer = Schema.Struct({ authorization: Schema.String });

export const RelayInfinitusTeamGroup = HttpApiGroup.make("infinitusTeam")
  .add(
    HttpApiEndpoint.get("listTeams", "/v1/infinitus/teams", { headers: Bearer, success: Schema.Array(TeamListRow) }),
    HttpApiEndpoint.post("createTeam", "/v1/infinitus/teams", { headers: Bearer, payload: TeamCreateRequest, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("joinTeam", "/v1/infinitus/team-join", { headers: Bearer, payload: TeamJoinRequest, success: TeamJoinResponse, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.get("getTeam", "/v1/infinitus/teams/:teamId", { headers: Bearer, params: teamParams, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.put("updateMe", "/v1/infinitus/teams/:teamId/me", { headers: Bearer, params: teamParams, payload: TeamMeUpdate, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("leaveTeam", "/v1/infinitus/teams/:teamId/leave", { headers: Bearer, params: teamParams, success: TeamOk, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("createInvite", "/v1/infinitus/teams/:teamId/invites", { headers: Bearer, params: teamParams, payload: TeamInviteCreate, success: TeamInviteCreated, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.delete("revokeInvite", "/v1/infinitus/teams/:teamId/invites/:inviteId", { headers: Bearer, params: Schema.Struct({ teamId: TeamId, inviteId: Schema.String }), success: TeamOk, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("approveRequest", "/v1/infinitus/teams/:teamId/requests/:userId/approve", { headers: Bearer, params: memberParams, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("declineRequest", "/v1/infinitus/teams/:teamId/requests/:userId/decline", { headers: Bearer, params: memberParams, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("promoteMember", "/v1/infinitus/teams/:teamId/members/:userId/promote", { headers: Bearer, params: memberParams, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("demoteMember", "/v1/infinitus/teams/:teamId/members/:userId/demote", { headers: Bearer, params: memberParams, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("removeMember", "/v1/infinitus/teams/:teamId/members/:userId/remove", { headers: Bearer, params: memberParams, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.put("updatePolicy", "/v1/infinitus/teams/:teamId/policy", { headers: Bearer, params: teamParams, payload: TeamPolicyUpdate, success: TeamSnapshot, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.get("listDocuments", "/v1/infinitus/teams/:teamId/documents", { headers: Bearer, params: teamParams, urlParams: Schema.Struct({ userId: Schema.optional(TeamUserId), environmentId: Schema.optional(EnvironmentId), kind: Schema.optional(TeamKind) }), success: Schema.Array(TeamDocumentRow), error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.get("listTranscriptChunks", "/v1/infinitus/teams/:teamId/transcripts/:userId/:environmentId/:threadId", { headers: Bearer, params: Schema.Struct({ teamId: TeamId, userId: TeamUserId, environmentId: EnvironmentId, threadId: Schema.String }), success: Schema.Array(TeamTranscriptChunkRow), error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.get("readTranscriptChunk", "/v1/infinitus/teams/:teamId/transcripts/:userId/:environmentId/:threadId/:seq", { headers: Bearer, params: Schema.Struct({ teamId: TeamId, userId: TeamUserId, environmentId: EnvironmentId, threadId: Schema.String, seq: Schema.NumberFromString }), success: TeamTranscriptChunk, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("createGrant", "/v1/infinitus/teams/:teamId/grants", { headers: Bearer, params: teamParams, payload: TeamGrantCreate, success: TeamGrant, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.delete("revokeGrant", "/v1/infinitus/teams/:teamId/grants/:grantId", { headers: Bearer, params: Schema.Struct({ teamId: TeamId, grantId: Schema.String }), success: TeamOk, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("createCommand", "/v1/infinitus/teams/:teamId/commands", { headers: Bearer, params: teamParams, payload: TeamCommandCreate, success: TeamCommandState, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.get("listPendingCommands", "/v1/infinitus/teams/:teamId/commands", { headers: Bearer, params: teamParams, success: Schema.Array(TeamPendingCommand), error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.get("getCommand", "/v1/infinitus/teams/:teamId/commands/:commandId", { headers: Bearer, params: Schema.Struct({ teamId: TeamId, commandId: Schema.String }), success: TeamCommandState, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("allowCommand", "/v1/infinitus/teams/:teamId/commands/:commandId/allow", { headers: Bearer, params: Schema.Struct({ teamId: TeamId, commandId: Schema.String }), success: TeamCommandState, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("denyCommand", "/v1/infinitus/teams/:teamId/commands/:commandId/deny", { headers: Bearer, params: Schema.Struct({ teamId: TeamId, commandId: Schema.String }), success: TeamCommandState, error: RelayInfinitusTeamRefusedError }),
  )
  .annotate(OpenApi.Description, "Infinitus Team: membership, sharing and delegated control for the signed-in user.");

const envParams = Schema.Struct({ environmentId: EnvironmentId });
export const RelayInfinitusTeamEnvironmentGroup = HttpApiGroup.make("infinitusTeamEnvironment")
  .add(
    HttpApiEndpoint.get("memberships", "/v1/environments/:environmentId/infinitus-team", { headers: Schema.Struct({ ...Bearer.fields, ...TeamUserHeader.fields }), params: envParams, success: TeamEnvironmentMemberships, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("publishDocuments", "/v1/environments/:environmentId/infinitus-team/:teamId/documents", { headers: Bearer, params: Schema.Struct({ environmentId: EnvironmentId, teamId: TeamId }), payload: TeamDocumentsPublish, success: TeamOk, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("publishTranscript", "/v1/environments/:environmentId/infinitus-team/:teamId/transcripts", { headers: Bearer, params: Schema.Struct({ environmentId: EnvironmentId, teamId: TeamId }), payload: TeamTranscriptPublish, success: TeamOk, error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.get("pollCommands", "/v1/environments/:environmentId/infinitus-team/commands", { headers: Schema.Struct({ ...Bearer.fields, ...TeamUserHeader.fields }), params: envParams, success: Schema.Array(TeamQueuedCommand), error: RelayInfinitusTeamRefusedError }),
    HttpApiEndpoint.post("ackCommand", "/v1/environments/:environmentId/infinitus-team/commands/:commandId/ack", { headers: Bearer, params: Schema.Struct({ environmentId: EnvironmentId, commandId: Schema.String }), payload: TeamCommandAck, success: TeamOk, error: RelayInfinitusTeamRefusedError }),
  )
  .annotate(OpenApi.Description, "Infinitus Team: what a linked environment publishes and runs for its user.");
```

Note for the implementer: `relay.ts` already sets `RelayAuthAndInternalErrors` on every endpoint of the groups it owns through the middleware's `failure` schema, so the endpoint `error` above names only the fork's own error. If the checker complains that the middleware's error is not in the union, mirror what `RelayInfinitusAlertGroup` does (`error: RelayAgentActivityPublishErrors`) by importing nothing and instead building the union in `relay.ts` at registration with `HttpApiGroup.addError`.

- [ ] **Step 2: Register in `relay.ts`**

Next to `RelayInfinitusAlertGroup`:

```ts
// Fork (#1592): Team on Infinitus Connect — the client group on the bearer
// auth, the environment group on the environment credential.
import { RelayInfinitusTeamEnvironmentGroup, RelayInfinitusTeamGroup } from "./relayInfinitusTeam.ts";
…
  .add(
    …,
    RelayInfinitusAlertGroup,
    RelayInfinitusTeamGroup.middleware(RelayClientAuth),
    RelayInfinitusTeamEnvironmentGroup.middleware(RelayEnvironmentAuth),
  )
```

Add the `"./relayInfinitusTeam"` subpath to `packages/contracts/package.json` beside `./relayInfinitusAlert`.

- [ ] **Step 3: Test the decode boundaries**

```ts
// packages/contracts/src/relayInfinitusTeam.test.ts
import { describe, expect, it } from "vitest";
import * as Schema from "effect/Schema";
import { TeamInviteCreate, TeamSnapshot, TeamTranscriptPublish, DEFAULT_TEAM_SHARES } from "./relayInfinitusTeam.ts";

describe("relayInfinitusTeam", () => {
  it("clamps invite days to 1..3650", () => {
    const decode = Schema.decodeUnknownSync(TeamInviteCreate);
    expect(() => decode({ days: 0, oneUse: false })).toThrow();
    expect(() => decode({ days: 3651, oneUse: false })).toThrow();
    expect(decode({ days: 7, oneUse: true })).toEqual({ days: 7, oneUse: true });
  });
  it("refuses a transcript chunk over 1 MiB", () => {
    const decode = Schema.decodeUnknownSync(TeamTranscriptPublish);
    expect(() => decode({ userId: "u", threadId: "t", seq: 0, rows: 1, lines: "x".repeat(1_048_577) })).toThrow();
  });
  it("every kind starts off", () => {
    expect(Object.values(DEFAULT_TEAM_SHARES).every((v) => v === "off")).toBe(true);
  });
  it("decodes a snapshot with an opaque now body", () => {
    const decode = Schema.decodeUnknownSync(TeamSnapshot);
    const snap = decode({ teamId: "t", name: "Papaya", role: "leader", policy: { requests: "code" }, me: { name: "Loc", shares: DEFAULT_TEAM_SHARES },
      members: [{ userId: "u", name: "Loc", role: "leader", founder: true, since: "2026-09-25T00:00:00Z", machines: [{ environmentId: "e", label: "Mac", now: { at: 1 }, lastPublished: null }] }],
      requests: [], invites: [], grants: [], pending: [], grantsToMe: [] });
    expect(snap.members[0]?.machines[0]?.now).toEqual({ at: 1 });
  });
});
```

Run: `vp test run packages/contracts/src/relayInfinitusTeam.test.ts` → PASS. Typecheck: `cd packages/contracts && npx tsc --noEmit -p .` (or the package's `typecheck` script).

- [ ] **Step 4: Commit** `feat(contracts): the relay's Infinitus Team groups (#1592)`

### Task 2.2: Schema, migration, bucket

**Files:**
- Create: `infra/relay/src/infinitusTeam/schema.ts`
- Modify: `infra/relay/src/persistence/schema.ts` (last line: `export * from "../infinitusTeam/schema.ts";` with a `// Fork (#1592)` comment)
- Modify: `infra/relay/src/worker.ts` (bucket resource + binding, the `Layer.mergeAll(AgentActivityPublisher.layer, InfinitusAlertPublisher.layer…)` stage gains the team layers, the cron gains the prune, `relayApiLayer` gains the two handlers — Tasks 2.5/2.6 fill the layers; this task adds the bucket only)
- Create: `infra/relay/migrations/postgres/<ts>_infinitus_team/{migration.sql,snapshot.json}` (generated)

- [ ] **Step 1: Write the Drizzle schema**

```ts
// infra/relay/src/infinitusTeam/schema.ts
import { boolean, index, integer, jsonb, pgTable, primaryKey, text, uniqueIndex, varchar } from "drizzle-orm/pg-core";

/** Team on Infinitus Connect (#1592). Times are ISO strings like the rest of
    the relay schema; ids are uuids the relay mints. */
export const infinitusTeams = pgTable("infinitus_teams", {
  teamId: varchar("team_id", { length: 36 }).primaryKey(),
  name: varchar("name", { length: 64 }).notNull(),
  founderUserId: varchar("founder_user_id", { length: 191 }).notNull(),
  policyRequests: varchar("policy_requests", { length: 8 }).notNull().default("code"),
  createdAt: varchar("created_at", { length: 64 }).notNull(),
  updatedAt: varchar("updated_at", { length: 64 }).notNull(),
});

export const infinitusTeamMembers = pgTable("infinitus_team_members", {
  teamId: varchar("team_id", { length: 36 }).notNull(),
  userId: varchar("user_id", { length: 191 }).notNull(),
  role: varchar("role", { length: 8 }).notNull(),
  name: varchar("name", { length: 64 }).notNull(),
  sharesJson: jsonb("shares_json").$type<Record<string, string>>().notNull(),
  since: varchar("since", { length: 64 }).notNull(),
  updatedAt: varchar("updated_at", { length: 64 }).notNull(),
}, (t) => [primaryKey({ columns: [t.teamId, t.userId] }), index("infinitus_team_members_user_idx").on(t.userId)]);

export const infinitusTeamInvites = pgTable("infinitus_team_invites", {
  inviteId: varchar("invite_id", { length: 36 }).primaryKey(),
  teamId: varchar("team_id", { length: 36 }).notNull(),
  tokenHash: varchar("token_hash", { length: 64 }).notNull(),
  createdByUserId: varchar("created_by_user_id", { length: 191 }).notNull(),
  oneUse: boolean("one_use").notNull(),
  usedByUserId: varchar("used_by_user_id", { length: 191 }),
  expiresAt: varchar("expires_at", { length: 64 }).notNull(),
  revokedAt: varchar("revoked_at", { length: 64 }),
  createdAt: varchar("created_at", { length: 64 }).notNull(),
}, (t) => [uniqueIndex("infinitus_team_invites_token_hash").on(t.tokenHash), index("infinitus_team_invites_team_idx").on(t.teamId)]);

export const infinitusTeamRequests = pgTable("infinitus_team_requests", {
  teamId: varchar("team_id", { length: 36 }).notNull(),
  userId: varchar("user_id", { length: 191 }).notNull(),
  name: varchar("name", { length: 64 }).notNull(),
  inviteId: varchar("invite_id", { length: 36 }).notNull(),
  createdAt: varchar("created_at", { length: 64 }).notNull(),
}, (t) => [primaryKey({ columns: [t.teamId, t.userId] })]);

export const infinitusTeamDocuments = pgTable("infinitus_team_documents", {
  teamId: varchar("team_id", { length: 36 }).notNull(),
  userId: varchar("user_id", { length: 191 }).notNull(),
  environmentId: varchar("environment_id", { length: 191 }).notNull(),
  kind: varchar("kind", { length: 16 }).notNull(),
  key: varchar("key", { length: 32 }).notNull(),
  bodyJson: jsonb("body_json").$type<unknown>().notNull(),
  updatedAt: varchar("updated_at", { length: 64 }).notNull(),
}, (t) => [primaryKey({ columns: [t.teamId, t.userId, t.environmentId, t.kind, t.key] }), index("infinitus_team_documents_team_kind_idx").on(t.teamId, t.kind)]);

export const infinitusTeamTranscripts = pgTable("infinitus_team_transcripts", {
  teamId: varchar("team_id", { length: 36 }).notNull(),
  userId: varchar("user_id", { length: 191 }).notNull(),
  environmentId: varchar("environment_id", { length: 191 }).notNull(),
  threadId: varchar("thread_id", { length: 512 }).notNull(),
  seq: integer("seq").notNull(),
  rows: integer("rows").notNull(),
  bytes: integer("bytes").notNull(),
  objectKey: text("object_key").notNull(),
  createdAt: varchar("created_at", { length: 64 }).notNull(),
}, (t) => [primaryKey({ columns: [t.teamId, t.userId, t.environmentId, t.threadId, t.seq] }), index("infinitus_team_transcripts_member_idx").on(t.teamId, t.userId, t.createdAt)]);

export const infinitusTeamGrants = pgTable("infinitus_team_grants", {
  grantId: varchar("grant_id", { length: 36 }).primaryKey(),
  teamId: varchar("team_id", { length: 36 }).notNull(),
  userId: varchar("user_id", { length: 191 }).notNull(),
  environmentId: varchar("environment_id", { length: 191 }).notNull(),
  audienceJson: jsonb("audience_json").$type<unknown>().notNull(),
  threadsJson: jsonb("threads_json").$type<unknown>().notNull(),
  capabilitiesJson: jsonb("capabilities_json").$type<string[]>().notNull(),
  preauthorizedJson: jsonb("preauthorized_json").$type<string[]>().notNull(),
  expiresAt: varchar("expires_at", { length: 64 }),
  createdAt: varchar("created_at", { length: 64 }).notNull(),
}, (t) => [index("infinitus_team_grants_env_idx").on(t.teamId, t.environmentId)]);

export const infinitusTeamCommands = pgTable("infinitus_team_commands", {
  commandId: varchar("command_id", { length: 36 }).primaryKey(),
  teamId: varchar("team_id", { length: 36 }).notNull(),
  fromUserId: varchar("from_user_id", { length: 191 }).notNull(),
  toUserId: varchar("to_user_id", { length: 191 }).notNull(),
  environmentId: varchar("environment_id", { length: 191 }).notNull(),
  threadId: varchar("thread_id", { length: 512 }).notNull(),
  action: varchar("action", { length: 16 }).notNull(),
  text: text("text"),
  project: varchar("project", { length: 256 }),
  status: varchar("status", { length: 16 }).notNull(),
  ackJson: jsonb("ack_json").$type<unknown>(),
  createdAt: varchar("created_at", { length: 64 }).notNull(),
  expiresAt: varchar("expires_at", { length: 64 }).notNull(),
  answeredAt: varchar("answered_at", { length: 64 }),
}, (t) => [index("infinitus_team_commands_env_status_idx").on(t.environmentId, t.status), index("infinitus_team_commands_from_idx").on(t.fromUserId, t.createdAt)]);
```

- [ ] **Step 2: Generate the migration** (from `infra/relay`): `npx drizzle-kit generate --dialect postgresql --schema ./src/persistence/schema.ts --out ./migrations/postgres --name infinitus_team`. Check the SQL creates eight tables and nothing else. Commit both files.

- [ ] **Step 3: Declare the bucket in `worker.ts`**

```ts
// Fork (#1592): transcript chunks live in R2, one row per chunk in Postgres.
const InfinitusTeamTranscriptsBucket = Cloudflare.R2.Bucket("InfinitusTeamTranscripts").pipe(RemovalPolicy.retain());
…
    const teamTranscriptsBucket = yield* InfinitusTeamTranscriptsBucket;
    const teamTranscriptsBinding = yield* Cloudflare.R2.ReadWriteBucket(teamTranscriptsBucket);
```

(`RemovalPolicy` is imported as `alchemy/RemovalPolicy` in `db.ts`; do the same.) The binding is handed to `InfinitusTeamTranscriptStore.layer(teamTranscriptsBinding)` in Task 2.6.

- [ ] **Step 4: Commit** `feat(relay): Infinitus Team tables and transcript bucket (#1592)`

### Task 2.3: Store

**Files:**
- Create: `infra/relay/src/infinitusTeam/InfinitusTeamStore.ts`
- Test: `infra/relay/src/infinitusTeam/InfinitusTeamStore.test.ts` (a fake `RelayDb` as `EnvironmentLinks.test.ts` does: assert the table each query targets and the persistence error's fields; no real Postgres)

**Interfaces:**
- Produces `InfinitusTeamStore` (`Context.Service`) with, every method failing `InfinitusTeamPersistenceError {op, cause}`:

```ts
readonly getTeam: (teamId) => Effect<TeamRecord | null>;
readonly createTeam: (input: {teamId, name, founderUserId, now}) => Effect<void>;
readonly updateTeamPolicy: (teamId, requests, now) => Effect<void>;
readonly listTeamsForUser: (userId) => Effect<ReadonlyArray<{teamId, name, role}>>;
readonly listMembers: (teamId) => Effect<ReadonlyArray<MemberRecord>>;
readonly getMember: (teamId, userId) => Effect<MemberRecord | null>;
readonly upsertMember: (input: {teamId, userId, role, name, shares, since, now}) => Effect<void>;
readonly updateMember: (teamId, userId, patch: {name?, shares?, role?}, now) => Effect<void>;
readonly deleteMember: (teamId, userId) => Effect<void>;   // cascades documents, transcripts rows, grants, commands, requests
readonly createInvite: (input: {inviteId, teamId, tokenHash, createdByUserId, oneUse, expiresAt, now}) => Effect<void>;
readonly getInviteByHash: (tokenHash) => Effect<InviteRecord | null>;
readonly markInviteUsed: (inviteId, userId) => Effect<void>;
readonly revokeInvite: (teamId, inviteId, now) => Effect<boolean>;
readonly listInvites: (teamId) => Effect<ReadonlyArray<InviteRecord>>;
readonly upsertRequest: (input: {teamId, userId, name, inviteId, now}) => Effect<void>;
readonly listRequests: (teamId) => Effect<ReadonlyArray<RequestRecord>>;
readonly deleteRequest: (teamId, userId) => Effect<void>;
readonly upsertDocuments: (input: {teamId, userId, environmentId, documents: ReadonlyArray<{kind, key, body}>, now}) => Effect<void>;
readonly listDocuments: (input: {teamId, userId?, environmentId?, kind?}) => Effect<ReadonlyArray<DocumentRecord>>;
readonly insertTranscriptChunk: (input: {teamId, userId, environmentId, threadId, seq, rows, bytes, objectKey, now}) => Effect<void>;
readonly listTranscriptChunks: (input: {teamId, userId, environmentId, threadId}) => Effect<ReadonlyArray<TranscriptRecord>>;
readonly transcriptCursors: (teamId, userId, environmentId) => Effect<ReadonlyArray<{threadId, rows, nextSeq}>>;
readonly transcriptsToPrune: (input: {olderThan: string, perMemberBytes: number}) => Effect<ReadonlyArray<TranscriptRecord>>;
readonly deleteTranscriptChunks: (keys: ReadonlyArray<{teamId, userId, environmentId, threadId, seq}>) => Effect<void>;
readonly createGrant / listGrantsForEnvironment(teamId, environmentId) / listGrantsForUser(teamId, userId) / listGrantsToUser(teamId, userId, role) / deleteGrant(teamId, grantId, userId) => Effect<boolean>;
readonly createCommand / getCommand(commandId) / listQueuedForEnvironment(environmentId, now) (also flips them to running) / listPendingForUser(teamId, toUserId) / updateCommand(commandId, patch: {status, ack?, answeredAt?}) / expireCommands(now);
```

- [ ] **Step 1: Write two persistence tests** (lookup failure keeps ids, list targets the right table), run to see them fail on the missing module, implement the store with Drizzle (`eq`, `and`, `inArray`, `lt`, `isNull` from `drizzle-orm`; `onConflictDoUpdate` for upserts as `EnvironmentLinks.upsert` does; `listQueuedForEnvironment` does `update … set status='running' where environment_id=? and status='queued' and expires_at > now returning *`), run them green.

- [ ] **Step 2: Commit** `feat(relay): Infinitus Team store (#1592)`

### Task 2.4: Team service (the rules)

**Files:**
- Create: `infra/relay/src/infinitusTeam/InfinitusTeamService.ts`
- Create: `infra/relay/src/infinitusTeam/inMemoryStore.ts` (test double implementing `InfinitusTeamStore` over Maps; also used by Tasks 2.5–2.6)
- Test: `infra/relay/src/infinitusTeam/InfinitusTeamService.test.ts`

**Interfaces:**
- Consumes `InfinitusTeamStore`, `EnvironmentLinks` (labels for machines, link check for the environment side), `Crypto.Crypto` (uuids, tokens), `DateTime`.
- Produces `InfinitusTeamService` with one method per route in spec §4.2 taking `{userId, …}` and failing `TeamRefused {reason}` (mapped to `RelayInfinitusTeamRefusedError` by the API layer) or `InfinitusTeamPersistenceError`. Plus `snapshot(teamId, userId)`.

Rules to encode, each with a test (names are the `it` titles):

- `create makes the caller the founding leader with shares off`
- `join with a one-use token joins at once and spends it` → status `member`; second join with the same token → `TeamRefused("This invite was already used.")` (test `one-use token spent`)
- `join with a reusable token creates a request` → status `pending`; approve → member; decline → request gone
- `policy off refuses joins` and refuses `createInvite` (`"This team is not taking requests."`)
- `expired token refused`; `revoked invite refused`
- `join by an existing member answers their status`
- `last leader cannot leave`; `last leader cannot be demoted`; `founder cannot be removed`; `a member cannot promote`
- `snapshot hides requests and invites from members`; `invite token never in a snapshot`
- `listDocuments honours share × role`: publisher `team` → member sees; `leaders` → member does not, leader does, publisher does; `off hides existing documents` (rows stay, the read returns none)
- `now older than ten minutes is offline` (`snapshot` folds `now` into machines only when `updatedAt` ≥ now − 10 min; older → `now: undefined`, `lastPublished` kept)
- `two machines fold under one member` (two environments, one user → one member row, two machines; label from the link)
- `transcript read requires the transcripts share`
- `createCommand checks the grant`: audience (`team`, `leaders`, explicit ids), threads (`all` or id), capability, expiry → else `TeamRefused("… has not let you do that.")`; `interrupt`/`new` not preauthorized → status `pending`, else `queued`; `allow` flips `pending` → `queued`; `deny` → `denied`; TTL 120 s on pending, 600 s on queued
- `revoked grant refuses a queued command` (`pollCommands` re-checks the grant and answers the command `refused` itself instead of returning it)
- `removeMember deletes their documents, transcripts, grants and commands`
- `environment memberships need a live link for that user, environment and key`

The token: 32 random bytes, base64url, `tokenHash = base64url(sha256(token))`; the link is `https://infinitus.run/join#<token>` built by the clients, never by the relay.

- [ ] **Step 1: Write the in-memory store and the failing tests** (`@effect/vitest` `it.effect`, provide `InfinitusTeamService.layer` over `inMemoryStore.layer` and a fake `EnvironmentLinks` layer returning fixed labels/links).
- [ ] **Step 2: Implement the service until green.** Run: `cd infra/relay && vp test run src/infinitusTeam/InfinitusTeamService.test.ts`.
- [ ] **Step 3: Commit** `feat(relay): Infinitus Team rules (#1592)`

### Task 2.5: Client API handlers

**Files:**
- Create: `infra/relay/src/infinitusTeam/InfinitusTeamApi.ts`
- Modify: `infra/relay/src/worker.ts` (`relayApiLayer` gains `infinitusTeamApi`; the runtime `Layer.mergeAll(AgentActivityPublisher.layer, InfinitusAlertPublisher.layer…)` stage gains `InfinitusTeamService.layer.pipe(Layer.provide(InfinitusTeamStore.layer))`)
- Test: `infra/relay/src/infinitusTeam/InfinitusTeamApi.test.ts`

Pattern: `HttpApiBuilder.group(RelayApi, "infinitusTeam", …)` exactly as `InfinitusAlertApi.ts`; each handler reads `RelayClientPrincipal`, calls the service, maps `TeamRefused` → `RelayInfinitusTeamRefusedError({code: "infinitus_team_refused", reason, traceId})` and persistence errors → `RelayInternalError`. Test through `HttpApiBuilder.toWebHandler` with a stub `RelayClientAuth` layer that provides a fixed principal (see how `Api.test.ts` builds its handler), covering: create → 200 snapshot; join with a bad token → 409 with the reason in the body; a member calling `createInvite` → 409.

- [ ] Steps: failing handler test → implement → green → commit `feat(relay): Infinitus Team client routes (#1592)`.

### Task 2.6: Environment handlers, transcript bucket, prune

**Files:**
- Create: `infra/relay/src/infinitusTeam/InfinitusTeamTranscriptStore.ts` (`Context.Service` over the R2 `ReadWriteBucketClient`: `put(key, text)`, `get(key) → string | null`, `delete(keys)`; `layer(binding)`; an in-memory layer for tests)
- Create: `infra/relay/src/infinitusTeam/InfinitusTeamEnvironmentApi.ts`
- Create: `infra/relay/src/infinitusTeam/InfinitusTeamPrune.ts` (`prune(now)`: expire commands, delete transcript rows + objects past 90 days or beyond 200 MB per member)
- Modify: `infra/relay/src/worker.ts` (cron: `yield* InfinitusTeamPrune.prune` beside the DPoP prune; `relayApiLayer` gains `infinitusTeamEnvironmentApi`)
- Test: `InfinitusTeamEnvironmentApi.test.ts`, `InfinitusTeamPrune.test.ts`

Environment handlers read `RelayEnvironmentPrincipal`, require `params.environmentId === principal.environmentId`, take `userId` from the payload or the `x-infinitus-user` header, and call `service.assertEnvironmentUser({userId, environmentId, environmentPublicKey})` before anything (Task 2.4's last rule). `publishTranscript` refuses when the member's `transcripts` share is `off` (`"Transcripts are not shared."`), requires `seq === nextSeq`, writes the object then the row. `pollCommands` returns the queued commands with their grant and flips them `running`. `ackCommand` with outcome `pending` sets status `pending` and `expiresAt = now + 120 s`; any other outcome sets `done`/`refused` and `answeredAt`.

Tests: `publish refuses a foreign user`, `transcript refused when shared off`, `transcript seq must be next`, `poll flips queued to running`, `prune deletes objects with rows` (in-memory bucket sees the delete), `prune expires commands`.

- [ ] Steps: failing tests → implement → green → `cd infra/relay && npx tsc --noEmit` → commit `feat(relay): Infinitus Team environment routes, transcripts and prune (#1592)`.

### Task 2.7: Ledgers, changelog, PR

- [ ] `docs/internals/fork-only-files.md`: one bullet for `packages/contracts/src/relayInfinitusTeam.ts` + `infra/relay/src/infinitusTeam/` pointing at the spec. `docs/internals/fork-registration-points.md`: extend the `packages/contracts/src/relay.ts`, `infra/relay/src/worker.ts` bullet (line ~476) with the team groups, the bucket and the prune; add `infra/relay/src/persistence/schema.ts` (the re-export line); `packages/contracts/package.json` (the subpath).
- [ ] `apps/mac/changelog.d/<pr>.md`: `Connect: teams live on Infinitus Connect — the relay holds members, invites, what each member shares and their transcripts (#1592).`
- [ ] `docs/operations/connect-setup.md`: a paragraph under the Cloudflare token: `Workers R2 Storage Read + Write` for the deploy token; R2 needs a payment method on the account.
- [ ] Open the PR (`gh pr create --base main --draft`, title `feat(relay): Infinitus Team on the relay — tables, routes, transcripts (#1592)`), body: problem, how, "Human step before merge: R2 on the deploy token". Mark ready and arm auto-merge once the owner confirms the token; after merge, watch `deploy-relay.yml` (`gh run watch`) and comment the result on #1592. Slice 3 waits for green.

---

## Slice 3 — Server and Mac (one PR: `infinitus/team-server`)

### Task 3.1: Shared redaction

**Files:**
- Create: `packages/shared/src/infinitusTeamRedaction.ts`, `packages/shared/src/infinitusTeamRedaction.test.ts`
- Modify: `packages/shared/package.json` (subpath export)

Port `TeamRedaction.swift` rule for rule (the eight rules, the home rule, the image rule; the `B` leading boundary `(^|[^A-Za-z0-9_]|\\[nrt])`; order preserved). Export `redactTranscriptLine(line: string, options: {home: string; includeImages?: boolean}): string` and `makeRedactor(options)`. The test file carries every fixture pair from `TeamRedactionTests.swift` `testFixtures` verbatim, plus `prefilter folds case`, `images dropped unless included`, `redacted JSON stays JSON`. Skip the byte-needle prefilter unless the test's 10k-line loop takes over a second.

- [ ] failing tests → port → green → commit `feat(shared): transcript redaction for Team (#1592)`.

### Task 3.2: The publisher

**Files:**
- Create: `apps/server/src/infinitus/Services/InfinitusTeamRelay.ts` (service tag: `start: () => Effect<void, never, Scope>`, `publishNow: Effect<void>` for tests and a future verb)
- Create: `apps/server/src/infinitus/Layers/infinitusTeamRelay.logic.ts` (pure): `buildNowDocument`, `buildThreadsDocument`, `buildFleetDocument`, `threadStatus`, `transcriptRows`, `chunkLines`, `dayDigest`
- Create: `apps/server/src/infinitus/Layers/InfinitusTeamRelay.ts` (`InfinitusTeamRelayLive`)
- Modify: `apps/server/src/server.ts` (`ReactorLayerLive` gains the layer with its own `InfinitusControlClientLive`, `ServerSecretStore.layer`, `FetchHttpClient.layer`, as `InfinitusSignInLapseLive` does)
- Modify: `apps/server/src/orchestration/Layers/OrchestrationReactor.ts` (`yield* infinitusTeamRelay.start()` after `agentAwarenessRelay.start()`)
- Test: `infinitusTeamRelay.logic.test.ts`, `InfinitusTeamRelay.test.ts`

**Interfaces:**
- Consumes: `ServerSecretStore` (`RELAY_URL_SECRET`, `RELAY_ENVIRONMENT_CREDENTIAL_SECRET`, `cloud-linked-user-id` via `readInstalledCloudUserId` in `cloud/http.ts` — export it if private), `ServerEnvironment.getEnvironmentId`, `ProjectionSnapshotQuery.getShellSnapshot / getThreadDetailSnapshot`, `InfinitusService.snapshot` and `.command({command: "team-days", args: [], options: {days: "30"}})`, `HttpClient`, `Crypto`.
- Produces documents whose bodies are the spec §5 table. `now.live` rows: `{id, title, project, startedAt, activityLine}` from shells whose `latestTurn.state` is `starting`/`running`, or `waiting` with `activityLine` "Waiting for input"/"Waiting for approval" (port `TeamThreadSources.status`). `fleet` rows port `TeamFleetDoc.row` over `InfinitusFleet`/`InfinitusAccount`: label = alias or `#n`, never the email; status `held | expiredLogin | dead | limited | ok` (limited at ≥ 90 %); windows from `usage.fiveHour`/`sevenDay`/`scoped` when present (usage is `Unknown` on the contract: decode the three fields defensively, skip what is missing).

Loop (`start`): `forkParked` a fiber that every 60 s: reads the link (unlinked → sleep), `GET memberships` with the header, for each team: publish `now` unless `off`; every fifth cycle also `fleet`, `threads`, `stats` (each unless `off`, stats one document per day whose `dayDigest` changed since the last send, held in a `Ref<Map>`), transcripts (threads updated in the last 30 days, not excluded, `transcripts` share on; rows after the relay's cursor for that thread, redacted with `home = os.homedir()`, chunked ≤ 1 MiB, one `publishTranscript` per chunk in order). Every 15 s, while any team lists a grant for this environment: `pollCommands` (Task 3.3). All failures logged at warning with the stage, never thrown out of the loop.

Tests (logic): `now lists running and waiting threads with lines`, `threads index newest first capped at 500 with basenames only`, `fleet never carries an email`, `excluded project drops its thread, live row and transcript`, `chunks never split a line and stay under 1 MiB`, `day digest ignores key order`. Tests (layer): a stub relay `HttpClient` recording requests + stub query/services: `skips kinds shared off`, `unlinked publishes nothing`, `stats publishes only changed days`, `transcript cursor resumes after the relay's rows`, `Mac unavailable still publishes now with empty fleets`.

- [ ] failing tests → implement → green → `cd apps/server && npx tsc --noEmit` → commit `feat(server): the Team publisher on the relay (#1592)`.

### Task 3.3: Command executor

**Files:**
- Modify: `apps/server/src/infinitus/Layers/InfinitusTeamRelay.ts` (the poll + execute half), `infinitusTeamRelay.logic.ts` (`decideCommand(grant, command, liveThreadIds) → {run: true} | {outcome, detail}`)
- Test: additions to both test files

Execution mirrors `InfinitusSlack.ts`: `send` → `orchestrationEngine.dispatch({type: "thread.turn.start", …, message: {role: "user", text}})`; `interrupt` → `thread.turn.interrupt`; `new` → `thread.create` for the project whose title or id matches, then `thread.turn.start`; `view` → `getThreadDetailSnapshot(threadId, {turnLimit: 20})` flattened to `{role, text}` rows through the redactor, joined and capped at 4096 chars in `result`. Local re-check before running: the grant is still in the last memberships reply (`revoked grant refuses a queued command` — the reply lists grants; a command whose `grant.grantId` is not listed is acked `refused`), thread live for `send`/`interrupt` (`notLive` otherwise). `interrupt`/`new` outside `preauthorized` → ack `pending` and stop; the relay re-queues on allow.

Tests: `decideCommand` table (each outcome), layer: `runs a send through the engine and acks done`, `pending is acked and not run`, `revoked grant refuses a queued command`.

- [ ] failing tests → implement → green → commit `feat(server): teammates' commands run from the relay queue (#1592)`.

### Task 3.4: Mac verbs `team-days` and `team-exclusions`

**Files:**
- Create: `apps/mac/Sources/Infinitus/TeamDays.swift` (app target): owns the fold memo — takes `TeamModel`'s hooks (`scanEntries`, `scanGeneration`, `scanConsumed`, `scanRequested`, `ownsScan`) and `fold(days: Int) -> (days: [String: Stats.Day], exclusions: [String], generation: Int)?` which returns the memo when its generation, exclusions and floor day match, folds and hands the table back otherwise, or asks for a scan and returns nil.
- Modify: `apps/mac/Sources/InfinitusCore/ControlProtocol.swift` (manifest: `team-days --days <n>` read `{days, exclusions, generation}`; `team-exclusions` read `{projects}`; `team-exclude` unchanged), `ControlServer.swift` (the three cases; `team-days` answers `Stats.Day.compacted()` per day), `AppModel.swift:895-909` (wire `TeamDays` instead of `team`), `StatsModel.swift` (`scanFeedsTeam` now asks `TeamDays`).
- Test: `apps/mac/Tests/InfinitusTests/TeamDaysTests.swift` (a scan fixture with one excluded project: the fold drops it, the second call answers from the memo without a fold, a changed exclusion refolds).
- Verify: `cd apps/mac && swift build && swift test --filter TeamDaysTests`; the e2e (`/bin/sh tools/e2e.sh`) still passes its team round until slice 6 removes it — this task leaves the old verbs in place.

- [ ] failing test → implement → green → commit `feat(mac): team-days answers the folded stats days for the desktop's Team publisher (#1592)`.

### Task 3.5: Contracts for the Mac verbs, ledgers, changelog, PR

- [ ] `packages/contracts/src/infinitus.ts`: `InfinitusTeamDays` (`{days: Record<string, unknown>, exclusions: string[], generation: number}`) and `InfinitusTeamExclusions`; the server decodes at the boundary.
- [ ] Ledgers: fork-only bullets for the three server files and `TeamDays.swift`; registration bullets for `server.ts` (the new stage), `OrchestrationReactor.ts` (the start line), `packages/shared/package.json`.
- [ ] Changelog fragment: `Desktop: this machine's threads, fleet and stats reach your team through Infinitus Connect, and teammates you grant can send to, view, interrupt or start your threads from there (#1592).`
- [ ] PR `feat(server,mac): the Team publisher and command runner on Infinitus Connect (#1592)`; auto-merge.

---

## Slice 4 — Web (one PR: `infinitus/team-web`)

### Task 4.1: Shared client and fold

**Files:**
- Create: `packages/client-runtime/src/relay/infinitusTeam.ts`: `makeInfinitusTeamClient({relayUrl, readClerkToken: () => Promise<string | null>}): InfinitusTeamClient` — one method per client route, each an `Effect` that reads the token (fails `InfinitusTeamSignedOut` when null), builds `HttpApiClient.make(RelayApi, {baseUrl, transformClient: setHeader authorization Bearer})` and calls `client.infinitusTeam.<route>`; `RelayInfinitusTeamRefusedError` surfaces as `InfinitusTeamRefused {reason}`.
- Create: `packages/client-runtime/src/relay/infinitusTeam.logic.ts`: `parseJoinInput(text) → token | null` (bare token, `infinitus://join/<t>`, `https://infinitus.run/join#<t>`, URI-decoded, trimmed), `buildJoinLink(token)`, `memberSummary(member, now)` ("2 machines · 3 live · last published 4 min ago"), `machineIsOnline(machine, now)` (10 min), `foldSnapshot(snapshot, now)` → the row model both panes render.
- Tests: `infinitusTeam.logic.test.ts` (the three join shapes and a garbage string; online/offline; summary lines).
- Modify: `packages/client-runtime/package.json` subpath exports.

- [ ] failing tests → implement → green → commit `feat(client-runtime): the Team relay client and snapshot fold (#1592)`.

### Task 4.2: Settings › Team

**Files:**
- Rewrite: `apps/web/src/components/settings/infinitus/InfinitusTeamPanel.tsx`, `team.logic.ts` (now thin: `useInfinitusTeamClient()` from `useAuth().getToken(resolveRelayClerkTokenOptions())` + the relay URL from `apps/web/src/cloud/publicConfig.ts`; the exclusions half keeps `infinitusEnvironment.command` for `team-exclusions` / `team-exclude`, gated on the manifest)
- Keep: `apps/web/src/routes/settings.team.tsx`, `deepLinks/pendingTeamJoin.ts`, `DeepLinkCoordinator.tsx` (the `join` link lands on the pane; the pane runs `parseJoinInput` on it)
- Modify: `apps/web/src/components/settings/settingsSearch.ts` items for the sections that changed (Teams, Invites, Grants).
- Test: `team.logic.test.ts` (rewritten: signed-out state, refusal reason passthrough).

Sections per spec §6.1, in order: signed-out card (button from `useInfinitusConnectAuthPrompt`), team picker (when > 1), Members (expand → threads index from `listDocuments kind=threads`; a thread → transcript chunks via `listTranscriptChunks` then `readTranscriptChunk`, rendered as plain rows), Requests, Invites, Sharing, Policy, Grants + Waiting for you, Private projects (Mac verbs), Leave, Join, Create. Every relay error shows `reason` verbatim in `InfinitusPanelNotice`. UI components come from `components/ui` with their variants (lint `shadcn/no-restyle`).

- [ ] implement → `vp test run apps/web/src/components/settings/infinitus/team.logic.test.ts` → `cd apps/web && npx tsc --noEmit` → lint the two files → the fork visual pass route (`fork-visual-routes.ts`: the marker becomes "Members" over a fixture snapshot; update the fixture) → commit `feat(web): Settings › Team on Infinitus Connect (#1592)`.

### Task 4.3: Ledgers, changelog, PR

- [ ] Ledger bullets (client-runtime files fork-only; web files already listed — update their lines). Fragment: `Desktop: Settings › Team creates, joins and manages a team through Infinitus Connect; teammates' threads and shared transcripts open from the member list (#1592).` PR `feat(web): Settings › Team on Infinitus Connect (#1592)`; before/after screenshots per AGENTS.md.

---

## Slice 5 — Phone (one PR: `infinitus/team-phone`)

### Task 5.1: Settings › Team on the relay client

**Files:**
- Rewrite: `apps/mobile/src/features/team/TeamRouteScreen.tsx`, `team.logic.ts` (keeps `teamJoinCode`'s link rewrite, now `parseJoinInput`; drops the per-Mac sections; a `useInfinitusTeamClient()` over `CloudAuthProvider`'s token provider — expose `useCloudRelayTokenProvider()` from `CloudAuthProvider.tsx` — and `apps/mobile/src/features/cloud/publicConfig.ts`'s relay URL)
- Keep: `App.tsx` link rewrite, `Stack.tsx` route, `settings-sheet-targets.ts`, the Android intent filter.
- Test: `team.logic.test.ts` (link rewrite unchanged; join parsing; signed-out fold).

Screen: signed-out card (the Connect onboarding route's sign-in), teams list, Join, Members with machines and live threads, Requests (leaders), Waiting for you with Allow/Deny. No Create, Sharing, Grants, transcripts.

- [ ] implement → tests → `cd apps/mobile && npx tsc --noEmit` → commit `feat(mobile): Settings › Team on Infinitus Connect (#1592)` → fragment `Phone: Settings › Team joins a team and approves requests as you, through Infinitus Connect, with no Mac in the loop (#1592).` → PR.

---

## Slice 6 — Removal (one PR: `infinitus/team-git-store-removal`)

### Task 6.1: Mac

- [ ] Delete `apps/mac/Sources/InfinitusCore/Team/*` except `TeamExclusions.swift`, `TeamPaths.swift`; delete `Sources/Infinitus/TeamModel.swift`, `TeamSecretsKeychain.swift`, `Sources/InfinitusCLI/TeamCommand.swift`, `Sources/CZlib/`; drop `CZlib` from `Package.swift` (verify `Deflate.swift` was the only consumer); drop `team` from `main.swift`'s subcommands and stdin list; drop the sixteen verbs (keep `team-days`, `team-exclusions`, `team-exclude`) from `ControlProtocol.swift` / `ControlServer.swift`; delete the Team tests except `TeamDaysTests`; delete the e2e team round (`tools/e2e.sh` lines 545–575) and `INFINITUS_TEAM_DIR`; `ci.yml` line 432: collapse the two-half `mac-test` back to one job if the Team suites were the reason (keep the `mac-test` name).
- [ ] `swift build`, `swift test`, `/bin/sh tools/e2e.sh` green. Commit `refactor(mac): the git-store Team leaves; team-days and the private-project list stay (#1592)`.

### Task 6.2: Server, contracts, docs

- [ ] Delete `apps/server/src/infinitus/Layers/InfinitusTeamControlHttp.ts` (+ test), `packages/contracts/src/infinitusTeamControl.ts` (+ subpath), the `infinitusTeamControl` group from `environmentHttp.ts` and its layer from `server.ts`; delete `InfinitusTeamSnapshot`, `InfinitusTeamMember`, `InfinitusTeamGrant`, `InfinitusTeamPending`, `InfinitusTeamRequest`, `InfinitusTeamCode`, `InfinitusTeamInsights` from `infinitus.ts` (+ their tests); drop `team-join` from `STANDARD_CLIENT_SECRET_VERBS` in `InfinitusSecret.ts` and the team verbs from `docs/internals/infinitus-secret.md`; `join.html`: the forwarder keeps working (the token is opaque) — remove the "paste into Settings › Team" double-prefix by forwarding `decodeURIComponent(code)`; ledgers: remove the git-store bullets, `phone-app-bridges.md`'s team paragraph rewritten; INFINITUS.md unchanged (no team paragraph there).
- [ ] Targeted typecheck of server, contracts, web, mobile; `vp test run` on the touched test files. Commit `refactor: the git-store Team's routes, contracts and docs leave (#1592)`. Fragment: `Connect: the git-store Team is gone — a team is on Infinitus Connect now; old team folders on this Mac are left untouched and unread (#1592).` PR, auto-merge, close #1313 with a comment pointing at #1592.

---

## Self-review

- Spec coverage: §3 identity/membership → 2.4; §4.1 tables/bucket/retention → 2.2, 2.6; §4.2 routes → 2.1, 2.5, 2.6; §4.3 snapshot → 2.1, 2.4; §4.4 authorization → 2.4; §5 server → 3.2, 3.3; Mac verbs → 3.4; §6.1 web → 4.2; §6.2 phone → 5.1; §6.3 no-op; §6.4 links → 4.1/4.2/6.2; §7 removal → 6.x; §8 slices → the sections; §9 testing → each task.
- Placeholders: none; the store and service bodies are specified by method list and rule list with test names rather than full code, which the implementer writes from the store interface in 2.3 and the rules in 2.4.
- Type consistency: `TeamShares`, `TeamGrant`, `TeamSnapshot`, `TeamQueuedCommand`, `TeamCommandAck` are defined once in 2.1 and named identically in 2.4–3.3 and 4.1.
- Review Focus: each line names its task and test.
