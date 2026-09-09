# Team — leaders, members, encrypted sharing, every insight

Brainstormed on issue #46 (2026-09-04/05). User decisions, in order:
"myself as CTO I want to manage team members with every stats built and
will be built"; "design with a universal approach, not tight to any OS.
team leaders can access transcripts of any with option to turn off from
members"; "Infinitus has nothing tight to cswap, not anymore" (forever);
"with git repo other members can access the repo and read the info that
is not shared to them"; "team members can decide to share with other
members"; "request and invite must be made through the app, no
friction. no outside app interaction"; "with github private repo it's
limited in number of collaborator and many teams dont use github";
"members sharing the same local network can see the candidates,
likewise for leaders"; "per-project exclusions, include linux windows
mDNS"; "how about storing keys as passkeys?"; "add an option for
biometric auth on app. joining a team requires enabling this";
"rebuild the whole spec in one".

## Non-negotiables kept
- No host of ours, no self-hosting, no cswap anywhere. The store is
  something the team already has (a git remote). Every cross-platform
  piece ships from this repo (InfinitusCore + InfinitusCLI) on macOS,
  Linux and Windows.
- Engine isolation: only Claude Code's own files (`~/.claude/projects/
  **/*.jsonl`, `~/.claude/sessions/*.json`) and the app's own data leave
  a machine, and only after redaction and encryption.
- The store is untrusted. Privacy comes from keys: everything a member
  publishes is end-to-end encrypted to the readers that member chose.
- Secrets (store credential, keys) live in the OS credential store and
  travel over stdin only; shown masked. Usage-cost figures are estimates.
- Idle CPU ~0%: publishing is timer-driven and incremental; no polling
  loops in SwiftUI.

## 1. Concepts

| term | meaning |
|---|---|
| team | one roster, one store, one or more leaders |
| leader | invites, approves, removes, promotes, publishes team-wide aggregates, reads whatever members share to leaders |
| co-leader | a leader who cannot remove or demote the founding leader; otherwise identical |
| member | publishes their own data to the audiences they pick |
| identity | an X25519 key pair (encryption) + an Ed25519 key pair (signing), both derived from one 32-byte identity secret; `kid` = first 16 bytes of SHA-256(public encryption key ‖ public signing key), base32 — binding both keys, so a request cannot pair one member's encryption key with another's signing key (#57) |
| audience | per data kind: **leaders** (default), **team**, or **chosen** members |
| data kinds | `stats` (Stats.Day), `now` (live state), `sessions` (session index + fleet health), `transcripts` |

A member sees: the roster, what each teammate shares *to them*, the
aggregates the leaders publish, and their own detail. A leader sees
every member's leader-shared data plus the same.

## 2. Identity and keys

### 2.1 Identity secret
- **Passkey path** (Apple now; Windows Hello to verify at plan time; a
  FIDO2 key with `hmac-secret` on Linux): the app registers a passkey
  for relying party `infinitus.run` (associated-domains entitlement
  `webcredentials:infinitus.run`; `site/public/.well-known/
  apple-app-site-association` lists the app ids; static file, no
  server). The identity secret is the PRF output for the fixed salt
  `infinitus-team-identity-v1`. Nobody ever verifies an assertion; the
  passkey is a synced secret-derivation device. The same passkey on the
  phone or a replacement Mac yields the same identity. The entitlement
  needs a provisioning profile, so passkey identity works only in a
  signed build (dev-signed builds already lose usernoted and Live
  Activities push for the same reason); the local path below is the
  default until then, which is why it builds first (§12).
- **Local path** (no passkey, or declined): 32 random bytes in the OS
  credential store (macOS keychain `run.infinitus.team`, Windows
  Credential Manager, Linux `$XDG_DATA_HOME/infinitus/teams/secrets/`
  0700 with 0600 files) plus a
  **recovery key** (the same bytes, base32 in 8 groups) shown once with
  "keep this offline" and re-showable after unlock.
- Derivation: `HKDF-SHA256(secret, salt: "infinitus-team-v1", info:
  "x25519")` → encryption key; `info: "ed25519"` → signing key.
  Implemented once in InfinitusCore over `swift-crypto` (`import
  Crypto`; re-exports CryptoKit on Apple). This is the repo's first
  package dependency; pin it.
- **Working key cache**: after one unlock the derived private keys sit
  in memory; the passkey PRF gesture happens once per launch (or when
  the cache is empty). The publish/fetch loop never prompts.
- Deleting the passkey deletes the identity: the app says so and offers
  an encrypted export: the identity secret sealed with a passphrase
  through PBKDF2-HMAC-SHA256 (600k rounds, written over swift-crypto's
  HMAC so it is the same on every platform) + ChaChaPoly. A re-created
  identity gets a new `kid` and must be re-approved by a leader.

### 2.2 Biometric lock (app-wide option, required for teams)
- Setting "Unlock with Face ID / Touch ID" (Mac: LocalAuthentication,
  Touch ID or Apple Watch; phone: Face ID / Touch ID; Windows: Windows
  Hello; Linux: passphrase lock, labeled as such). Off by default.
- On: the pop-out, settings and the phone app show a locked state until
  unlocked; re-lock after **immediately / 5 min / 1 h / on sleep**
  (default 1 h). Team data is decrypted only after unlock; the unlock
  is the moment the passkey PRF runs, so one prompt serves both.
  Re-lock hides the team views; the working key stays in memory so the
  publish/fetch loop keeps running without a prompt.
- Mac: Create team, Accept invite, Request to join are disabled until
  the setting is on, with "Turn on biometric unlock first" and a button
  to the setting. Phone: no such gate (user 2026-09-09) — team actions
  work with the lock off. Turning it off while in a team is allowed with a
  warning; team data then re-locks behind the passkey prompt on each
  launch. The app never leaves a team silently.
- Unavailable biometrics fall back to the device passcode as the OS
  does; on Linux the passphrase.

## 3. Envelope (the file format, the contract)

Every object in the store is one envelope: a JSON header line, `\n`,
then ciphertext (zlib from the system library on all three platforms).

```
{"v":1,"kind":"stats","from":"<kid>","eph":"<base64 X25519 pub>",
 "to":[{"kid":"<kid>","wrap":"<base64>"},…],
 "at":<unix seconds>,"nonce":"<base64 12B>",
 "sig":"<base64 Ed25519 over header-without-sig + ciphertext>"}
<ChaCha20-Poly1305 ciphertext of the plaintext JSON/JSONL, zlib-deflated>
```

- One fresh 32-byte file key per envelope. For each recipient: X25519
  ECDH(ephemeral, recipient) → HKDF(info: "wrap-v1" + kids) → wrap key
  → ChaChaPoly seal of the file key. The sender is always a recipient.
- Readers verify `sig` against the sender's roster key before decrypting
  and reject envelopes from kids not in the roster (or removed after the
  envelope's `at`).
- `kind` and the path name the plaintext schema (below). Schemas are
  versioned inside the plaintext (`{"schema":1,…}`); envelope `v` only
  changes when the crypto does.

## 4. Store

### 4.1 Interface (InfinitusCore `TeamStore`)
```
protocol TeamStore {
  func put(_ path: String, _ data: Data) async throws       // whole object
  func get(_ path: String) async throws -> Data?
  func list(_ prefix: String) async throws -> [StoreEntry]   // path, size, version
  func changes(since: StoreCursor?) async throws -> ([StoreEntry], StoreCursor)
  func delete(_ path: String) async throws
}
```
Adapters: **git** (v1). Later, same layout: synced folder (Drive,
Dropbox, OneDrive, iCloud Drive, NAS) and S3-compatible bucket.

### 4.2 Git adapter
- Config: remote URL + write credential (HTTPS token in the credential
  store, or an SSH key path). Any host: GitHub, GitLab, Bitbucket, Gitea,
  Azure DevOps, a bare repo over SSH. No host API is ever called.
- **Members are never host collaborators**: everyone pushes with the
  team credential the invite carries. One repo serves any team size.
- Branches: `roster` (leaders only: `team.json`, `aggregates/…`),
  `requests` (anyone with the credential: `requests/<kid>.json`),
  `m/<kid>` (that member only; everything but transcripts — kilobytes),
  `t/<kid>` (that member's transcript chunks, #321). Disjoint writers ⇒
  no merge conflicts; every fetch pulls `roster`, `requests`, every
  `m/*` and the member's own `t/<kid>`; a teammate's `t/<kid>` is
  fetched when their `now.json` `sharesTo` hint names this reader, or
  on demand when one of their transcripts is opened.
- Local mirror at `App Support/Infinitus/teams/<team-id>/store/store.git`,
  a bare repo (no worktrees: reads are `cat-file`, writes are
  `commit-tree` + push), blobs only.
- Commits are made by `git` as a subprocess (present on every dev box;
  the app already shells out to git for Stats). Author `Infinitus
  <kid@infinitus.run>`; message = path list. Force-push never.
- Push cadence: every 5 min while a session is alive, at day end, on
  audience change, on leave. Fetch cadence: on the Team pane opening,
  then every 5 min while open, every 30 min otherwise; `git fetch`
  only, no network when the Mac is on battery-saver and idle. A joiner
  may wait up to 30 min for approval while the leader's pane is closed.
- Growth: ciphertext doesn't delta-compress, so transcripts are
  **append-only chunks** (§5.4) and `days/` files are tiny. A leader
  setting "keep N days of transcripts" (default 90) prunes old chunks
  from the leader's clone. The remote keeps history; v1 shows the store
  size on the privacy page and leaves remote compaction to a later
  version.
- **Credential rotation** cannot be automated without a host API. On
  removal the app rotates the *roster* (the removed key stops being a
  recipient and its writes are ignored) and offers "Rotate store
  credential…" with a paste field; the new credential reaches remaining
  members through a roster-signed `credential` envelope wrapped to the
  team (so members pick it up on their next fetch).
- Vandalism by a credential holder (delete/garble) is recoverable from
  git history and local clones and attributable through signatures.

### 4.3 Layout (per branch)
```
roster:    team.json  aggregates/<period>.json  credential.json
requests:  requests/<kid>.json
m/<kid>:   days/<yyyy-mm-dd>.json   now.json   sessions/index.json
           transcripts/<session-id>/<seq>.jsonl   crashes.json
```
Every file is an envelope (§3); `team.json` is signed-plaintext (JSON +
detached Ed25519 signature by a leader) so anyone with the credential
can read the roster.

## 5. Roster (`team.json`)
```
{"schema":1,"id":"<uuid>","name":"Papaya","createdAt":…,
 "leaders":[{"kid":…,"enc":…,"sig":…,"name":"Loc","since":…,"founder":true}],
 "members":[{"kid":…,"enc":…,"sig":…,"name":…,"since":…,"devices":["Mac","iPhone"],
             "sharesTo":{"stats":"team","transcripts":"leaders","sessions":["<kid>"]}}],
 "removed":[{"kid":…,"at":…}],
 "policy":{"requests":"open|code|off","membersSeeEachOther":false},
 "codeFingerprint":"<sha256 of the team code>", "rev":17}
```
- `sharesTo` is a hint the member writes into its own `now.json` and
  the leader copies into the roster on the next roster save; readers
  still rely on the envelope recipients, never on the hint.
- Signed by a leader; `rev` increases monotonically; clients refuse a
  roster with a lower `rev` or a signature from a non-leader. The first
  roster a joiner accepts must be signed by the leader named in the code.
- Promote / demote / remove edit this file. One leader minimum.

## 6. Join and invite (all in-app)

### 6.1 Create team (leader, once)
Team pane › Create: name → identity (passkey or local, §2.1) → store:
"Paste the URL of an empty private repo and a write credential" (or an
SSH key path). The app initialises the branches, writes `team.json`,
pushes. The only out-of-app moment in the design.

### 6.2 Invite (leader → person)
Invite button → `infinitus://join/<base64url payload>` + QR + share
sheet. Payload: team id, name, remote URL, write credential, leader kid
+ enc key, expiry (default 7 days), one-time nonce, signed by the
leader. Opening the link on the Mac: the app verifies the leader
signature, clones, drops `requests/<kid>.json` (name, keys, devices,
platform) and shows "Waiting for approval". Opening it on the phone:
the phone verifies the signature and hands the payload to its Mac over
the mirror, which does the rest (iOS has no git; phone-only members are
phase 3). Because the leader minted
the invite, the leader's app auto-approves requests whose nonce
matches an invite it issued (one round trip, no tap); other requests
need Approve.

### 6.3 Team code (person → leader)
A team has a shareable code: the invite payload without a nonce and
with a long expiry. Git hosts issue no branch-scoped tokens, so the code
carries the **same write credential** as an invite; what limits it is
`policy.requests: off` (the app ignores new requests and hides the
code), code rotation (= credential rotation, §4.2), and the signature
rules that make any other write ignorable. The vandalism surface (§4.2)
grows with how widely the code is shared; the Team pane says so next to
the code. Enter the code → request lands → leader taps Approve/Decline. The
code is pasted on stdin, never argv.

### 6.4 Nearby (same LAN)
- The existing `_infinitus._tcp` advertisement (MirrorServer on Mac;
  the Linux/Windows CLI's own listener, §9) gains TXT keys `n` (name),
  `k` (kid), `t` (team id or empty), `r` (leader|member|none), `d`
  (discoverable 0/1). Nothing secret.
- Leader's Team pane "Nearby": discoverable peers not in the team →
  **Invite** → the invite payload encrypted to the peer's enc key
  (fetched from `GET /team/key` on the peer) is `POST /team/invite`d to
  the peer; the peer's app shows "Loc invites you to Papaya" →
  **Accept** joins at once (leader-initiated ⇒ auto-approve as in §6.2).
- Member's "Nearby teams": leaders with `requests != off` → **Request**
  → `POST /team/request` to the leader; also written to the `requests`
  branch if the peer has the credential, so an offline leader still sees
  it. Leader taps Approve.
- Discoverable: on while the Team pane is open, off otherwise; an
  "always" option. Off ⇒ TXT carries `d=0` and no team fields; the
  endpoints answer 404.
- The phone shows the Mac's Nearby lists through the mirror and can
  Invite / Request / Approve from there.

### 6.5 Remove, leave, promote
- Remove (leader): roster edit (kid → `removed`), optional credential
  rotation (§4.2). The removed app sees the roster on its next fetch,
  stops publishing, keeps its local history, and shows "Removed from
  Papaya".
- Leave (member): deletes its `m/<kid>` branch contents (history stays
  ciphertext only its recipients could ever open), pushes, tells the
  leaders through a `requests/<kid>.leave` file. Member key rotation is
  offered so even the member can't reopen old envelopes.
- Promote / demote: roster edit; a promoted member's key becomes a
  recipient for `leaders` audiences **from now on**; members re-wrap
  recent history only when they choose "Re-share history to new
  leaders" (default: last 30 days, one click in the warning).

## 7. What a member publishes

All on the member's machine, from Claude Code's own files, through the
same `StatsScanner` the app uses. Every kind honours **per-project
exclusions** (a Claude Code project dir the member marks private:
nothing from it is published — no transcript, no session row, no
Stats.Day contribution; exclusions are local and never sent).

| kind | file | content | cadence |
|---|---|---|---|
| stats | `days/<date>.json` | `Stats.Day` (Stats v2 shape, schema-versioned), minus per-project rows for excluded projects | day end + every push while the day changes |
| now | `now.json` | sessions by status, active account + windows per fleet (engine ids opaque strings), blockers (dead accounts, expired AWS logins, waiting prompts), crashes today, `sharesTo` | every push while sessions are alive; deleted on quit |
| sessions | `sessions/index.json` | per session: id, project name (basename, not path), start/end, busy/waiting minutes, activity mix, $; fleet health summary | every push |
| transcripts | `transcripts/<session>/<seq>.jsonl` | redacted JSONL, append-only chunks of ≤1 MiB of new lines since the last chunk; sub-agent transcripts under the same session | every push |
| crashes | `crashes.json` | the built-in `CrashReport.summary` list (no raw) | on change |

Audience per kind (§1) is chosen in Settings › Team; changes apply to
new envelopes. "Re-share history" re-wraps the local plaintext copies
for the last N days and republishes. Narrowing cannot recall ciphertext
teammates already hold; the UI says so.

### 7.1 Redaction (before encryption, on the member's machine)
Bearer tokens, `sk-…`, AWS access keys / session tokens, webhook URLs,
`.env` dumps, `Authorization:` headers, the patterns the app already
masks in logs; home paths normalised to `~`; pasted images dropped
unless "include images" is on. The member's "What my team sees" view
renders the redacted output.

## 8. What a leader (and the team) sees

### 8.1 Reader
`TeamReader` (InfinitusCore) folds every readable `days/` envelope into
`Stats.Day` per member per day (Stats v2 `+`), keeps `now.json` per
member, indexes sessions, and streams transcript chunks into the
existing `SessionFeed.parse` so a member's session renders in the same
chat view the phone uses for live sessions.

### 8.2 Insights per member
Effort (tokens, $, minutes by day/week/month/year, by model, by
activity, by repo); rhythm (hours heatmap, sessions/day, longest focus,
waiting/blocked minutes); quality signals already in Stats v2 (review
yield, test ROI, rework, delegation depth, cache hits, model switches);
fleet health (accounts, limits hit, dead time, AWS stalls, crashes);
now (running/waiting/idle, active account, blockers); transcripts
(list like the phone's Sessions screen, open, search, jump from a
stat to the stretch behind it).

### 8.3 Insights for the team
Totals and trends; per-member comparison table; leaderboards the leader
picks; repo coverage (who works where, effort per repo); blockers board
(every member's dead accounts, expired logins, waiting prompts, crashes);
cost per member / repo / model with `UsageForecast` per member; team
hours heatmap and who's on now. Leaders publish `aggregates/<period>.json`
(wrapped to the team) so members see the team picture without reading
each other's detail. Narrative digests (Haiku over labels and titles,
never transcript text) are **phase 3**.

### 8.4 Members' view
Roster with, per teammate, what they share *to you*; the leaders'
aggregates; your own detail. With `membersSeeEachOther` the leaders
re-publish member detail to the team; otherwise a teammate's detail is
visible only if that teammate chose you.

## 9. Surfaces

- **Mac Team pane**: members list (name, role, audience per kind, last
  publish, today's effort, blockers, on/off now), requests, Nearby,
  Invite / Team code / Approve / Remove / Promote, member detail (Stats
  tiles with a member picker), transcripts, privacy page (what I share,
  exclusions, store URL masked credential, Leave, identity export).
- **Phone Team tab** through the mirror: the same lists; approve /
  request / invite from the phone; member detail reuses the Stats and
  Sessions screens with a member picker; locked behind the phone's own
  biometric switch.
- **InfinitusCLI, all platforms**: `infinitusctl team create|invite|code|
  request <code>|approve <kid>|decline <kid>|remove <kid>|promote <kid>|
  status|members|member <kid> [--period]|share <kind> leaders|team|<kid>…|
  exclude <project> [--off]|publish|fetch|leave|identity export|import`.
  `team` subcommands run **in-process** (no control socket) so a Linux/
  Windows member needs only this binary: InfinitusCLI leaves the macOS
  `#if` in Package.swift; socket-backed commands stay macOS-only at
  runtime with a clear error elsewhere. Timer snippets shipped for
  systemd (`packaging/linux`) and Task Scheduler (`packaging/windows`).
- **Control commands** (Mac, for the e2e gate): `team-status`,
  `team-publish`, `team-fetch`, `team-approve <kid>`.
- **Linux/Windows discovery**: `InfinitusCore/MDNS.swift` — a
  multicast-DNS responder + browser over UDP (224.0.0.251 / ff02::fb,
  5353) advertising `_infinitus._tcp` with the same TXT record; the CLI
  runs `infinitusctl team nearby` / `--discoverable` on top of
  `PosixHTTPServer` for `/team/key|invite|request`. Apple keeps
  Network.framework; the wire format is shared so all platforms see
  each other. Windows support for `swift-crypto`, sockets and Windows
  Hello PRF is verified at plan time; if any fails, Windows ships
  passkey-less (local identity) and still on the same store.

## 10. Threat model (what the design promises)

| adversary | can | cannot |
|---|---|---|
| store host / anyone with the credential | see file names, sizes, kids, timing; delete or garble files | read any content; forge a member's envelope or a roster |
| a member | read what teammates chose to share to them and the leaders' aggregates | read other members' leader-only data, even with repo access |
| a removed member | keep ciphertext already fetched and readable to them | read anything published after removal |
| a stolen Mac while the app runs | everything that Mac's identity can read | reach a passkey-derived identity after the passkey is removed from the account |
| the app vendor | nothing: no host, no telemetry | — |

Not covered: a compromised leader machine; traffic analysis on the
remote; a malicious leader (they can read what is shared to leaders, by
design).

## 11. Testing
- Unit (InfinitusCoreTests, runs on Linux CI): envelope round trip and
  tamper rejection; roster signature + `rev` rules; audience wrapping
  (leaders / team / chosen, promotion re-wrap); per-project exclusion in
  the publisher; redaction fixtures; transcript chunking; `TeamReader`
  folding; invite payload verify + expiry + nonce; mDNS packet
  encode/decode; identity derivation vectors (fixed secret → fixed
  kids).
- Integration (`swift test`, macOS + Linux): two identities, a local
  bare repo as the remote, create → invite → request → approve →
  publish → fetch → read; remove → publish is ignored; leave.
- e2e (`tools/e2e.sh`): the Mac app creates a team against a bare repo
  in `$SOCKDIR`, a second identity (the CLI in-process) joins with a
  team code, publishes a fixture transcript, the app's `team-status`
  reports the member; idle CPU gate unchanged.
- Manual: passkey PRF on Mac + phone (same identity on both), biometric
  lock timings, Nearby between two Macs and a Linux box.

## 12. Build order (one spec, one plan, PRs in this order)
1. Crypto + envelope + identity (local path) + `TeamStore` + git adapter
   + roster; `infinitusctl team create|request|approve|publish|fetch`
   against a bare repo. Linux CI green; a `windows-latest` Swift job
   for InfinitusCore + InfinitusCLI added to ci.yml — Windows is
   best-effort until that job exists.
2. Publisher: Stats.Day / now / sessions / transcripts / crashes,
   exclusions, audiences, redaction, chunks; `TeamReader`.
3. Biometric lock setting (Mac + phone) and the team gate.
4. Passkey identity (Apple), AASA on the site, export/import.
5. Mac Team pane + control commands + e2e step.
6. Invite link/QR, team code, `infinitus://join`, requests UI.
7. Nearby: TXT + endpoints on the Mac, `MDNS.swift` + CLI listener on
   Linux/Windows.
8. Phone Team tab via the mirror.
9. Leader insights: member detail, comparison, blockers board,
   aggregates publish, members' view.
10. Site + README + CHANGELOG (one line per feature).
Phase 3 (later): narrative digests, shared fleets, live peer view,
two-way driving, folder/S3 adapters, phone-only members, Windows Hello
PRF if not verified in step 4.
