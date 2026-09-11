# Team — delegated session control, phase 1 (grants + drive)

Brainstormed on issue #220 (2026-09-07), on top of the team design
(2026-09-05-team-design.md). User decisions, in order: "need more
controls like allow starting new sessions, delete session, the whole 9
yards" (the full-control ask, 2026-09-06); phase 1 = "Grants + Drive";
"LAN or store is nut, is there other way?" → the tunnel the phone
already uses; "can I allow other to create hostnames to keep their
tunnels static?" → yes, leader-provisioned; "go, hostnames in phase 1".

## Non-negotiables kept
- No host of ours beyond what exists: the rendezvous worker on
  infinitus.run (holds no accounts, stores one URL per unguessable key)
  and Cloudflare's tunnels. No relay carries plaintext: a command is a
  sealed, signed envelope whether it travels over LAN, a tunnel, or the
  store.
- Default off. Nothing on a Mac is driveable until its owner writes a
  grant. Grants are the session owner's alone; a leader cannot grant on
  a member's behalf.
- The grantor's Mac is the only authority. It checks every command
  against its local grants at execution time; a revoked grant fails on
  the next command, no store round-trip.
- Every remote action executes through the code path the phone and CLI
  already use (`AppModel.send` with a `SessionInput.Request`), so there
  is one implementation of "inject into a session" and it stays engine-
  independent.
- Secrets — the Cloudflare API token, tunnel tokens — live in the
  keychain and travel over stdin or a sealed envelope; shown masked.
- Idle CPU ~0%: no polling loop wakes for driving. The route answers
  requests; the store lane rides the existing publish/fetch timer.

## 1. Concepts

| term | meaning |
|---|---|
| grantor | the member whose Mac runs the session; writes grants, executes commands |
| driver | a member a grant names; sends commands, reads the tail |
| grant | audience × sessions × capabilities, on the grantor's Mac |
| capability | `view`, or one of the drive actions `send`, `approve`, `mode`, `resume`, `key` |
| command | one sealed envelope from driver to grantor asking for one action on one session |
| ack | the grantor's sealed reply to one command |
| endpoint | how to reach a grantor's Mac: LAN address, hostname, or rendezvous key |
| hostname | a Cloudflare named tunnel under a leader's zone, minted for a member |

## 2. Grants (`<teamDir>/grants.json`)

```json
{ "schema": 1,
  "grants": [
    { "id": "g-…", "audience": "leaders" | "team" | ["kid", …],
      "sessions": "all" | ["<sessionId>", …],
      "capabilities": ["view", "send", "approve"],
      "since": 1780000000 }
  ] }
```

- `TeamGrants` in InfinitusCore beside `TeamShares`: `load/save`, `add`,
  `remove(id:)`, and the one question everything asks:
  `permits(kid:session:capability:roster:) -> Grant?`. Audience resolves
  through `TeamRoster.recipients(for:)` so "leaders" follows the roster
  as it changes; a kid the roster no longer lists never matches.
- Sessions match on Claude Code's `sessionId` (stable for a transcript),
  never on pid: the driver names what it saw in the grantor's `now.json`
  and the grantor resolves it to the live pid at execution time.
- Capabilities are the `SessionInput.Request.Kind` names plus `view`.
  `send` = a prompt; `approve` = a permission decision; `mode` = a
  session-mode switch; `resume` = the resume nudge; `key` = a keystroke
  (interrupt, `/clear`). A grant that lists `send` only cannot answer a
  permission prompt.
- Revocation is `remove(id:)`. Nothing propagates; the next command
  fails `noGrant`.
- The grantor publishes `grantsTo: [{audience, sessions, capabilities}]`
  in `now.json` as a UI hint (like `sharesTo`). Readers use it to draw
  controls; the grantor's Mac decides.

## 3. Envelopes

Two member kinds join `TeamKinds.memberKinds`, both under
`m/<kid>/control/`:

| kind | path | sealed to | body |
|---|---|---|---|
| `command` | `m/<driver>/control/commands/<id>.json` | the grantor | `{schema:1, id, to:<grantor kid>, session, action, text?, at, ttl}` |
| `ack` | `m/<grantor>/control/acks/<id>.json` | the driver | `{schema:1, id, outcome, detail?, at}` |
| `hostname` | `m/<leader>/control/hostnames/<member kid>.json` | the member | `{schema:1, hostname, token, at}` |

- `id` is a UUID minted by the driver; `ttl` is seconds (default 120,
  cap 600). `action` ∈ `send | approve | mode | resume | key`; `text` is
  the prompt, decision, mode name or key.
- `outcome` reuses `SessionInput.Reply.outcome` strings (`delivered`,
  `running`, `captured`, `noSurface`, `noChannel`, `rejected`) plus the
  refusals: `noGrant`, `notLive`, `expired`, `replayed`, `unknownSender`,
  `badRequest`, `rateLimited`.
- The same bytes travel on every lane. The path shapes above are the
  store lane's; `TeamKinds.expected(at:)` learns them so a command
  replayed under another branch is refused as today.
- `TeamKinds.check` for `hostname`: the sender must be a leader in the
  roster at `header.at`.

## 4. Verification (`TeamControl.verify`, pure, InfinitusCore)

Order, first failure wins, every failure is an ack + audit line:

1. `Envelope.open` as the grantor: signature, roster membership at
   `header.at` (`TeamRoster.keys(for:at:)`), me among the recipients.
2. `body.to == my kid` (a command sealed to me but addressed elsewhere
   is `badRequest`).
3. `now ≤ at + ttl` else `expired`; `at` not more than 5 min in the
   future else `badRequest`.
4. `id` not in the replay set — `<teamDir>/control-seen.json`, ids with
   their expiry, pruned on write — else `replayed`.
5. `TeamGrants.permits(kid: header.from, session:, capability: action)`
   else `noGrant`. The tail route checks `view` the same way.
6. Session live (`ClaudeSessions.list` has the sessionId) else
   `notLive`.
7. Per-driver token bucket, 5 commands per 10 s, else `rateLimited`.

Then `AppModel.send(SessionInput.Request(kind:action, text:), toPid:,
icon: "person.2", what: "team \(driverName)")`, the reply's outcome
becomes the ack, and the audit line is written.

## 5. Delivery

### 5.1 Endpoints (published in `now.json`)

```json
"endpoints": { "lan": "192.168.1.20:47824", "hostname": "loc.team.example.com",
               "rendezvous": "<64 hex>" }
```

- `lan`: the mirror server's current address, present only while the
  listener is up. `hostname`: the named tunnel's, present while
  `NamedTunnel.connected`. `rendezvous`: present while the quick tunnel
  runs; key = SHA-256 of `"team-control|" + teamId + "|" + kid`, and the
  Mac PUTs its quick-tunnel URL under it on every tunnel start, exactly
  as it does under the pairing key. Any roster member derives it; the
  URL alone opens nothing.
- The publisher writes `endpoints` and `grantsTo` on every `now.json`
  pass; both are hints. A stale `lan` costs one timeout.

### 5.2 Routes (`TeamControl.respond`, pure, beside `TeamNearby`)

| route | auth | answers |
|---|---|---|
| `POST /team/command` | the envelope itself | the ack envelope, `200`; `404` when the route is off |
| `GET /team/sessions/<sessionId>/tail?since=` | header `X-Infinitus-Team: <kid>.<base64 sig over "tail|<sessionId>|<unix minute>">` | the feed bytes the phone's tail route serves, `403` without `view` |

- Mounted by MirrorServer (Mac) under the existing `/team/` prefix;
  PosixHTTPServer (Linux tray) mounts the same handler once the tray
  serves a tunnel. The route is on whenever the member is in a team and
  has at least one grant; with no grants it answers `404` like a
  non-discoverable Nearby.
- TLS is the tunnel's or nothing on LAN; the envelope's seal is the
  confidentiality, its signature the authentication, on every lane.

### 5.3 Driver order (`TeamControl.Deliver`, Mac + CLI)

1. `lan`, 2 s timeout, only when the address is in one of this Mac's
   own subnets.
2. `hostname`, 5 s.
3. `rendezvous`: GET the URL from infinitus.run (cached per member,
   refreshed on the first refused connection), then POST, 5 s.
4. Store: `put` the command under the driver's branch; the grantor's
   next fetch (`TeamModel.loop`, ≤ 5 min) executes it and `put`s the
   ack; the driver's next fetch shows it. `ttl` is raised to 600 for the
   store lane so the fetch cadence cannot expire it.

The driver's UI names the lane that carried each command ("via LAN",
"via tunnel", "via store, next fetch").

### 5.4 Hostnames (leader-provisioned)

- Settings › Team › Hostnames: the leader pastes a Cloudflare API token
  (Account: Cloudflare Tunnel Edit; Zone: DNS Edit, on one zone) and a
  label (`team` → `<name>.team.<zone>`). Keychain
  `run.infinitus.cloudflare-api`, account = zone. Stdin for the CLI.
- "Give hostname" on a member row, or `team hostname give <kid>`:
  1. `POST /accounts/{account}/cfd_tunnel` `{name: "infinitus-<team>-<kid8>", config_src: "cloudflare"}`
  2. `PUT /accounts/{account}/cfd_tunnel/{id}/configurations` ingress `[{hostname, service: "http://localhost:47824"}, {service: "http_status:404"}]`
  3. `POST /zones/{zone}/dns_records` `{type: "CNAME", name: hostname, content: "<id>.cfargotunnel.com", proxied: true}`
  4. `GET /accounts/{account}/cfd_tunnel/{id}/token` → sealed to the member as a `hostname` envelope.
  Account and zone ids come from `GET /zones?name=<zone>` once, cached in
  `<teamDir>/cloudflare.json` (ids only, never the token).
- The member's Mac, on reading a `hostname` envelope addressed to it:
  stores the token under `Keychain.tunnelService` (account = hostname),
  sets `mirror_named_tunnel_host/enabled`, starts `NamedTunnel`. The
  existing pane shows it as any named tunnel; the member can turn it
  off, which stops the tunnel but keeps the token.
- Removing the member (`TeamClient.remove`) deletes the DNS record and
  the tunnel when the leader holds the API token; otherwise the pane
  lists it under "orphaned hostnames" with a delete button.
- Leaders' own hostnames go through the same path (give to self).

## 6. Audit and the HUD

- Every command, accepted or refused, appends to the grantor's
  `events.jsonl` as kind `team-control`: `{driver kid, driver name,
  session, action, outcome, lane}`. The popup's event log shows it with
  the `person.2` icon; the Team pane's feed lists the last 50.
- A session that executed a remote command shows "driven by <name>" in
  the HUD row for 60 s after the last one (a `drivenBy: (name, until)`
  on the session state; the row reads it, no timer).
- Refusals other than `noGrant` from a roster member also post one
  notification per driver per hour ("Alice's commands are failing:
  expired"), through `PushTriggers`-style latching.

## 7. Surfaces

### 7.1 Mac Settings › Team (grantor)
- "Session control" section: rows `audience · sessions · capabilities`
  with a remove button; "Add grant" sheet: audience picker (leaders /
  team / members multi-select), sessions picker (all / pick from live +
  recent), capability checkboxes with one-line meanings. Empty state:
  "Nobody can drive your sessions."
- Feed: last 50 audit lines.
- "Hostnames" (leader): token field (masked, keychain), label field,
  and per member the hostname or "Give hostname".

### 7.2 Mac member detail (driver)
- Sessions the member granted to me, with the granted controls:
  prompt field + Send, Approve / Deny when the tail shows a prompt,
  mode menu, Resume, Interrupt. Disabled controls carry the missing
  capability in `.help`. The live tail renders below, polling the tail
  route every 3 s only while the detail is on screen.
- Every action shows its lane and outcome inline.

### 7.3 CLI
```
infinitusctl team grant <leaders|team|kid,…> [--sessions a,b] [--view] [--send] [--approve] [--mode] [--resume] [--key]
infinitusctl team revoke <grant id>
infinitusctl team grants [--json]
infinitusctl team send <kid> <sessionId>            # text on stdin
infinitusctl team approve <kid> <sessionId> <allow|deny>
infinitusctl team mode <kid> <sessionId> <mode>
infinitusctl team tail <kid> <sessionId> [--follow]
infinitusctl team hostname token                    # API token on stdin
infinitusctl team hostname give <kid>
infinitusctl team hostname list
```
Exit codes as today; every error masked through `TeamGit.masked`.

### 7.4 Phone
Later phase (Infi): the member's sessions open like own sessions when a
grant names the phone's Mac. Nothing in this phase touches `ios/`.

## 8. Threat model (what this phase promises)
- A non-member, or a removed member, cannot make a grantor's Mac do
  anything: step 1 refuses before any grant is consulted.
- A member without a grant learns nothing from the route: `noGrant`
  acks carry no session detail; the tail answers `403`.
- A stolen command file replays nowhere: ids are single-use for their
  TTL and bound to one grantor.
- Cloudflare, the git host and infinitus.run see ciphertext and
  signatures only. A hostname or rendezvous URL reveals that a Mac runs
  Infinitus, nothing else.
- A leader's Cloudflare token can mint and delete tunnels in their own
  zone; it never leaves their Mac and is scoped to that.
- Not promised: liveness. A grantor offline, or with no lane up, runs
  the command on its next fetch or never (ack `expired`).

## 9. Testing
- `TeamGrantsTests`: audience resolution through a moving roster,
  `all` vs listed sessions, capability subsets, revoke.
- `TeamControlTests`: one test per verification rule in §4, order
  proven by a command failing two rules; replay set pruning; rate
  limit; the tail header over a fixed minute; endpoint key derivation.
- `TeamKindsTests`: the three new path shapes, a command under another
  branch refused.
- `TeamControlRouteTests`: `respond` as a pure function — command →
  ack bytes, `404` without grants, `403` tail.
- `TeamHostnameTests`: the four Cloudflare calls against a fake
  `http` closure (order, bodies, ids cached), the `hostname` envelope,
  removal deleting both records.
- e2e (`tools/e2e.sh`): a second identity grants nothing → `noGrant`;
  grants `send` → the demo session receives the prompt over the local
  mirror server; the audit line and the HUD badge appear; revoke →
  `noGrant` again. Idle CPU gate unchanged.
- Linux CI compiles InfinitusCore + CLI including the route.

## 10. Build order (PRs, each green alone)
1. Spec (this file).
2. Core: `TeamGrants`, `TeamControl` (verify, respond, envelopes,
   endpoints, replay set, rate limit), `TeamKinds` shapes, tests.
3. Mac grantor: route mounted in MirrorServer, execution through
   `AppModel.send`, audit + HUD badge, `now.json` endpoints + grantsTo,
   Settings section + feed, CLI grant/revoke/grants, e2e step.
4. Mac driver: member detail controls + tail, `Deliver` with the four
   lanes, store lane on both sides, CLI send/approve/mode/tail.
5. Hostnames: Cloudflare client, `hostname` envelope, Settings and
   member-row UI, CLI, removal cleanup.
6. Site + README + CHANGELOG one-liners ride each PR.

Phase 2 (#220, later): lifecycle (start/stop/resume-past/delete with
the approval envelope), accounts, machine verbs; phone surfaces; LAN
discovery of teammates' Macs via Nearby TXT.
