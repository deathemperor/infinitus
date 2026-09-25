# Team on Infinitus Connect (design)

Status: approved by the owner's ruling (2026-09-25, #1592): rebuild Team on
Infinitus Connect; transcripts stay, stored when the member's sharing
allows. The four calls the owner accepted with the analysis that day are
§2's decisions 1–4. Decisions 5, 8 and 9 are this document's own and are
listed in #1592's first comment for overruling; decision 5 in particular
replaces the "command route stays" line of the analysis.
Date: 2026-09-25. Issue: #1592. Supersedes `2026-09-15-team-rebuild-design.md`
(the git-store rebuild, #1313) and, through it, `2026-09-05-team-design.md`
and `2026-09-07-team-session-control-design.md`.

## 1. What this is

Team as shipped in 0.5.0-alpha.17 is peer-to-peer over one git remote the
leader supplies: a keypair per Mac, an invite code that carries the
remote's write token, sealed envelopes on per-member branches, a
five-minute fetch loop, and every setting in files under the Mac's
Application Support. It worked, and it has three costs the relay removes:
every shared code is a store credential; the phone cannot read anything
without a Mac in the loop; and a member is a machine, not a person.

Infinitus Connect (#1322) is the fork's deployment of the relay on
`relay.infinitus.run`: Clerk identity, Postgres on Neon, environment links,
managed tunnels, push. The relay is ours, which is what makes the design
below defensible: team rows are relay-readable behind Clerk authorization,
not end-to-end encrypted. Redaction still runs on the member's machine
before anything is published.

Under this design a member is a Clerk user; a team is a relay row; joining
is an invite token the relay checks; sharing is documents the desktop
server publishes with its environment credential; settings are relay rows
every device of the user agrees on; delegated control is a command queue
the grantor's server polls. The Mac contributes data only (stats days and
the private-project list) and keeps three verbs. The git store, the
per-Mac identity and recovery key, the sealed envelopes, the crypto core,
the CLI team subcommands and the unauthenticated command route go.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | **Rows the relay can read, no end-to-end encryption.** | The relay is the owner's. E2E on Connect needs a keypair per device, device keys in the roster and every publisher wrapping to every device of every recipient before a phone can read a row. |
| 2 | **The team engine lives in the desktop server**, in TypeScript. | The server holds the environment credential, the thread shells and the thread detail. The Mac has no Connect session and never talks to the relay (One API). A Linux member needs no Swift. |
| 3 | **Transcripts are stored** (owner's ruling), chunked into R2 with one row per chunk in Postgres; default share `off`. | Postgres on the free tier is the wrong place for 1 MiB chunks. `off` is what the 2026-09-15 spec said and the code got wrong (leaders by default). |
| 4 | **Shares, policy and grants move to the relay. Private projects stay on the Mac.** | Every device of a user must agree on what they share. Exclusions were designed as never sent and still are. |
| 5 | **Delegated control is a relay queue**; the unauthenticated `POST /api/infinitus/team/command` route goes. | With the envelopes gone the route would have no authentication. The queue also gives a member with no tunnel a lane, which the store lane was. The tunnel lane (a relay-signed command over the grantor's managed hostname) is deferred. |
| 6 | **Relay changes follow the alerts pattern**: `infra/relay/src/infinitusTeam/`, its own schema file (`schema.ts`, re-exported by one line at the end of `persistence/schema.ts`, since `Drizzle.Schema` in `db.ts` reads that one path), its own API file, wired at the existing `worker.ts` and `relay.ts` registration points. The migration is generated locally with `npx drizzle-kit generate` and committed (`migration.sql` + `snapshot.json`), as every relay migration is; the deploy applies it. | #1565: fork edits in upstream's hot files keep conflicting. |
| 7 | **Client routes use the bearer `client` auth** (Clerk session or OAuth token); environment routes use the environment credential. | No new DPoP scope, so the phone's `t3-mobile` token needs nothing. The environment credential already authenticates every relay environment route. |
| 8 | **No migration from git-store teams.** | The old team is a set of files on one Mac. The owner's team starts over; the old directories are left in place, unread. |
| 9 | **Push on a join request or an approval is deferred.** | The fan-out exists (`InfinitusAlertPublisher`), but a user-keyed variant is its own slice. Leaders see requests when they open the pane, as today. |

## 3. Identity and membership

A member is the Clerk `sub`. The relay knows no email or name, so a member
gives a display name on create or join and may change it later. A user may
belong to several teams; the clients show a list and a picker. A team has
leaders and members; the founder is a leader and cannot be removed; a team
keeps at least one leader.

Joining: an invite token minted with `oneUse` is the leader's own act, so
a join with one makes the joiner a `member` at once and spends the token.
A reusable token (the shareable code) creates a request the leaders
approve. Turning `policy.requests` to `off` refuses joins with any token
until it is turned back; the tokens themselves keep their expiry. A join
by an existing member answers their current status.

Machines: a member's documents are keyed by environment. The reader shows
each member's machines by the environment label the link carries
(`relay_environment_links.environment_label`). A member with no linked
environment has a name and nothing else.

## 4. Relay

### 4.1 Tables (`infra/relay/src/infinitusTeam/schema.ts`, one migration)

| table | columns | keys |
|---|---|---|
| `infinitus_teams` | `team_id` (uuid), `name`, `founder_user_id`, `policy_requests` (`code` \| `off`), `created_at`, `updated_at` | PK team_id |
| `infinitus_team_members` | `team_id`, `user_id`, `role` (`leader` \| `member`), `name`, `shares_json` (kind → `off` \| `leaders` \| `team`), `since`, `updated_at` | PK (team_id, user_id) |
| `infinitus_team_invites` | `invite_id` (uuid), `team_id`, `token_hash` (sha256, base64url), `created_by_user_id`, `one_use` (bool), `used_by_user_id`, `expires_at`, `revoked_at`, `created_at` | PK invite_id; unique token_hash; idx (team_id) |
| `infinitus_team_requests` | `team_id`, `user_id`, `name`, `invite_id`, `created_at` | PK (team_id, user_id) |
| `infinitus_team_documents` | `team_id`, `user_id`, `environment_id`, `kind` (`now` \| `fleet` \| `threads` \| `stats`), `key` (`-` or the day), `body_json` (jsonb, ≤ 256 KiB), `updated_at` | PK (team_id, user_id, environment_id, kind, key); idx (team_id, kind) |
| `infinitus_team_transcripts` | `team_id`, `user_id`, `environment_id`, `thread_id`, `seq`, `rows` (int, rows in the chunk), `bytes`, `object_key`, `created_at` | PK (team_id, user_id, environment_id, thread_id, seq); idx (team_id, user_id, created_at) |
| `infinitus_team_grants` | `grant_id` (uuid), `team_id`, `user_id` (grantor), `environment_id`, `audience_json` (`team` \| `leaders` \| [user_id]), `threads_json` (`all` \| [thread_id]), `capabilities_json` ([`view` \| `send` \| `interrupt` \| `new`]), `preauthorized_json`, `expires_at`, `created_at` | PK grant_id; idx (team_id, environment_id) |
| `infinitus_team_commands` | `command_id` (uuid), `team_id`, `from_user_id`, `to_user_id`, `environment_id`, `thread_id`, `action`, `text`, `project`, `status` (`queued` \| `pending` \| `running` \| `done` \| `refused` \| `denied` \| `expired`), `ack_json` (`{outcome, detail?, result?}`), `created_at`, `expires_at`, `answered_at` | PK command_id; idx (environment_id, status); idx (from_user_id, created_at) |

R2: bucket `InfinitusTeamTranscripts` (Alchemy `Cloudflare.R2.Bucket`, a
`ReadWriteBucket` binding on the Worker). Object key
`teams/<team>/<user>/<environment>/<thread>/<seq>.jsonl`. Removing a
member, leaving, and the retention prune delete the objects with the rows.

Retention: transcript chunks older than 90 days, and a member's chunks
beyond 200 MB per team (oldest first), are deleted by the existing
five-minute cron beside the DPoP prune. `now` documents are never deleted;
a reader treats one older than ten minutes as offline. Commands past
`expires_at` flip to `expired` in the same cron.

### 4.2 Routes (`packages/contracts/src/relayInfinitusTeam.ts`)

Group `infinitusTeam`, middleware `RelayClientAuth`, principal `userId`:

| method and path | body → reply | who |
|---|---|---|
| `GET /v1/infinitus/teams` | → `[{teamId, name, role}]` | any |
| `POST /v1/infinitus/teams` | `{name, memberName}` → snapshot | any |
| `POST /v1/infinitus/team-join` | `{token, memberName}` → `{teamId, status: member \| pending}` | any |
| `GET /v1/infinitus/teams/:teamId` | → snapshot (§4.3) | member |
| `PUT …/:teamId/me` | `{name?, shares?}` → snapshot | member |
| `POST …/:teamId/leave` | → `{ok}` | member, not the last leader |
| `POST …/:teamId/invites` | `{days (1..3650, default 7), oneUse}` → `{inviteId, token, expiresAt}` (the token once, never again) | leader, policy not `off` |
| `DELETE …/:teamId/invites/:inviteId` | → `{ok}` | leader |
| `POST …/:teamId/requests/:userId/approve` \| `decline` | → snapshot | leader |
| `POST …/:teamId/members/:userId/promote` \| `demote` \| `remove` | → snapshot | leader; remove never the founder; demote never the last leader |
| `PUT …/:teamId/policy` | `{requests}` → snapshot | leader |
| `GET …/:teamId/documents?userId=&environmentId=&kind=` | → `[{userId, environmentId, kind, key, body, updatedAt}]`, filtered by the publisher's share for the kind and the reader's role | member |
| `GET …/:teamId/transcripts/:userId/:environmentId/:threadId` | → `[{seq, rows, bytes, createdAt}]` | member, share allows |
| `GET …/:teamId/transcripts/:userId/:environmentId/:threadId/:seq` | → `{lines}` (the chunk's text) | member, share allows |
| `POST …/:teamId/grants` | `{environmentId, audience, threads, capabilities, preauthorized?, expiresInSeconds?}` → grant | the grantor, for an environment linked to them |
| `DELETE …/:teamId/grants/:grantId` | → `{ok}` | the grantor |
| `POST …/:teamId/commands` | `{toUserId, environmentId, threadId \| "-", action, text?, project?}` → `{commandId, status}` | a member a grant allows (checked here: grant exists, not expired, audience includes the caller, thread and capability match) |
| `GET …/:teamId/commands/:commandId` | → `{commandId, status, ack?}` | the sender or the grantor |
| `GET …/:teamId/commands?pending=1` | → `[commands waiting for my tap]` | the grantor |
| `POST …/:teamId/commands/:commandId/allow` \| `deny` | → `{commandId, status}` | the grantor |

Group `infinitusTeamEnvironment`, middleware `RelayEnvironmentAuth`,
principal `environmentId` (must equal the path's) and
`environmentPublicKey`. The relay allows several users to link one
environment while the environment itself knows one linked user
(`cloud-linked-user-id`), so the server names that user in every call
(`userId` in the payload, or the `X-Infinitus-User` header on the two
GETs), and the relay refuses unless an active `relay_environment_links` row
exists for that exact user, environment and public key:

| method and path | body → reply |
|---|---|
| `GET /v1/environments/:environmentId/infinitus-team` | → `{userId, teams: [{teamId, shares, grants: [this environment's], transcripts: [{threadId, rows}] (rows already published per thread)}]}` |
| `POST /v1/environments/:environmentId/infinitus-team/:teamId/documents` | `{documents: [{kind, key, body}]}` → `{ok}` (upsert, ≤ 40 per call, ≤ 256 KiB each) |
| `POST /v1/environments/:environmentId/infinitus-team/:teamId/transcripts` | `{threadId, seq, rows, lines}` → `{ok}` (≤ 1 MiB; seq must be the next; refused when the member's transcripts share is `off`) |
| `GET /v1/environments/:environmentId/infinitus-team/commands` | → `[queued commands for this environment]`; the relay marks them `running` |
| `POST /v1/environments/:environmentId/infinitus-team/commands/:commandId/ack` | `{outcome, detail?, result?}` → `{ok}`; `pending` when the grant needs the grantor's tap |

Errors: `RelayAuthInvalidError` (`not_authorized`) and `RelayInternalError`
from `relay.ts`, plus one fork-owned tagged error in
`relayInfinitusTeam.ts`, `RelayInfinitusTeamRefusedError` (status 409,
`{code: "infinitus_team_refused", reason, traceId}`), for everything the
caller can fix: a refused join, an expired or spent invite, a policy
refusal, an unknown team or member, the last leader leaving, the founder
removed. `reason` is a sentence the clients show verbatim.

### 4.3 The snapshot

```
{teamId, name, role, policy: {requests}, me: {name, shares},
 members: [{userId, name, role, founder, since,
            machines: [{environmentId, label, now?: <now body>, lastPublished}]}],
 requests: [{userId, name, at}]            // leaders only
 invites: [{inviteId, oneUse, expiresAt, usedBy?}]   // leaders only, never the token
 grants: [{grantId, environmentId, audience, threads, capabilities, preauthorized, expiresAt}]  // mine
 pending: [{commandId, fromUserId, fromName, environmentId, threadId, action, text?, project?, expiresAt}]  // waiting for my tap
 grantsToMe: [{grantorUserId, environmentId, threads, capabilities}]}
```

`now` is folded into the snapshot because the members list needs it on
every open; the other kinds are read on demand.

### 4.4 Authorization

A kind is readable when the publisher's current `shares[kind]` is `team`,
or `leaders` and the reader is a leader, or the reader is the publisher.
The check reads the member's row at request time, so narrowing a share
hides everything at once. A removed member's documents, transcripts,
grants and commands are deleted with the membership.

## 5. Desktop server

`apps/server/src/infinitus/Layers/InfinitusTeamRelay.ts` (+ `Services/`,
`infinitusTeamRelay.logic.ts` for the pure parts). It joins the fork's
chained reactor list in `server.ts` (`ReactorLayerLive`, the second `pipe`;
the first is at its twenty-argument limit) with its own control client,
as `InfinitusSignInLapseLive` does, and is started where the orchestration
reactor starts `AgentAwarenessRelay` (`OrchestrationReactor.ts`). It reads
the link the way `InfinitusAlertRelayLive` does, on every cycle.

Loop: every 60 s it reads `GET …/infinitus-team` once (memberships, shares,
grants, cursors) and publishes `now`; every 300 s it also publishes the
other kinds. Nothing publishes for a kind whose share is `off`. An
unlinked server, or a user in no team, sleeps until the next cycle.

| kind | key | body | source |
|---|---|---|---|
| `now` | `-` | `{at, machine, desktop: true, live: [{id, title, project, startedAt, activityLine}], fleets: [{engine, account, windows}], blockers}` | thread shells (`ProjectionSnapshotQuery.getShellSnapshot`) for live rows; the Mac snapshot (`InfinitusService.snapshot`) for fleets and blockers; `fleets: []` when the Mac is unavailable |
| `fleet` | `-` | the old `FleetDoc` shape: per engine active, next, accounts `[{label (alias or #n, never an email), tier, status, active, windows, models}]` | the Mac snapshot |
| `threads` | `-` | `{at, threads: [{id, title, project (basename), status, createdAt, updatedAt, turns, usage?}]}`, newest 500 | thread shells |
| `stats` | the day | `Stats.Day.compacted()` as the Mac's `team-days` returns it (no `minuteTokens`, `sessions` or `hours`; the tallies and the peak stay, so a day is a few KiB) | the Mac, `team-days --days 30`, one document per changed day (the server keeps the last digest per day in memory) |
| transcripts | per thread | rows `{role, text, at}` after the relay's cursor, redacted, chunked at 1 MiB | `getThreadDetailSnapshot` for threads updated in the last 30 days, capped at 100k messages |

Private projects: the Mac's `team-days` reply carries `exclusions`
(project basenames and Claude project slugs). The server drops threads,
live rows and transcripts whose project basename is excluded; stats are
already filtered on the Mac. Without a Mac there are no exclusions.

Redaction moves to `packages/shared/src/infinitusTeamRedaction.ts`: the
same rules as `TeamRedaction.swift` (authorization headers, bearer and
`sk-` tokens, GitHub, AWS keys and secrets, Slack/Discord/Outlook webhooks,
`KEY/SECRET/TOKEN/PASSWORD=` values, home paths to `~`, base64 image
blocks), tested with the same fixtures.

Commands: while the memberships reply lists a grant for this environment,
the loop polls `GET …/infinitus-team/commands` every 15 s. Each command is
checked again locally (grant still listed, thread live for `send` and
`interrupt`) and run in-process with the same services the HTTP routes use:
`send` → `thread.turn.start`, `interrupt` → `thread.turn.interrupt`, `new`
→ `thread.create` then start, `view` → the thread detail redacted and
capped at 4096 characters in `result`. `interrupt` and `new` without
preauthorization are acked `pending`; the relay holds them for the
grantor's tap (120 s) and re-queues on allow.

The Mac keeps `team-exclusions` (read → `{projects}`), `team-exclude add|remove
<slug>` (write) and gains `team-days --days <n>` (read →
`{days: {<day>: Day}, exclusions: [slug], generation}`). `TeamDays.swift`
(app target) takes over `TeamModel`'s scan hooks in `AppModel` (`scanFeedsTeam`,
`scanEntries`, `scanGeneration`, `dropScanEntries`) and owns the folded
memo #499 introduced: one fold per scan generation, kept until the next,
the raw entries given back once folded, so the verb answers from the memo
and never re-folds the corpus (#251). A verb call with no fold yet asks for
a scan and answers `{days: {}, generation: 0}`; the server tries again next
cycle. Everything else Team leaves the Mac.

## 6. Clients

`packages/client-runtime/src/relay/infinitusTeamClient.ts`: one
`HttpApiClient` over `RelayApi`'s `infinitusTeam` group with a Clerk token
provider, shared by web and phone; the web's comes from `useAuth().getToken`
(`managedAuth.tsx`), the phone's from `CloudAuthProvider`'s token provider.
The pure fold of a snapshot into rows (`infinitusTeam.logic.ts`) sits
beside it and is what both panes render.

### 6.1 Web — Settings › Team (`/settings/team`, route kept)

Signed out of Connect: one card, "Sign in to Infinitus Connect to use
Team", with the sign-in the sidebar offers
(`components/clerk/useInfinitusConnectAuthPrompt.tsx`). Signed in:

- No team: Create (name, your name) and Join (your name, the invite token
  or link; a pending `pendingTeamJoin` from a deep link prefills it). The
  Join field takes the bare token, `infinitus://join/<token>` and
  `https://infinitus.run/join#<token>`, URI-decoded, so a pasted link of
  any shape works and the old double-prefix trap in `join.html` is moot.
- In a team (a picker when in several): Members (role, machines, live
  threads, today's cost and messages from `stats`, Promote / Demote /
  Remove for leaders), Requests (Approve / Decline), Invites (Mint, with
  days and one-use; the token shown once with Copy and Copy link; the list
  with Revoke), Sharing (a select per kind), Policy, Grants (mine, with
  Revoke) and Waiting for you (Allow / Deny), Leave. A member row expands
  to their threads index; a thread opens its transcript chunks as plain
  rows. Private projects stay on the pane, read and written through the
  Mac's verbs as today, gated on the manifest carrying `team-exclusions`.
- Every error is the relay's reason verbatim.

### 6.2 Phone — Settings › Team

The same client and fold. Teams list; Join (name, token or the `/join#`
link the app already rewrites); Members with machines and live threads;
leaders approve and decline; Waiting for you with Allow / Deny. No Create,
no Sharing, no Grants, no transcripts on the phone in v1. The Mac picker
leaves the screen: joining is the user's, not a Mac's.

### 6.3 Mac menu bar

Nothing changes on screen. Peer fleets (#1545) stay as they are.

### 6.4 Links

`https://infinitus.run/join#<token>` is what users share; `join.html`
forwards to `infinitus://join/<token>` on a desktop and shows the token
with Copy otherwise. The desktop deep link `join` and `pendingTeamJoin`
keep working with the token as the payload. The phone's rewrite to
`team?code=` is unchanged.

## 7. Removed

`apps/mac/Sources/InfinitusCore/Team/` except `TeamExclusions.swift` and
`TeamPaths.swift` (which keep the exclusions file where it is) and a new
`TeamDays.swift` for the fold; `TeamModel.swift`, `TeamSecretsKeychain.swift`;
the sixteen `team-*` verbs bar the three above; `TeamCommand.swift` and
the CLI's `team` subcommand; the `CZlib` target; the Team tests and the
e2e team round; `InfinitusTeamControlHttp.ts`, `infinitusTeamControl.ts`
and the `infinitusTeamControl` group in `EnvironmentHttpApi`; the team
schemas in `packages/contracts/src/infinitus.ts` (`InfinitusTeamSnapshot`
and siblings); the old web pane and phone screen (rewritten in place).
The `Application Support/Infinitus/teams/<id>` directories are left where
they are.

## 8. Slices

One PR each, in order. The relay deploys on every merge to `main`, so its
slice lands first with nothing calling it, and its deploy run is checked
green before the next slice merges.

1. Spec and plan (this document; docs only).
2. Relay: schema, migration, R2 bucket, the two groups, contracts, tests.
   Human steps first: the deploy token needs Workers R2 Storage Read +
   Write; R2 may need a payment method on the Cloudflare account.
3. Server: the publisher, the command poller and executor, the shared
   redaction, the three Mac verbs.
4. Web pane and the shared client.
5. Phone screen.
6. Removal.

## 9. Testing

Relay: `@effect/vitest` layers over an in-memory `InfinitusTeamStore` for
authorization (share × role), invite lifetimes and one-use, founder and
last-leader rules, the command state machine, retention. Server: the
document builders and redaction as pure tests; the loop against a stubbed
relay client (publishes what the shares say, skips `off`, polls commands
only with a grant, acks pending). Web and phone: the snapshot fold and the
join-input parsing. Mac: `team-days` on a scan fixture with an exclusion.
