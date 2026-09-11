# Open items (carried over from the claude-swap session, 2026-08-29)

## Done 2026-08-30
- ~~Caffeine integration~~ → built as a native power assertion instead
  (KeepAwake.swift, Display pane toggle); Caffeine.app path dropped —
  it required writing another app's prefs.
- ~~Session counter breakdown~~ → engine emits idle/waiting/shell/unknown
  (additive in `liveSessions`); shown in the brain chip's tooltip
  (user picked tooltip over chip).
- ~~Dev loop~~ → `UNBUNDLED=1 ./dev.sh` relaunches through
  run-unbundled.sh; relaunches debounced to one per 10s.

- ~~Switch celebration "looks broken"~~ → two causes, both fixed:
  Grid layout attached the sweep to the number cell only (now an
  anchor-preference overlay sweeping the whole row), and the sweep
  gradient carried the theme color at opacity 0 (pure white band for
  every theme) — shoulders now tinted + a themed wash glow.
- ~~Glass chrome~~ → NSVisualEffectView `.menu` material, behind-window,
  on the popover content and the (now non-opaque) pop-out window; on
  macOS 26 a Liquid Glass layer (`glassEffect(.regular, in: .rect)`)
  rides on the blur (glassChrome()). Drop one layer if it looks doubled.
- ~~iCloud sync setting home~~ → own "Sync" pane (SyncPane.swift).
- ~~Theme requests~~ → builtins `agent` ("AI Agentic — tokens & context")
  and `swe` ("Classic SWE — hand-written, no AI").
- ~~About pane icon~~ → real app icon when bundled; unbundled draws the
  menu bar glyph on the gradient card (the retired ∞ is gone).

- ~~Bundle id~~ → `com.huuloc.limitless`, done 2026-08-30 as the one
  intentional step (superseded 2026-09-03: `com.huuloc.infinitus`,
  prefs migrate again; re-grant notifications + login item); it was the one
  intentional step: prefs copy-migrate from the g2 domain on first
  launch, themes.json copy-migrates from `CswapBar/`; re-grant
  notifications + login item once under the new id.

## Deferred by design
- ~~Community theme gallery URLs 404~~ → repo pushed 2026-08-30;
  index.json + synthwave fetch verified live (HTTP 200).
- Codex backend support: landscape researched (codex-rotate, codex-switcher,
  opencode plugin, openai/codex#9648); feasible as a second engine backend
  behind the same isolation boundary. Not requested.
- Router ecosystem (9router / n9router / ai-9router, 2026-08-30): local
  proxies that rotate provider accounts per-request via ANTHROPIC_BASE_URL.
  Opposite layer to cswap's credential swap — running both fights.
  → 9Router requested and shipped as the THIRD engine 2026-09-03
  (#19, docs/research/9router-backend.md): NineRouterEngine over the
  dashboard API, keychain password, switch/hold/remove, verified live.
  Still open there: "routed via …" detection of ANTHROPIC_BASE_URL,
  Linux tray parity, cost report.
- Developer ID signing: proven end-to-end 2026-09-01 under the company
  team (cert → notarytool Accepted → staple → spctl pass → 5 CI
  secrets), then UNSIGNED same day on user request ("I'll be providing
  a new account"): secrets deleted, identity removed from the keychain,
  CI back on the ad-hoc path. The runbook is exercised — redoing it
  with the new account is ~10 min (docs/RELEASING.md). Cert artifacts
  left on disk for the user to discard (~/Desktop/devid-csr,
  ~/Downloads/AuthKey_339Q7369BM.p8 — p12 unopenable, its password
  died with the secret).

- ~~AppIcon ∞~~ → make-icon.swift now scales the MenuBarGlyph path
  (identity source of truth) onto the gradient squircle; icns rebuilt.
- ~~Sync "pushed" under an off toggle~~ → disable-mid-tick race; tick()
  re-checks `enabled` after its await before any write.

## Listing PRs to open (user 2026-09-04: "save the list for later")

Docs-only "list Infinitus" PRs, like CLIProxyAPI's "Who is with us?"
(router-for-me/CLIProxyAPI#5452, merged). Verified 2026-09-04 by reading
each README + CONTRIBUTING; best first.

- **jaywcjlove/awesome-mac** (112k★) — Utilities → Menu Bar Tools.
  Fork+PR, alphabetical, one-sentence title-cased description, OSS +
  Freeware icons; no star/age gate. Precedent: cctop, Agent Island,
  CodexIsland.
- **rohitg00/awesome-claude-code-toolkit** (2.6k★) — "Companion Apps &
  GUIs" table (`| [name](url) | stars | description |`). Fork+PR, no
  gate. Precedent: TokenEater.
- **hesreallyhim/awesome-claude-code** (53k★) — Observability &
  Monitoring → Usage & Cost (or Session Monitors). NOT a PR: web issue
  form only (gh CLI disallowed); needs 14+ days old with active commits
  OR 100+ stars; one resource per submission; no emojis / sales copy.
  Precedent: ClaudeBar.
- **jqueryscript/awesome-claude-code** (508★) — Clients & GUIs or Usage
  & Observability. Guidelines "under construction"; fork+PR. Medium.
- **iCHAIT/awesome-macOS** (19k★) — macOS Utilities. Fork+PR, informal;
  no AI precedent there. Weak.

Checked, no community/related section (not viable): decolua/9router,
musistudio/claude-code-router, ccusage/ccusage,
Maciek-roboblog/Claude-Code-Usage-Monitor, nguyenphutrong/quotio,
vlondon/awesome-swiftui; the other "Who is with us?" siblings keep no
list of their own.

## Open — tracked as GitHub issues since 2026-09-01

- **Phone: a Continue button for a stopped session** (user 2026-09-04
  from the phone: "develop a button on ios when clicked it continues the
  session that maybe stopped by various reasons"). Mac half shipped
  2026-09-04: `SessionInput.Request.Kind.resume` — the Mac composes the
  continue text (limit, crash, closed terminal, whatever), socket first,
  terminal fallback, same outcomes as a message; Linux `serve` gets it
  through the same `deliver`. Phone half (Infinitus): a "Continue" button
  on the session feed/detail when the session is idle/waiting with no
  prompt or its last item is a limit stop, POSTing `{kind:"resume",
  text:""}`; a 400 from an older Mac → "update Infinitus on the Mac".

Open work lives at github.com/deathemperor/infinitus/issues (user
2026-09-01: "move todo items to use github issues tracking"); this
file keeps the shipped log and the deferred-by-design notes.

- ~~infinitusctl~~ → shipped 2026-09-03: agent-facing control CLI.
  `ControlProtocol` (InfinitusCore: request/reply, manifest table,
  socket path), `ControlServer` (app: same-user UNIX socket in App
  Support, one JSON line each way, dispatch on the manifest, every
  action through the same FleetState/AppModel calls as the panes),
  `infinitusctl` executable bundled in Infinitus.app/Contents/MacOS.
  Verified live: status/fleets/proxy/manifest, rename + routing
  round-trips, remove/--yes and bad-fleet guards. The cask gains a
  `binary` stanza for `infinitusctl` on the first release that ships it
  (release.yml). `rotate`/`reorder` verbs shipped 2026-09-03; tools/e2e.sh
  round-trips every verb on the demo engine in CI.
- ~~#1 All-dead Live Activity (iOS + macOS equivalent)~~ → shipped;
  the macOS floating countdown panel landed 2026-09-03 (RevivalPanel).
- ~~#2 Working-sessions Live Activity design~~ → shipped (WorkingActivity).
- #3 Slack push mirror to mobile
- #4 Capture quality (window captures + bright backgrounds)
- #5 Resume nudge typed but never submitted (Enter delivery)
- #6 Playground simulations (onboarding + auto-switch scenarios)
- #7 Infinitus smart engine — reset battle plans, window-start
      scheduling, capacity advice ("the big Infinitus"; plan last).
      Layer 1 (WindowTelemetry) and layer 2 (WindowPlanner: ignite /
      switch / hold / reset steps, replay report, burn rate; Utilization
      pane "Battle plan — dry run"; samples now carry `active`) shipped
      compute-only 2026-09-03. Same day, MVP step 3 (manual mode): the
      live plan rides the popup's error slot (`BattlePlanLine`, next to
      the all-dead banner) with a two-tap confirm-gated "Ignite" that
      runs `cswap run <n> -- -p . --max-turns 1` (PATH widened to reach
      `claude`; result in the event log); `infinitusctl plan` returns
      the plan (e2e-gated). Then (user: "go with your suggestions"):
      ignite is an engine capability (`.ignite`; cswap via `cswap run`,
      proxy not yet — needs an upstream verb), `infinitusctl ignite`,
      window-age guard (≥ 90 min left at the bind), strategist dropped,
      auto toggle parked (engine-side if ever), replay after a week of
      `active`-flagged samples decides further investment. Decisions
      recorded in docs/research/smart-engine.md.
- ~~#8 CLIProxyAPI alternate backend~~ → shipped 2026-09-02 as the
  multi-engine seam: `AccountEngine` + `EngineFleet` + capabilities in
  InfinitusCore, `FleetState`/`EngineRegistry` in the app (AppModel stays a
  FleetModel facade over the primary Claude fleet), `FleetStack` popup
  sections, `CLIProxyEngine` over the Management API (keychain key,
  hold/switch-as-priority/rename/remove/OAuth add/usage ledger), Engines
  pane with both toggles + layer-fight warning; dev proxy installed via
  brew (docs/research/multi-engine.md §6/§9). Same day: module renamed
  InfinitusCore with per-engine dirs; proxy sign-in through the in-app
  chooser (`is_webui=true`, shared per-account cookie jar); Accounts tab
  lists every fleet with one row design; usage polled once per account
  (cache + per-email dedupe + `offerSharedUsage`). Verified live with two
  credentials. Evening: routing picker on the CLIProxyAPI tab (PUT
  `routing/strategy`, caching/affinity notes), switch + strategy live
  round-trips (reversible; remove stays stub-only), redacted 7.2.145
  live fixtures, `MirrorSnapshot.fleets` for the phone (iOS side still
  to consume it), Linux docker build green (Core + Tray), guides in
  docs/guides/ (human walkthrough + agent brief), upstream draft for a
  session-affinity route (docs/research/, not posted). Still open:
  upstream quota endpoint PR; iOS FleetScreen stacking `fleets`. Codex
  onto AccountEngine parked (user 2026-09-02: focus on Claude).
- #9 Mobile companion app (brainstorm done, user picks pending)
- #10 Human handoffs: AUR publish, Linux real-account cswap, signing
- ~~#11 Full-screen mode~~ → shipped 2026-09-01 (Display → Fleet wall,
      screen picker, scaled popup body, Esc leaves)
- ~~#12 Fleet wall layout~~ → shipped 2026-09-01 (mission-control
      hero/rail/bench; wall is a mode — popup/pop-out close)
- Remote routes that survive an Infinitus restart (user 2026-09-03,
  phone on 5G far from the Mac: Wi-Fi unreachable, no Tailscale on the
  phone, quick tunnel gets a NEW random URL every launch → rescan per
  restart). Every option, so the pick is recorded:
  - Tailscale on the phone (zero code): the stored 100.x route then
    outlives restarts. Needs the Tailscale app + same login on the phone.
  - Tailscale Funnel route: `tailscale funnel 47824` → stable public
    `https://<mac>.<tailnet>.ts.net`, nothing on the phone, no domain;
    one-time Funnel enable in the tailnet admin. Infinitus offers it as
    a route next to the quick tunnel (Tailscale.app bundles the CLI).
  - Tailscale Serve (tailnet-only HTTPS `https://<mac>.<tailnet>.ts.net`
    with a real cert) — only matters if the phone is on the tailnet
    anyway; noted for completeness, not planned.
  - Cloudflare NAMED tunnel (user has CF account + domain — the pick
    2026-09-03): dashboard-managed tunnel (Zero Trust → Networks →
    Tunnels → Cloudflared, public hostname `infinitus.<domain>` →
    `http://localhost:47824`), Mac keeps only the tunnel token (keychain,
    `TUNNEL_TOKEN` env to `cloudflared tunnel run`, never argv);
    Devices pane "Your domain" row (hostname + masked token), supervised
    child like the quick tunnel, route "Anywhere, your domain" ahead of
    the quick tunnel in the QR. Alternative: locally-managed
    (`cloudflared tunnel login/create/route dns` + config.yml) — more
    steps, no dashboard visit. Linux tray: `parity pending`.
  - Rendezvous for the quick tunnel: Mac publishes its current
    trycloudflare URL to a KV on infinitus.run keyed by a hash of the
    pairing token; phone looks it up when the stored tunnel dies. Keeps
    "no account at all" but adds a service to run — fallback only.
  - Phone fix regardless of route: a dead tunnel URL should be dropped
    or demoted (not retried first every poll) once a sibling route
    answers; and the Settings status should say WHICH route failed.
- Phone session screen asks (user 2026-09-03 evening, after the first
  real 5G use — "session communications on iOS work great"):
  - ~~tool chips combined into one~~ → 5cf4bbf; ~~mid-turn prompts
    missing~~ → 9bba207; ~~cross-session tag shown raw~~ → a73219b;
    ~~markdown bubbles~~ → 1328cec; ~~session names~~ + metadata line →
    af6aa53.
  - Attachments: phone sends an image/file with a message (design: POST
    body carries `attachments: [{name, mime, base64}]`, Mac saves under
    App Support/Infinitus/attachments/<uuid>.<ext> and appends the path
    to the typed/socketed message so Claude Code reads it; size cap).
  - Feed header: which account is active for the session (cswap: the
    fleet's active account; CLIProxyAPI: per-request routing, so show the
    strategy + the accounts it can land on), its 5h/7d limits, and a
    detail screen on tapping the title (session metadata + account/limits).
- Release process (user 2026-09-03): every release must update the
  website (site/) and the GitHub README with the new features so the
  three stay in sync — added to CLAUDE.md as a rule.
- #13 Session progress tracking — watch agents, not accounts
      (zero-token transcript parsing + optional Claude narration;
      brainstorm in docs/research/session-progress.md)

## Shipped 2026-09-02/03 (remote access, engine ranking, two-session flow)

- **Live Activities #1 + #2** (user 2026-09-03 "pick #1 … and #2"):
  widget extension `ios/InfinitusMobileWidgets` (bundle
  `com.huuloc.infinitus.mobile.widgets`, embedded by the app), shared
  `LiveActivityAttributes.swift`. `LiveActivities.sync` runs after every
  mirror refresh: all-dead → RevivalActivity (reviver, native
  `Text(timerInterval:)` countdown to its reset, session count; ends
  with a 2-min "revived — X is back" card), busy > 0 → WorkingActivity
  (active account + plan, binding-window gauge, "N working · M
  sessions", "→ next" hint; updates only on switch / ≥5-pt move /
  count change; 15-min staleDate). No push pipeline yet — updates
  happen while the app runs; APNs from the Mac is the follow-up if the
  lock screen needs to stay live with the app closed. Verified on the
  iPhone 17 simulator (lock-screen card "death2 · Fable 70% · 3
  working · 12 sessions · → deathemperor1st"). The macOS floating
  countdown panel (the #1 "macOS equivalent") followed on 2026-09-03:
  `RevivalPanel.swift`, a non-activating floating NSPanel off the same
  `LiveActivityBuilder.revival` state, Display toggle
  `revival_panel`, gated in tools/e2e.sh's all-dead scenario.
- **Connected devices** (user 2026-09-03 mid-turn "todo: show
  active/connected devices"): the phone sends `X-Infinitus-Device-Id`
  (per-install UUID) + `X-Infinitus-Device` (its name) on every
  request; `MirrorServer.clients` keeps one `MirrorClient` per id
  (route from the Host header: Wi-Fi / Tailscale / quick tunnel /
  the named hostname), and the Sync pane lists them — green dot while
  heard from in the last 90 s, "· route · N s ago". Linux tray: a
  footer chip (2026-09-03) — `serve` notes each phone in a
  `mirror-clients.json` sidecar, `panel` ships it as `devices`.
- **Pairing rendezvous on infinitus.run** (user 2026-09-03 "can the
  domain be reused for other users?" → "1 ok"): `site/src/worker.js`
  serves the landing page as before plus `PUT/GET /rendezvous/<sha256
  of pairing token>` backed by KV (7-day TTL, only *.trycloudflare.com
  URLs accepted, no accounts). Mac: `QuickTunnel.onURL` →
  `AppModel.publishRendezvous` (toggle "Publish the current URL to
  infinitus.run", default on, republished on token regenerate). Phone:
  when every saved route is dead and one was a quick-tunnel URL,
  `NetworkFleetMirror` GETs the rendezvous, swaps the new URL into the
  saved list and retries — no rescan after a Mac restart. Core:
  `MirrorRendezvous` (key/url/isEphemeral/publishBody/parseLookup).
  Verified live against the deployed Worker (404 / 400 / 204 / 200).
- ~~#17 layer 1 session feed~~ → shipped 2026-09-03: `SessionFeed`
  (InfinitusCore, zero-token parse of the session jsonl into
  user/assistant/tool/question/permission/result/limit items,
  consecutive-tool collapsing, `finalize` promotes an open tool call to
  `permission` when the record says waiting), Mac `GET
  /sessions/<pid>/tail?n=` (token-gated, 404 unknown pid, `n` clamped),
  phone `SessionFeedScreen` (chat bubbles, tool chips, permission/question
  cards, 5 s poll). Live: 200/404/401 verified on the bundled app.
- ~~#17 layer 2 reply/decide~~ → shipped 2026-09-03: `SessionInput`
  (kinds `message`/`key`; keys y/n/1-9/enter/esc, PTY only via new
  `PtyNudge.press` which never Esc-dismisses the menu it answers; messages
  go to the peer socket first, the PTY only without one — flipped from
  PTY-first 2026-09-03, same for the resume nudge), `MirrorTransport` request bodies
  (Content-Length, 16 KiB cap), Mac `POST /sessions/<pid>/input`
  (400/404/200 JSON reply), every attempt in Activity (`📲 phone → repo:
  "…" (pty|socket)`), phone composer + Yes/No on a trailing permission card
  + one button per AskUserQuestion option. Phone POST is single-route with
  a 15 s timeout (a retry elsewhere would type twice); typed messages
  collapse newlines. Live: 400/404/rejected + a real message delivered
  over the socket. Linux tray parity landed the same day (6399a2a: POSIX
  server reads bodies, /tail + /input routes, stderr input log; docker
  200/404/400/404/200/noChannel) plus the #13 phase word in Panel.qml
  (QML render unverified — the Omarchy VM would not boot). Push when a
  session flips to waiting-on-you shipped the same night (PushTriggers
  `sessions:` — once per pid, re-arms when answered, seeded silently at
  launch so a relaunch never re-pushes stale prompts; Notify → "A session
  waits on you"). Linux parity a2e1ecb: `infinitus-tray serve` ticks
  PushTriggers every pass (cswap notify push + notify-send + stderr;
  `INFINITUS_PUSH_*` env flags, `--interval`); docker: 0 pushes on the
  seeding pass, exactly 1 on the busy→waiting flip, none while it stays.
  Not yet: multi-Mac picker (#17 item 3).
- ~~Linux parity (#9)~~ → shipped 2026-09-03: panel footer chips (service
  status via cached Anthropic fetch, sessions, engine probe) and
  `infinitus-tray serve/pair` on a POSIX HTTP listener with the same
  token contract (docker: 401/401/200). Omarchy VM would not boot, so the
  QML footer render is unverified.
- ~~Named Cloudflare tunnel route~~ → shipped 2026-09-03: `NamedTunnel`
  (`cloudflared tunnel run`, token in the keychain under
  `com.huuloc.infinitus.cloudflare-tunnel`, `TUNNEL_TOKEN` env), Devices →
  Anywhere → "Expose through your own Cloudflare tunnel" (hostname, masked
  token, Save/Forget, port-mismatch warning), pair route "Anywhere, your
  domain" ahead of the quick tunnel. Live 2026-09-03 as `tunnel.infinitus.run`
  via the locally-managed path (cloudflared login → user authorized the
  zone → `tunnel create infinitus` → `route dns` → ~/.cloudflared/config.yml;
  Infinitus runs `cloudflared tunnel run` with no token when config.yml
  routes the hostname). Quick tunnel turned off — the named one replaces
  it. Linux tray: `parity pending`.
- ~~Phone status names the failed route~~ → shipped 2026-09-03: "couldn't
  reach any saved Mac — 192.168.2.36:47824 didn't answer · …trycloudflare.com
  answered 530 · Wi-Fi discovery didn't answer" instead of "offline". The
  5G "offline" was the phone's stale Bonjour result from the last Wi-Fi
  session. Device builds need `CODE_SIGNING_ALLOWED=YES` on the xcodebuild
  line (project.yml sets NO for the simulator).
- ~~Backend-free remote access (#9)~~ → pairing token (24×base32,
  `Authorization: Bearer` or `?t=`, 401 before routing), QR +
  `infinitus://pair`, Tailscale route (100.64/10 detection; listener
  forced IPv4 — the v6 wildcard was unreachable over the utun),
  Cloudflare quick tunnel (cloudflared child + orphan reaper, verified
  live end-to-end). One QR carries every route; the phone keeps the
  list, last-good first, 3 s per try, falls through — a tunnel URL that
  changes on restart no longer forces a rescan.
- ~~Devices pane~~ (was Sync): "Set up your phone" walkthrough with live
  checks (server records `lastServed`), "Copy for an AI agent" brief
  (token only while revealed), Tailscale status row (get / open /
  connected), cloudflared install hint. No auto-install by design.
- ~~Settings window~~ → resizable 960×640 (min 700×480, frame
  autosaved); macOS 26's launch-time SwiftUI Settings scene window is
  hidden (it re-strips .resizable on every update); ⌘, routed to ours.
- ~~#16 Weekly reset on full-HP rows~~ → Anthropic's weekly window is a
  fixed per-account slot; the usage endpoint omits `resets_at` at 0 %
  for some tokens. Infinitus remembers each account's last reset and
  steps it by whole weeks; the ENGINE now carries the slot forward too
  (claude-swap PR #309, cherry-picked into the deploy branch and
  installed) — consume-first then ranks a 0 % account by its real
  reset instead of "unknown → last" (the user's "why is P2 burning
  while P5/P6 sit at 0 %"). 5h-dead rows keep their 7d reset.
- ~~iOS multi-fleet~~ → one section per `MirrorSnapshot.fleets` entry
  (keyed engineID/provider), listJSON fallback for older Macs.
- ~~Two sessions, one checkout~~ → e2 works in ../limitless-e2 on
  branch e2; main is merge-only, one build owner (CLAUDE.md).
- ~~infinitusctl follow-ups~~ → `INFINITUS_CONTROL_SOCKET` (playground
  + CLI converge), release bump adds the cask `binary` stanza once.
- ~~Supervisor~~ → a refusal within 10 s of our own child's exit
  retries in 3 s (engine restart for an upgrade sat "held elsewhere"
  for a minute). Mock-mode instances no longer write usage history.
- Queued (user 2026-09-03, autonomous run): #17 session feed +
  reply/decide from the phone (layer 1 in progress), Linux parity
  (footer chips, `infinitus-tray serve/pair`; in progress), hot reload
  (InjectionIII download still awaiting permission), ~~#15 pick-first~~
  → engine knob only (user 2026-09-03): cswap `autoswitch.preferred`
  (claude-swap PR #312, star hidden until the installed cswap has it),
  proxy priority tier; the app-side auto-order writer and `auto-order`
  verb are gone, headroom sort is display-only.

## Shipped 2026-09-01/02 (session progress, site, mobile v0)
- ~~#13 Session progress (layers 0+1)~~ → SessionProgress transcript
  parser (todos, nowDoing, goal, retrying, quiet minutes), sessions
  popover rows, wall session board, Linux panel sessions section.
  2026-09-03: layer-1 phase word (exploring / building / verifying /
  wrapping up) from the recency-weighted tool mix; shown only when the
  session has no TodoWrite report (open question 1 resolved that way —
  todos are the agent's own report, the heuristic fills in). Row JSON
  carries `phase`; the Linux panel renders it (6399a2a).
- ~~#14 Landing page~~ → infinitus.run (Cloudflare Workers assets):
  real captures, 1080p popup video, 15 full-popup theme images, brew
  cask, subtle Linux/Omarchy downloads, SEO/agent pass (JSON-LD, FAQ,
  OG card, llms.txt, sitemap).
- ~~"loc recovers in" wrong reviver~~ → RecoveryMath corrects the
  engine's next_recovery (which skips the active account), both OSes.
- ~~#7 layer 1~~ → WindowTelemetry (5h window reconstruction, daily
  rhythm) + Utilization "5h windows" section.
- ~~#9 mobile v0 + fidelity plumbing~~ → FleetMirror seam (mac +
  Linux tray exporters, FleetPrefs travel with the snapshot), iOS app
  scaffold (XcodeGen), InfinitusUI shared target: gauges, burn, theme
  colors, effects, rows/cards generic over FleetModel — pixel-verified
  unchanged on mac. Directive: pixel-perfect; portrait = stacked
  cards, landscape = wide list.
- ~~Popup Rotate/Refresh buttons~~ → retired (obsolete with
  auto-rotation); both stay in the status-item menu. Linux panel's
  footer Rotate button dropped too (`r` key still rotates).
- Omarchy aarch64 VM: built via chroot repairs; expect driver must
  answer busybox ash's ESC[6n cursor query or sends get eaten.

## Shipped 2026-09-01 (second wave — the remote-control batch)

- ~~Usage utilization history~~ → UsageHistory JSONL per machine
  (email-keyed, engine-poll stamped) + WasteMath weekly generations;
  recorders on BOTH OSes (AppModel actor / TrayHistory on the Waybar
  heartbeat, demo engines excluded); Utilization settings pane (range/
  window/account pickers, waste rows with observation-gap honesty);
  iCloud Drive mirror per machine when settings sync is on, merged at
  read. Verified live on the real fleet.
- ~~Onboarding~~ → ClaudeCLIDetect (~/.claude.json oauthAccount) +
  CLIProxyDetect (presence + credential-file count, contents never
  read; a real ~/.cli-proxy-api was found on this machine) + port
  probe; engine-missing card gains detection lines, empty-fleet gains
  FirstAccountCard with one-click `cswap add`; tray tooltip names the
  adoptable login. Empty-fleet was blank — IntroContentReveal held
  content for rows that never come; snapshotLoaded releases it.
  Simulated live: INFINITUS_CSWAP="" and DEMO_EMPTY=1.
- ~~Dying-account flash~~ → macOS CriticalPulse (red breath over rows
  whose binding window is ≥90%, riding the DeadRowBounds anchors);
  Omarchy panel pulses the urgent border (recovery holds steady, the
  pulse is the signal). Verified in the playground.
- ~~Dead-by-5h rows~~ → weekly/spend/per-model gauges stay visible
  with timers skipped; the 5h cause line keeps its own countdown
  (wide/compact/stacked + panel). Verified: killed alpha shows
  "MP down · 2h23m" + HP/$/Dragon gauges timer-less.
- ~~Auto-resume bugs (3 of 4)~~ → ResumeGate: nudges need evidence
  AFTER the stop (switch since first sighting, or usage poll newer
  than the stop) + 10-min per-session cooldown surviving burned
  stopUuids; /rc sweep skips busy sessions and withholds the
  confirm-Esc while "esc to interrupt" shows; sweep idleness measured
  against the stop instant (a 7d wait no longer reads as idle).
  Remaining Enter-delivery report → issue #5.
- ~~Move todos to GitHub issues~~ → issues #1–#10; this file is the
  pointer + history.
- Also: consume-first "why account 1?" answered (at-limit escape +
  self-correction; engine settings verified); CLIProxyAPI Management
  API mapped (docs/research/cliproxyapi-backend.md); mobile companion
  brainstormed (docs/research/mobile-companion.md — effects parity,
  remote control, Teams); Developer ID signing proven then unsigned on
  request; native aarch64 Omarchy VM build launched (ggalancs/
  omarchy-arm-utm, vetted, official sources).

## Shipped 2026-09-01 (the 0.3.0 wave — 8 todos, both OSes)
- ~~Omarchy right-click dead + anim/effects ask~~ → any-button click
  opens the panel (MouseArea acceptedButtons); rows intro, hover/active
  color motion, gauge fills already animated.
- ~~Glass over white apps~~ → GlassScrimView appearance-following wash,
  Settings window only (popup/pop-out keep the tuned dial); playground
  `settings` command via AppDelegate.shared.
- ~~All-dead: waiting sessions + first-reviver countdown~~ → banner with
  live 1s countdown (RecoveryCountdown, TimelineView / QML Timer),
  Transcript.findStopped count, orange marker + urgent border.
- ~~Behind-pace effects~~ → GaugeMath.chillDepth + breathing mint halo
  (macOS) / pulsing fill sheen (panel).
- ~~Disable accounts from rotation~~ → engine disable/enable surfaced:
  Accounts pause/play button, panel row right-click, tray verbs,
  demo-cswap verbs.
- ~~Sort by headroom, active + candidate pinned~~ → DisplayOrder.sort,
  display-only; Accounts toggle (synced sort_headroom) + panel
  sortByHeadroom setting (--engine-order opts out).
- ~~Composed changelogs~~ → CHANGELOG.md; release.yml publishes the
  version's section (--generate-notes only as fallback).
- ~~Release new version~~ → v0.3.0 tagged; first tag exercising
  linux-publish (Linux binaries + omarchy tarball on the release).

## Shipped 2026-08-30 (evening wave — 15 numbered asks + follow-ups)
- ~~Theme preview ': :' rows~~ → macOS 26 VStack ideal-height bug;
  per-row fixedSize; preview bars animated:false. Verified in probe.
- ~~Custom theme reconcile~~ → templateJSON, themes/README table, and
  the synthwave sample now carry every RowTheme field.
- ~~Plain-theme skull~~ → Off theme's dead marker is ✕.
- ~~New themes~~ → Sci-Fi, Wild West, Cyberpunk, Gothic builtins
  (one role per icon each); ThemeColor learned brown. Verified live.
- ~~Theme selection revamp~~ → Themes settings pane: builtin/custom
  card grids + community gallery moved out of Display. Verified live.
- ~~Settings reorder~~ + ~~search box top space~~ → hand-rolled
  SettingsRoot, most-used panes first. Verified live.
- ~~Visual layout/size pickers~~ → PickTile art tiles. Verified live.
- ~~Icon-only menu bar~~ → titleIconOnly override toggle (synced).
- ~~Engine updates into engine pane~~ → Engines → cswap hosts
  auto-update + check/upgrade; About keeps app releases. Verified.
- ~~Resume nudges into cswap pane~~ → status-first rows (check /
  warning + one-click fix, n/2-ready pill). Verified live.
- ~~Rows slide-in intro~~ → introStyle "rows", per-row stagger from
  the right (Group-in-GridRow distribution). Verified live at launch.
- ~~Compact rail responsive~~ → measured rows-column height vs counted
  rail items; five accounts + hidden actions = one column. Verified.
- ~~Pop-out persistence~~ → popout_shown/x/y; restored at launch
  without stealing focus (position verified to the point); Cmd+W
  clears. ~~Off-screen overflow~~ → clampOnScreen on every re-fit +
  anchored bottom clamp.
- ~~Switch push lists the fleet~~ → ENGINE side (claude-swap commit
  572e073): switch_text(fleet=…) + switcher.fleet_status_rows —
  '→ 2 bravo: 5h 45% · 7d 12%' lines under the head. Tests green
  (pre-existing env-dependent failures in move/swap/store-guard
  suites are unrelated).


## Shipped 2026-08-30 (night wave — 6 asks + 3 mid-turn)
- ~~Theme preview "Fable"~~ → previews alias via theme.modelName.
- ~~Themed active-account icon~~ → RowTheme.activeIcon replaces the
  slot text (👑🌟🌿🐍🧠⌨️🧑‍🚀🏇⚡🕯); active outranks next.
- ~~Pop-out lost on restart~~ → quit's window teardown wiped
  popout_shown; AppDelegate.terminating guards pinnedClosed.
  Verified: seed → quit → flag survives → restore at position.
- ~~README à la CodexBar~~ → hero + badges + demo gif + Why/Install/
  Privacy/Credits (CodexBar credited as inspiration); MIT LICENSE.
- ~~Homebrew release~~ → repo public, v0.1.0 via release.yml
  (macos-26), rolling nightly prerelease, deathemperor/homebrew-tap
  with limitless + limitless@nightly casks; About updates via brew.
  E2E: brew install --cask deathemperor/tap/limitless → 0.1.0 in
  /Applications.
- ~~Animation GIF~~ → docs/demo.gif (launch intro + two rotate
  celebrations) recorded off a fabricated LIMITLESS_CSWAP shim
  fleet — no real account data in the published gif.
- ~~Linux/AUR ask~~ → app is AppKit (no Linux build); shipped the
  engine instead: claude-swap formula in the tap (Linux-capable,
  resources pinned, E2E-installed) + packaging/aur/PKGBUILD
  (publishing needs the user's AUR account).
- ~~Omarchy~~ → app not compatible (macOS-only) — README says so
  honestly; engine CLI on Arch/Omarchy highlighted instead.
- Open: Developer ID/notarization for quarantine-free installs (the
  release workflow bumps the tap cask itself via a deploy key).

## Performance (#18, 2026-09-03)
- ~~RPG effects idle the pop-out at 43% CPU~~ → every effect is a
  CAAnimation on a `LayerEffect` host (render-server driven): 0.4%.
  Theme off was 15% from the "resetting…" pulse — now a CA mask, 0.3%.
- ~~Burn overlays (ember/flame/limit) tick a Canvas at 20 fps while a bar
  burns: ~11% with several bars ablaze~~ → ported to CA (sparks are a
  CAEmitterLayer, tongues are skewed CAShapeLayers, the limit marquee a
  stepped gradient sliding in 2pt keyframes): ember/flame/limit all 0.3-0.5%.
- ~~`Infinitus-feed` at 25-34% CPU~~ — was the bundled app's own BurnOverlay
  tick, seen from the supervisor; gone with the port (other session, 2026-09-03).
- ~~Heap grows ~2 MB/min for as long as a bar shows the under-10-minute
  countdown~~ → the per-second `.contentTransition(.numericText)` on the
  m:ss label (and the wall's big countdown) grew the CG glyph cache
  without bound on macOS 26; dropped (0.08 MB/min after). `perf` now
  reports `heapBytes`.
- CI: `e2e` job (tools/e2e.sh) gates idle CPU ≤ 8% / RSS ≤ 220 MB / heap
  growth ≤ 768 KB/min with the demo fleet, rpg + ember. 2026-09-03: also
  switch/hold/unhold/rename round-trips, wall over pop-out and back, the
  all-dead scenario; the perf sample comes AFTER that churn — which is
  how it caught the wall leaving its 15 fps sparks ticking after close
  (~8% idle per visit; fixed: content detached, window reused).
- RSS itself (~140-160 MB) is mostly file-backed and system caches:
  footprint 81 MB = 59 MB malloc (SwiftUI attribute graph + view tree for
  a 12-row grid, 13 MB ColorSync transform cache, fonts) + CoreAnimation;
  the 192/160 MB single "allocations" are mmapped font/CoreUI assets.
  Nothing app-owned left that a change would move much.


## Prediction model follow-ups (2026-09-03)
- ~~Anchor projections to the newest sample's `t`, not `now`~~ → done
  2026-09-03: `UsageForecast.build` / `WindowPlanner.plan` take
  `measuredAt` (the newest sample's `t`, from `usageFetchedAt`), clamp
  it to `now`, and never project into the past. The republish guard in
  `updateBattlePlan` now only fires on a new sample or rate.
- First Run-rate scan reads each transcript whole (`readToEnd`) — a
  one-time RSS bump right after opening Utilization, not a leak.

## Engines backlog
- OmniRoute (https://github.com/diegosouzapw/OmniRoute) as a fourth
  engine (user 2026-09-03) — same shape as 9Router: probe its API for
  connections + per-connection quotas, map to EngineFleet, switch/hold
  via its own knobs. Research done 2026-09-03 (docs/research/
  omniroute-backend.md): a 9Router fork on the same port with the same
  `/api/providers` + `/api/usage/{id}` surface (roster paginated, 30-day
  cookie) — build it as NineRouterEngine with a second identity once a
  live instance confirms the Claude quota-key names.
