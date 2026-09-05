# Changelog

Product notes: concise, what you get and why it matters — no commit
links, no internals or workflow detail; one feature note is one line,
a single short sentence (user 2026-09-04). The release workflow
publishes the matching section as the GitHub release body.

## 0.4.4 (unreleased)

### Stats
- The activity tables read the ask off your own message — "debug the crash" counts as debugging even when the tools only edited — and the plugin's UserPromptSubmit hook refreshes a session the moment a prompt goes in.

### Phone
- The Game HUD bars' cool glow (usage behind pace) is a real glow now, scaled to the bar, instead of a tinted rim.
- The chat composer's placeholder speaks the theme's language too ("Send word…" in the Wild West, "Codec open…" while dictating in Metal Gear).
- Allow… on a permission card offers "Allow for this session": the Mac remembers the tool (Bash by command verb) and the plugin's PreToolUse hook skips that prompt for the rest of the session.

### Mac
- Settings › Machine watches what many sessions do to this Mac — load, swap, stuck hooks, runaway processes, residue — with confirmed kill, reclaim and hook-disable actions and notifications for new hook registrations and idle sessions.
- Sessions whose sub-agents hit a limit get a nudge that the swapped-in account has headroom, so they stop waiting for the reset.
- When a revival countdown ends the Mac asks the engine again right away (three tries a minute apart) instead of waiting for the next poll.
- "<account> is back" notifications, with "reset early" when Anthropic reset before the advertised time and "all accounts are back" when the whole fleet returns (Settings › Notifications).
- `/infinitus:handoff <session>` passes the current task and its context to another live session through the plugin.
- Live Activity pushes drop a phone token from before the bundle id move instead of failing on it every minute.
- "Needs AWS login" banners no longer repeat after a relaunch, and every banner's headline is now its subtitle.
- The Game HUD chat header's bars play the Fleet card's effects: pace fire, the cool halo, HP drops, Lucky 7s, the switch, death and revival flashes.
- The phone raises its own alarms, no push service needed: an exhausted account's limit lifting in 10 minutes, and the account the fleet just swapped to; off in Settings › Notifications.
- Settings shows the Mac's and the phone's versions, can trigger the Mac's update, and says when a newer phone build is out.

## 0.4.3

### Stats
- Stats reads Codex CLI transcripts too, with two more effort tables, per engine and per effort setting — one full rescan on first refresh.
- Where the effort went: minutes, tokens and spend per activity (review, tests, plan, debugging, browser, simulator, explanations, coding) and per model, on the Mac and the phone — heuristic labels, one full rescan on first refresh.
- Tokens/min records: every day's peak minute, the all-time best and the days it fell, a 30-day sparkline and a week-over-week trend, on the Mac and the phone — one full rescan on first refresh.

### Fixes
- A resume nudge after an account switch waits until the new account has held for 30 s and been polled alive since, and its retries stop when the engine switches again, so a flapping engine no longer burns three nudges in a minute.
- The idle-session note is sent once per session, app relaunches included.
- `infinitusctl status` and the phone show the Mac build's real git sha instead of "dev".
- Machine › Reclaim also clears abandoned pip and Python tempfile directories older than an hour, and finds open files without walking the temp directory (which is what hangs on a loaded Mac).
- Settings › Machine warns once per hook owner, names the owner of a shell-conditional hook, and can kill a hook's live instances (`infinitusctl machine-hook kill <owner> --yes`).
- Stats scan parses transcripts 4.6× faster (byte-level line scanning, no regex on tool results) and decodes the cache once per backfill instead of every pass.
- Tokens/min records: the day's minute buckets survive the stats cache, so the peak is the day's real busiest minute, not the last scan's.
- Stats count workflow sub-agent transcripts (`subagents/workflows/…`), which were invisible to tokens, cost and peaks.
- AWS logins survive a Mac relaunch, and a need that failed just before a launch still reaches the phone.
- A session stuck behind the credential broker's refresh lock (another process sitting in `aws login`) now shows the AWS login card too.
- A session whose check kept only the broker's "Fix: aws login" line (a `| tail -1`) shows the AWS login card too.
- Haiku session names now cover the sessions Claude Code named itself (`limitless-bf`, `banyan-51`…).
- Phone dictation never sits on "Translating…": a missing language pack asks to download, and after ten seconds the take goes out as spoken.
- A chat opens in well under a second on sessions with hundreds of sub-agents; the Mac read every sub-agent's log per request and the phone gave up after three ("the Mac didn't answer").
- The phone's composer no longer floats mid-screen after the keyboard is dragged away.
- Mac notifications are titled Infinitus, not claude-swap; engine update notices name the engine in the body.
- A chat swipes back from anywhere on the screen, not only from the left edge.
- The terminal's own "[Image: original …]" note after a screenshot is read no longer shows as a message you sent.

### Crash reports
- The phone app and the Mac app report their own crashes into Settings › Sync, nothing leaves your machine, and any report can go into a session's chat for triage.
- The Mac app leaves a lifecycle trail in the unified log — launch, who asked it to quit, signals, uncaught exceptions — so a silent exit has a trace.

### Accounts
- Randomize names: every account gets a fresh name from the current theme's pool (Settings › Accounts, or `infinitusctl randomize-names`).

### Mac
- The plugin's MCP server: `fleet_status`, `list_sessions` and `session_message` tools in every session, plus `/infinitus:status`; `infinitusctl sessions` and `infinitusctl send <pid|name>` for scripts.
- A Claude Code plugin (`infinitusctl plugin install`): its hooks push a permission or question to the phone the moment it appears and refresh the fleet when a turn ends.
- Settings › Sync names this Mac for the phone, widgets and crash reports; the default drops the " (7)" macOS appends after name collisions.
- Compact account rows no longer run under the cash column.
- Releases are signed with a Developer ID and notarized: no more right-click → Open on first launch.
- Bundle ids move to `run.infinitus` and `run.infinitus.mobile`: settings carry over; notifications, login item, proxy key and phone pairing are asked once more.
- The menu bar item follows the theme — the loop in its color, the theme's icon beside it — and glows on a switch, a death or a revival, with an ember breath while the active account burns (Settings › Display).
- Capture Screen for a Session… in the menu-bar menu: pick a region or window, choose a session, add a note, and it lands in that session's chat like a phone message.

### Phone
- Start a session from the phone: + on the Quests tab picks a repository, the engine and a first prompt, and the Mac opens it in a cmux workspace or Terminal; Siri and Shortcuts have "Start a session in Infinitus".
- The working Live Activity follows an account switch when the app opens, and a card nothing has reached says "out of date".
- A lighter chat header: compact by default, or a stat strip with mini gauges (Settings › Appearance › Chat header).
- A capture of the app — the capture button in a chat, a shake anywhere, or a screenshot the phone just took — lands in the composer as an attachment so you can say what it's about.
- The Game HUD header draws every window as a bar, the models' too, and one + button left of the text holds every attachment: capture this screen, photo library, camera, files, paste.
- The phone app is called Infinitus on the home screen and in search.
- A session that comes to need an AWS sign-in raises a notification on the phone, tap to sign in, and the Quests badge counts it.
- The phone build carries the push entitlement, so Live Activities and alerts move with the app closed once the Mac holds an APNs key (Settings › Sync).
- Home-screen and lock-screen widgets in the fleet's theme: the active account's windows as your theme names and colors them, what's waiting, and the revival countdown when every account is limited.
- The phone's app icon follows the theme: a crown for RPG, a snake for Metal Gear, a planet for Cosmos… the stock loop for Off and custom themes.
- Share → Infinitus from any app sends images, files, a link or text into a session with a note, picked from the Mac's live list, without opening the app; your sessions sit in the share sheet's suggestions row.
- A message from another session shows as "Message from @name" with a preview, the full text a tap away.
- Your own turns render Markdown too.
- Live Activities are back on the lock screen and Dynamic Island.
- The tab bar shrinks to its icon as a list scrolls, Safari-style (iOS 26).
- Gauges hold still on open and on tab switches; Settings › Replay intro plays the entrance on demand.
- A third chat header, Game HUD: a ringed portrait with the level on its rim, a name plate, HP/MP-style bars and a buff square per model, all in the theme's colors.
- Loading, empty and "looking for the Mac" placeholders speak the theme, with the theme's icon in motion.
- Settings › Chat header previews every style live, in the current theme.
- The Game HUD header is a glossy unit frame now: the portrait rides the panel, the bars carry a pace tick.
- Live Activity: the next account and the "then …" line are readable on the Lock Screen's dark card.
- AWS login: the card shows the profile's account id and IAM user name, tap to copy.
- AWS login: the in-app sign-in page gets the account id and user name filled in.

### Team (preview)
- `infinitusctl team` creates a team on any git remote and exchanges end-to-end encrypted files between members (create, code, request, approve, publish, read).
- Nearby: a discoverable Mac or Linux box shows up to teammates on the same network, and `infinitusctl team request --nearby <kid>` sends a join request straight to a leader — no code to paste.
- Settings › Lock puts the pop-out and Settings behind Touch ID (password fallback), re-locking at once, after 5 min, after 1 h or on sleep; teams need it on.
- Members publish their stats, live state, session index, redacted transcripts and crash summaries to the audiences they pick, with per-project exclusions (`infinitusctl team share|exclude|publish|members|member`).

## 0.4.2

### All accounts limited
- **Floating revival countdown.** When every account is limited, a small
  always-on-top panel shows who recovers first, a live countdown and
  the sessions waiting to resume. Settings → Display to turn it off.

### Forecast
- "Binds at", "all accounts out" and the battle plan no longer drift
  later between polls.

### Phone
- **Continue a stopped session** from the phone — one button, whatever
  stopped it (a limit, a crash, a closed terminal). It shows only when
  the turn ended without a final answer; after one, the composer is
  the way on.
- **The whole conversation stays readable.** A pasted screenshot no
  longer pushes everything before it out of a session's chat.
- **Sessions is home.** The app opens on what's waiting for you, with a
  badge for how many; the Fleet tab opens with the active account, who's
  next and how many sessions are working.
- **Safer approvals.** A permission request is a card pinned above the
  composer with the full command; Allow asks once more, Deny is plain,
  and the phone taps back when it lands. Questions pick, then send.
- **Pairing starts on screen**: the empty Fleet tab scans the Mac's QR
  code, and says so when it's paired.
- Cleaner feed: tighter tool rows with errors in red, a loading and an
  empty state, "offline" up top where you can see it, and an ⓘ button
  to the session's details. Plain words for status; no process ids.
- Honors Reduce Motion; bigger tap targets and labels for VoiceOver.
- **Dictate a message.** A mic in the composer; on-device, no server.
- **Dictate in any language.** Long-press the mic (or Settings →
  Dictation) to pick the language — Vietnamese included. A non-English
  take is translated on the phone (iOS 18, nothing leaves it) into an
  editable English draft, with a chip to peek at what you said; or send
  it as spoken with a note asking for an English reply, so the session
  stays English. The recognizer is handed the session's names and
  tools so "commit", "PR" and file names survive a Vietnamese take.
- **Paste an image** from the clipboard, straight into the chat — the
  keyboard's "Paste from Screenshots" chip and the edit menu both work.
- **Notifications straight to the phone** (issue #3) — every alert the
  Mac posts, no Slack or Telegram in between. Ships once the phone
  build can register for them.
- Idle sessions show their names, not just the busy ones.
- **Pictures in the feed.** An image pasted in the terminal or sent
  from the phone shows as a thumbnail in the message; tap for full
  size. Images inside tool results stay text.
- Tool runs stay grouped through errors, with an error count on the chip.
- **The theme names the phone.** Tab bar icons and names, the screen
  titles and every session's status word come from the theme — RPG
  sessions are Questing, Resting at camp or Awaiting orders under
  Quests / Party / Inventory. Custom themes set `sessionWords`,
  `tabLabels` and `tabIcons`; Off keeps the plain words.
- **Unnamed sessions get a name.** Claude Haiku titles any session you
  haven't named from what it's working on, and re-titles it as the work
  moves on — in the sessions list on the Mac and the phone. One short
  Haiku turn on the active account; Settings → Display to turn it off.
- **Snappier chat.** A sent message shows in the feed at once, marked
  until the session reads it; a reply that streams in lands as it is
  written instead of up to two seconds late; coming back to the app
  refreshes the feed immediately; and on the Mac a message being typed
  into a terminal no longer holds up every other phone request.
- **A header of its own on a session's chat.** Back, the session's name
  and state (tap for its details), and the account's own Fleet row —
  glyphs, gauges, the per-model window, the plan badge — on the theme's
  tint; the Sessions list header shows the theme's glyph. The Off theme
  keeps the plain lines.

### Stats
- **Your engineering week, in numbers.** Settings → Stats: commits,
  lines, PRs, messages (keyboard, phone, agents), sessions, tool calls,
  time spent waiting on you, switches and limits, cost — today, this
  week, month or year, each with its trend. On the phone and the wall
  too; `infinitusctl stats` for scripts.

### Agents
- `infinitusctl events` — the app's switch/death/revival log, so a
  "why did it switch?" question has a record to read.
- `infinitusctl stats` — the same numbers as JSON for a period, for
  scripts and agents.

### Linux tray
- Sessions that need an AWS login say so; the footer names the
  connected phone.

### Site
- infinitus.run reads well on phones: no sideways scroll, better
  contrast, feature cards grouped by what they do.

### Settings
- **The Codex slots tab is gone.** The manual auth.json slot switcher
  never grew usage tracking or auto-switch; Codex accounts still show
  as fleets through CLIProxyAPI and 9Router.

### AWS sign-in
- **Your phone hears when a session needs an AWS login** — one push per
  session and profile (Notifications → "A session needs an AWS login"),
  so the need no longer waits for you to open the app.
- **One login, every session.** When two sessions are stuck on the same
  sign-in, or one profile's login signs another in underneath (a broker
  profile over its anchor), every stuck session is told to continue and
  its "needs login" clears — the app checks the other profiles with the
  CLI instead of guessing from the config.

### Fixes
- A phone message no longer reads to the session like a note from
  another Claude session: it answers you in its own transcript instead
  of "replying" to a session named Infinitus.
- No more phantom permission cards: a tool running in a session that
  needs no approval was shown as "wants to run this" until the turn
  ended.
- Sessions moved into a git worktree show their feed again (the
  transcript stays under the repo's own folder).
- Keys and typed messages reach sessions inside cmux, where the
  terminal reports no process ids — matched by the session's name.
- The pop-out no longer freezes the app when it and its content
  disagree on size (a fractional height, a screen clamp, or content
  that measures differently in two window sizes kept the resize loop
  spinning on the main thread).
- Bright apps behind the popup, and window-only captures (CleanShot),
  no longer wash the glass out: it caps at a legible level at every
  transparency setting, and dark backdrops pass through untouched.
- The popup no longer burns CPU (and stops answering `infinitusctl`)
  while an account sits in the 90s.
- An engine that refuses to start no longer shows as a crash.
- "All accounts down" no longer appears while the active account is
  fine and only the spares are limited — the countdown panel, the popup
  banner, the wall, the phone and the Linux panel all wait for the
  account you're actually on to hit its limit.

## 0.4.1

### Menu bar
- **Reset time in the bar.** The title ends with when the active
  account's fuller window resets — `loc · 75·40% · ↺2h14m`. Countdown,
  clock time or off, in Settings → Display. Linux tray too.
- **Stars you can see.** The pick-first star shows in every account
  list, and starring an account switches to it right away.
- **Install engine** sets up `uv` itself instead of stopping on "uv not
  found" — thanks @sonyy172 (#20).

### One account
- **The solo card.** One account gets one card: every window on its own
  line, big gauge, full reset time — and a one-line case for a second
  account with "Add account…" right there.

### Phone
- **AWS sign-in that survives a passkey.** Sign in from the phone: the
  AWS page opens in Safari, the code pastes in with one tap. The session
  that needs it is a sticky bar above its chat and at the top of the
  sessions list.
- The hide-keyboard button is gone — drag or tap to dismiss.

### AWS sign-in
- **Sessions that need `aws login` say so** — "🔐 <session> needs AWS
  login (<profile>)" in the popup and on the phone — and can be signed
  in from either. Once done, the session is told to retry and continue.
  The code never touches disk or logs.

### Forecast
- **"At this pace"** under the account rows: when each window of the
  active account runs out at the measured burn, and when the fleet's
  weekly headroom is gone — clock times, paces inline.
- **Detail dashboard** in Utilization: every account at its own pace,
  the fleet's all-out time, the battle plan steps, and the run rate in
  tokens, dollars and turns per minute / hour / day / week.
- The plan line reads as a sentence: "when main hits its MP limit
  ~4:00 PM switch to loc → loc's MP resets 6:50 PM".

### Battle plan
- **Ignite from any engine that can** (`infinitusctl ignite`), and the
  planner never lands on a window with under 90 minutes left.

### 9Router engine
- **A third engine.** [9Router](https://github.com/decolua/9router)
  connections show up as fleets — Claude, Kiro, Codex, Gemini — with
  their gauges, switch, hold and remove. Kiro's monthly credits ride the
  credit gauge. Settings → 9Router.

### Playground
- Every fleet scenario is a button: Normal / Empty / All dead / One
  account / Two accounts / No engine / Two engines.

### Docs
- `docs/guides/agent-setup.md`: set Infinitus up from scratch with a
  coding agent.

### Bundle id
- Now `com.huuloc.infinitus`. Settings carry over; macOS asks once more
  for notifications, the login item and each keychain item.

## 0.4.0

The phone release: your fleet and every Claude Code session reachable
from anywhere, a second engine, and the app learns to plan its 5-hour
windows.

### Remote access
- **Four ways in, one QR.** Wi-Fi, Tailscale, your own Cloudflare
  tunnel, or a free quick tunnel — one pairing QR carries every route,
  and the phone uses whichever answers. A quick tunnel's new address
  finds the phone by itself after a restart.
- **Connected devices** in Settings → Sync, with a "Set up your phone"
  walkthrough.

### Session chat
- **Every session as a chat on the phone.** Replies, tool calls
  collapsed into one chip, sub-agent cards — streamed as they're written.
- **Reply from the phone.** Answer questions and permission prompts, type
  a message, attach photos and files. Tap the header for the account
  serving the session.
- Sessions listed by name, with branch, model and output size; a
  "waiting on you" push when one stops for an answer.

### Engines and accounts
- **CLIProxyAPI** as a second engine: OAuth add, hold/remove, routing
  strategy, key in the keychain.
- **Pick-first stars.** Star an account and the engine lands on it
  first when it switches.
- **5-hour window telemetry** and a **battle plan**: Infinitus projects
  when the active account binds and offers to start a spare account's
  clock early so its reset lands mid-sprint — two taps, confirm-gated.
- Weekly reset shown on full rows; remembered resets say "last seen".

### Agents
- **`infinitusctl`**: status, fleets, switch / rotate / hold / rename /
  prefer / reorder / remove, add, proxy settings, perf. A first-run
  recipe a coding agent can finish for you.
- Resume nudges reach a session over its own socket first.

### Performance
- Pop-out idle CPU 43% → 0.4%; every effect runs on Core Animation.

### Linux
- `infinitus-tray serve/pair`: the phone companion on Linux, same
  routes, same chat.

### Site
- infinitus.run shows the popup in every theme.

## 0.3.0

The Linux release: Omarchy gets the full popup, and the fleet tells you
more when things are tight.

### Linux
- **The fleet panel.** Click the bar widget for the macOS popup, ported
  to Quickshell: themed gauges, dead/held states, click to switch,
  keyboard driving. Release artifacts for x86_64 and aarch64, plus an
  Omarchy bundle.

### Both platforms
- **All accounts limited, made useful.** The popup names the first
  account to recover with a live countdown, and counts the sessions
  waiting to resume.
- **Behind-pace glow** on bars running slower than the clock — the calm
  twin of the ahead-of-pace burn.
- **Rotation holds.** Keep any account out of auto-rotation and bring
  it back — a button on the row, or the CLI.
- **Most headroom first.** Rows sort by headroom with the active and
  next accounts on top; slot numbers never move.

### macOS
- Settings stay readable over a white app behind them.
- The playground has a demo video and a window recorder.
