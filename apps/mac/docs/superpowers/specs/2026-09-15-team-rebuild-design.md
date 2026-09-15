# Team — rebuild into the unified app (design)

Status: approved by the rulings recorded in #1313 (the brainstorming
approval gates could not run interactively; every decision below is either
a ruling from #1313 or a call this document makes explicit and #1313's
comment surfaces for the owner to overrule).
Date: 2026-09-15. Issue: #1313. Supersedes for this rebuild:
`2026-09-05-team-design.md` (the core design, still the reference for the
sections this document says are kept verbatim) and
`2026-09-07-team-session-control-design.md` (delegated control, re-homed
on threads in §8).

## 1. What this is

Team went out with #1061 / #1044 / #1171 / #1159 because it was built on
three things the unified app no longer has: the Mac's terminal sessions,
the Mac's mirror HTTP server, and a Mac-only pane. The crypto core and
the store were sound and are restored as they were. Everything above them
is re-homed on what the unified app has today: threads on the desktop
server, one control-socket API, a web Settings pane, a phone screen and a
headless Mac.

What stays exactly as the 2026-09-05 spec says (sections cited): identity
(§3; local keychain + recovery key path), envelope v1 (§4), the store
protocol and git adapter (§5), the roster, membership, promotion chain and
removed-member cutoff (§6), join by team code with #161's `proof` (§6.3),
paths bound to kinds (§4.3), redaction and chunking (§7.3), aggregates
(§7.5). None of it is redesigned here.

## 2. The eight architecture changes

| # | Change since the old spec | Answer | Lands in |
|---|---|---|---|
| 1 | Terminal sessions are gone; the unit is a thread | The `sessions` kind becomes `threads`; `now` is rebuilt from the desktop server's thread shells and the activity card the server already pushes; transcripts are thread transcripts read from the desktop server (§4) | `TeamDocs`, `TeamKinds`, `TeamPublisher`, `DesktopAPI` (apps/mac) |
| 2 | The Mac's mirror HTTP server is gone; the phone reaches the Mac only through the desktop server | The phone's Team screen sends the same `infinitus.command` / `infinitus.secret` the web sends; no phone-specific transport (§6.3) | `apps/mobile/src/features/team/` |
| 3 | One API over the control socket, contracts hand-written | Every Team action is a `team-*` verb in `ControlProtocol.swift`; reply shapes in `packages/contracts/src/infinitus.ts` (§5) | `ControlProtocol.swift`, `ControlServer.swift`, `infinitus.ts` |
| 4 | Biometric lock exists (#788) | Kept as the old spec §2.2 had it: minting an invite or a team code and approving a request need the lock on; `lock off` in a team needs `--yes` (§5.4) | `LockModel.swift`, `ControlServer.swift`, `InfinitusLockPanel` copy |
| 5 | `infinitus://` is claimed by both apps | The desktop takes `infinitus://join/<payload>` back (#1044 removed it); the invite link users see is the universal link `https://infinitus.run/join#<payload>`, the `/pair` shape from #724 (§7) | `InfinitusDeepLinks.ts`, `packages/contracts/src/ipc.ts`, `apps/mac/site`, `App.tsx` |
| 6 | No Windows build | The CLI's in-process `team` subcommands build for macOS and Linux only; no Windows job, no systemd units (§9) | `Package.swift`, `TeamCommand.swift` |
| 7 | Surfaces are web, phone, Mac menu bar | Web: Settings › Infinitus › Team. Phone: Settings › Team. Mac: no pane; a headless `TeamModel` behind the verbs (§6) | `apps/web`, `apps/mobile`, `apps/mac/Sources/Infinitus/TeamModel.swift` |
| 8 | The crypto core can come back as it was with #161's fix | Restored verbatim from `4947e663df` with its tests and the `CZlib` target; the fix is already in that tree (§3) | `apps/mac/Sources/InfinitusCore/Team/`, `Tests/InfinitusCoreTests/` |

## 3. Crypto core (restored, slice 1)

Restored by `git checkout 4947e663df -- <path>` (never from the old plan
files, which #55 records as carrying pre-fix listings): `Base32`,
`CanonicalJSON`, `Deflate` (+ the `CZlib` system-library target in
`Package.swift`), `DrainingPool`, `Envelope`, `PBKDF2`, `RecoveryKey`,
`Signed`, `TeamIdentity`, `TeamIdentityExport`, `TeamSecrets`,
`TeamPaths`, `TeamCode`, `TeamRequest` (with `proof`), `TeamInvites`,
`TeamRoster`, `TeamKinds`, `TeamStore`, `TeamGit`, `TeamClient`,
`TeamChunker`, `TeamRedaction`, `TeamPublishState`, `TeamShares`,
`TeamTranscriptChoices`, `TeamExclusions`, and `TeamDocs` for the document
shapes.

Two edits at restore time, both because the symbols they name are gone:
`TeamDocs.Now` loses `endpoints` (was `TeamControl.Endpoints?`) and
`grantHints` (delegated control returns in §8 with its own shape);
`TeamKinds.controlKinds` (`command`, `ack`, `hostname`) goes with them.
Everything the compiler still accepts stays byte-for-byte, comments
included.

Not restored: `NearbyRecord`, `TeamNearby`, `TeamMirror`, `TeamSnapshot`,
`TeamHostnames`, `TeamControl*`, `TeamGrants*` (see §10).

Tests: every test file whose subject is restored comes back with it
(`PBKDF2`, `RecoveryKey`, `TeamChunker`, `TeamDeflate`, `TeamEnvelope`,
`TeamGit`, `TeamIdentity`, `TeamIdentityExport`, `TeamInvites` minus its
Nearby case, `TeamMembership`, `TeamRedaction`, `TeamRoster`,
`TeamSecrets`, `TeamSettings`, `TeamShares`, `TeamTranscriptChoices`,
`TeamClient` minus the `TeamReader` scan cases, which return with the
reader in slice 2). CI: `mac-test` runs `swift test --parallel` as now;
the old `mac-test-team` split is not brought back unless the suite's wall
time needs it (the ruleset names `mac-test`, so a split keeps that name
and adds one). `mac-linux` builds `CZlib` on the `swift:6.1` image as it
did before #1061, no apt step.

Identity stays local-keychain + recovery key + export/import. The passkey
PRF path (old §3.4) stays unwired: it needs a provisioning profile the
build still lacks.

## 4. Documents on threads (slice 2)

The store layout, envelope audiences and branches are the old §7 table.
The kinds are:

| kind | path | source now | change |
|---|---|---|---|
| `stats` | `stats/days/<day>.json` | `Stats.Day` from `StatsScanner` | unchanged |
| `fleet` | `fleet.json` | `FleetDoc` | unchanged |
| `crashes` | `crashes.json` | `CrashReport.summary` | unchanged |
| `now` | `now.json` | see below | rebuilt |
| `threads` | `threads/index.json` | desktop server thread shells | replaces `sessions/index.json` |
| `transcripts` | `transcripts/<thread>/<n>.json` on `t/<kid>` | `DesktopAPI.thread(id, turnLimit)` | source changes, shape kept |
| `aggregates` | `roster/aggregates/<period>.json` | leaders, from `stats` | unchanged |

`now.json`: `at`, `machine`, `windows` (unchanged), `fleets` (unchanged),
`live` = one row per thread whose session is `starting` or `running`
(thread id, title, project basename, `startedAt`, the `activityLine` the
activity card carries), `blockers` (unchanged), `sharesTo` (unchanged).
The Mac reads the shells with `DesktopAPI.shell()` using the origin and
token `DesktopCredential` already holds (the CLI's `desktop-token` hop is
not needed in-process); with no desktop credential `live` is empty and
`now.json` says `desktop: false`.

`threads/index.json`: one row per thread on the primary environment,
newest `updatedAt` first, capped at 500: `id`, `title`, `project`
(basename only), `status`, `createdAt`, `updatedAt`, `turns`, and `usage`
(the shell's `ThreadUsageRollup`: tokens, cost estimate, models) when the
shell carries it. Never a message body, a path beyond the basename, or a
branch name.

Transcripts: a thread transcript is the desktop server's thread detail
(`turnLimit` = the member's choice, `TeamTranscriptChoices` unchanged),
flattened to the old transcript row shape (role, text, tool name and
summary line, timestamps), redacted by `TeamRedaction`, chunked by
`TeamChunker`, published on `t/<kid>`. The publisher stops reading
`~/.claude/projects/*.jsonl`: a thread's provider is not always Claude,
and the desktop server's detail is the one record all clients already
trust. Opt-in per member as before (`team share transcripts on|off`,
default off).

Publisher loop: `TeamModel` on the Mac runs the old 300 s cycle (fetch,
publish, compact-when-due) on `DispatchQueue "run.infinitus.team"`, the
store under `AppSupport/team/`, secrets in the keychain
(`run.infinitus.team`) or in `INFINITUS_TEAM_DIR` when set (e2e and dev).
A cycle that finds no desktop credential publishes `stats`, `fleet`,
`crashes` and a `now` with `desktop: false`, and logs once.

Reader: `TeamReader` and `TeamInsights` return as they were, with the
session-shaped insights (`LiveSession`, `SessionRow`) re-typed on the
rows above; blockers and headroom are unchanged.

## 5. Verbs and contracts (slice 2)

Every verb goes in `ControlProtocol.swift`'s manifest so the web and phone
gate on the manifest, never on a version, and the visual fixture's guard
sees it.

| verb | args / options | effect | stdin | reply |
|---|---|---|---|---|
| `team-status` | — | read | — | `null` when not in a team, else `TeamSnapshot` (below) |
| `team-create <name>` | `--remote <url>`, `--as <your name>` | write | secret (the remote's token, when the URL needs one) | `TeamSnapshot` |
| `team-join <your name>` | — | write | secret (the team code) | `{requested: true, kid}` |
| `team-code` | `--days n`, `--invite` (one-use nonce) | write (the invite book changes) | — | `{code, expires}` (rendered, never logged) |
| `team-fetch` | — | write | — | `TeamSnapshot` |
| `team-publish` | — | write | — | `{published: [paths]}` |
| `team-approve <kid>` / `team-decline <kid>` | — | write | — | `TeamSnapshot` |
| `team-remove <kid>` / `team-promote <kid>` | — | write | — | `TeamSnapshot` |
| `team-leave` | `--yes` | write | — | `{left: true}` |
| `team-share <kind> <audience>` | audience ∈ `team`, `leaders`, `nobody` | write | — | `TeamSnapshot` |
| `team-exclude <add|remove> <slug>` | — | write | — | `TeamSnapshot` |
| `team-policy requests <open|code|off>` | — | write | — | `TeamSnapshot` |
| `team-insights` | `--period <p>` | read | — | `TeamInsights` (blockers, headroom, aggregates) |
| `team-identity` | `--export` | read | secret with `--export` (the passphrase) | `{kid, exported?}` |

`TeamSnapshot` is the old `TeamSnapshot.swift` shape (restored in slice
2, so the web pane's old decoder still reads it) with `sessionsNow`
renamed `threadsNow`, and four fields added: `policy: {requests}`,
`shares: {kind: audience}`, `exclusions: [slug]`, `lockEnabled`. Encoded
by the Mac's `JSONValue.of`, decoded at the boundary by
`InfinitusTeamSnapshot` in `packages/contracts/src/infinitus.ts` (like
`InfinitusLockStatus`); the phone and the web import that one schema.
`TeamInsights` pins `blockers` and `headroom`; aggregates rows decode one
at a time like `buildForecast`'s lines. `TeamCode` is `{code, expires}`
and is never put on a span or a log line.

Secrets rule: the team code on `team-join` and a remote token on
`team-create` travel on the request line's `secret` field via
`infinitus.secret`; the web and phone send them only to verbs whose
manifest says `stdin: "secret"`, as the Engines pane does.

### 5.4 The lock

The old §2.2 gate, on the same three actions: `team-code` (either form)
and `team-approve` refuse while `lock-status.enabled` is false with "turn
the biometric lock on first"; `lock off` in a team refuses without
`--yes` (`LockModel.teamNames()` reads the configs under
`TeamPaths.standard()` again). Create and join are not gated, as before.
The e2e keeps the lock off and never needs a bypass: it mints the code
with the CLI's in-process `team code` against the leader's
`INFINITUS_TEAM_DIR`, and the CLI has no lock to check (the lock is the
app's).

### 5.5 CLI

`infinitusctl team …` returns for macOS and Linux (§9) with the
subcommands the e2e's second identity and a Linux member need: `create`,
`code`, `request`, `status`, `requests`, `approve`, `decline`, `fetch`,
`publish`, `members`, `share`, `exclude`, `identity`, `leave`. With the
app running and no `INFINITUS_TEAM_DIR`, the app-answered ones route to
the socket (#354's rule, restored). No `nearby`, no `control`.

## 6. Surfaces (slices 3 and 4)

### 6.1 Web — Settings › Infinitus › Team

Route `settings.infinitus.team.tsx` over `InfinitusTeamPanel.tsx` +
`team.logic.ts` (the #1044 files restored and trimmed): the panel reads
`team-status` through `infinitus.command`, and offers:

- Not in a team: Create (name, remote, your name; the token field is a
  password input sent as the secret) and Join (your name + the code as a
  password input; a pending `pendingTeamJoin` from a link prefills the
  code).
- In a team: Members (role badge, last seen, Promote / Remove for
  leaders), Requests (Approve / Decline, hidden unless leader), Invite
  (Mint a code → the code shown once with a Copy and a "Copy link"
  building the universal link, §7; disabled with the lock's own copy while
  the lock is off), Sharing (a select per kind), Exclusions, Policy,
  Sync (last fetch / publish / error, Fetch now, Publish now), Leave.

Gate: manifest carries `team-status`, else "no team commands". Every
error is the app's text verbatim. Registration: `settingsSearch.ts`
(`SettingsPath` `/settings/infinitus/team`, label, search item),
`SettingsSidebarNav.tsx` (icon, `INFINITUS_SETTINGS_PATHS`),
`routeTree.gen.ts` regenerated, `fork-visual-routes.ts` marker
"Members" with the fixture answering `team-status` (added to the
fixture's data manifest only after the Mac declares the verb, or the
guard fails).

### 6.2 Mac

No pane. `TeamModel` is headless: the loop, the verbs' implementation,
`Activity` log lines for every action. `MenuBar` gets no item. The
standalone `make-app.sh` build drops its dead `CFBundleURLTypes` for
`infinitus://` (no handler is left in the Mac sources since #1041; the
nested Menu Bar build that ships never registered one).

### 6.3 Phone — Settings › Team

`apps/mobile/src/features/team/TeamRouteScreen.tsx` (route
`SettingsTeam` in `Stack.tsx`, target in `settings-sheet-targets.ts`, a
row in `SettingsInfinitusSection`): one section per paired Infinitus
Mac (the Accounts screen's `infinitusMacs` shape), each reading
`team-status` through the phone's `infinitus.command` atom and offering
Join (name + code, `infinitus.secret`), Members, Requests with Approve /
Decline, Fetch now. No Create, no Sharing, no Leave on the phone: those
are the desktop's. A universal link (§7) opens this screen with the code
filled and the first Infinitus Mac selected.

## 7. Links

Users share one link: `https://infinitus.run/join#<base64url
Signed<TeamCode>>`. The payload is in the fragment, so the site's server
never sees it (the `/pair` rule, #724).

- `apps/mac/site/public/join.html`: shows "Open this on a Mac running
  Infinitus, or on the phone app"; on a desktop browser it forwards to
  `infinitus://join/<payload>`; with no handler it shows the code with a
  Copy so the user can paste it into Settings › Infinitus › Team. AASA
  gains a `/join` component for `Q783W6B4FA.run.infinitus.mobile`;
  Android's intent filter in `app.config.ts` adds the path. Deploy is by
  hand (`npx wrangler deploy` from `apps/mac/site`), a prerequisite the
  phone slice names.
- Desktop: `DesktopDeepLink` gets `join` back (`packages/contracts/src/ipc.ts`,
  `InfinitusDeepLinks.ts` claims the `join` host; `pair` stays unclaimed);
  `DeepLinkCoordinator` stores the payload in `pendingTeamJoin` and
  navigates to Settings › Infinitus › Team, which prefills the code. The
  Mac app registers nothing for the scheme, so there is no second
  claimant any more.
- Phone: `appLinking` rewrites `https://infinitus.run/join#…` to the
  `SettingsTeam` route with `code=<payload>`.

`infinitus://join/…` still works when typed or scanned; it is not what
the app shows.

## 8. Delegated control (slice 6, last)

The 2026-09-07 design, on threads:

- Grant = audience × threads × capabilities. Threads by id, or `*` for
  every thread on the grantor's primary environment. Capabilities:
  `view` (thread detail through the grantor), `send`, `interrupt`, `new`
  (a thread in a named project). `preauthorized` and `expires` as in
  Phase 2; approvals (`pending`, 2-min TTL) as in Phase 2.
- Command and ack envelopes: sealed `command` / `ack` kinds under
  `m/<kid>/control/…` return to `TeamKinds`; `TeamControl.verify` order
  is unchanged (sig/roster, `to == me`, ttl, replay, grant, live, rate).
- Execution: the grantor's Mac runs the command through `DesktopAPI`
  with its own desktop credential: `send` → `dispatch(thread.turn.start)`,
  `interrupt` → `dispatch(thread.turn.interrupt)`, `new` →
  `dispatch(thread.create)` then `start`, `view` → `thread(id, turnLimit)`
  redacted. A driver's command therefore has exactly the rights the
  grantor's own desktop session has, never more.
- Lanes: (1) a new unauthenticated desktop route `POST
  /api/infinitus/team/command` (the pairing routes' precedent, #710) that
  forwards the sealed envelope to the Mac's `team-inbox` verb on the
  request line's `secret` field and answers the sealed ack; reachable at
  the grantor's published `httpBaseUrl`, `lanHttpBaseUrls` and tunnel,
  which `now.json` gains as `endpoints` again; (2) the store lane as
  before. Hostnames via Cloudflare and the rendezvous KV lane are
  dropped (§10). The route is safe to expose unauthenticated because the
  envelope is what authenticates: an unverifiable one is refused before
  anything is looked up, and the verb rate-limits per sender.
- Surfaces: web Team pane gains Grants and Pending; the phone gains
  "Send to <member>'s thread" only after the lane works from the web.

The slice's plan stays high-level until slices 1–5 have landed; the spec
answers the lanes so no slice before it forecloses them.

## 9. Platforms

macOS and Linux build `InfinitusCore` + `InfinitusCLI` with Team. No
Windows job (#1269 dropped it; `CZlib` needs vcpkg there). No systemd
units (`infinitus-team.service/.timer`, #1171): a Linux member runs
`infinitusctl team publish` from its own scheduler if it wants to; the
tray does not run the loop in v1.

## 10. Dropped and deferred (and why)

Each of these narrows a ruling in the old specs' preambles; #1313's
comment lists them for the owner.

- **Nearby (mDNS discovery, LAN invite)** — dropped. It rode on the mirror
  HTTP server and `MDNS.swift`, both gone; the phone's LAN sweep (#651)
  and the desktop's `/.well-known/t3/environment` are where a re-home
  would go (team `kid` + name as descriptor fields), later.
- **Hostnames via Cloudflare API and the rendezvous KV lane** — dropped.
  The tunnel the desktop already publishes (`status.forkTunnel`,
  `alternateHttpBaseUrls`) is the reachable endpoint; the site's
  `worker.js` has no rendezvous route left and gets none.
- **Passkey identity** — deferred (no provisioning profile); local +
  recovery key + export/import is the only path, as it already was in
  practice.
- **Mac pane** — dropped. Web and phone are the surfaces.
- **Session-shaped documents** (`sessions/index.json`, live terminal
  sessions, Claude jsonl transcripts) — replaced by thread-shaped ones
  (§4). A team on the old layout is not migrated: the old `sessions`
  paths are ignored by `TeamKinds.expected` and compacted away.
- **Windows** — out (§9).
- **Transcripts from `~/.claude/projects`** — replaced by the desktop's
  thread detail (§4).
- **`team-sessions` / `team-drive` / `team-pending` / `team-allow` /
  `team-deny` / `team-grants` / `team-grant` / `team-revoke` /
  `team-discoverable` / `team-hostname`** — return only as the §8 slice
  defines them (thread-shaped), not before.

## 11. Slices

One PR each, in this order; the plan has the steps.

1. Spec + plan (this document; docs only).
2. Crypto core (§3): files, tests, `CZlib`, `TeamCommand` with the CLI
   subcommands in §5.5 (the e2e's team round needs the app's verbs and
   lands with slice 3).
3. Verbs + contracts + Mac loop (§4, §5): `TeamModel`, `ControlProtocol`
   entries, `ControlServer` cases, `threads`/`now` on `DesktopAPI`,
   lock gates, contracts, fixture `team-status`.
4. Web pane (§6.1) + desktop `join` link + site `join.html` + AASA.
5. Phone screen (§6.3) + universal link rewrite.
6. Delegated control (§8).

Transcripts (§4) ship in slice 3 if the flattening is small, else as a
slice between 5 and 6; the plan decides on the shell's real shape.

## 12. Testing

Swift: the restored tests, `TeamModel` tests over `INFINITUS_TEAM_DIR`
with a file-backed bare remote (the old `TeamGitTests` fixture), a
`DesktopAPI` stub for `now`/`threads`. e2e: the old round (create, code,
CLI request, fetch, approve, publish, share off, stdin refusals) plus
`team-status` shape. Web: `team.logic.test.ts` (gates, decode, secret arg
shapes), the fork visual pass route. Phone: `team.logic.test.ts` for the
link rewrite and the section fold. Contracts: decode fixtures for
`TeamSnapshot` and `TeamInsights`.
