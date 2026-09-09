# Changelog

Product notes: concise, what you get and why it matters — no commit
links, no internals or workflow detail; one feature note is one line,
a single short sentence (user 2026-09-04). The release workflow
publishes the matching section as the GitHub release body.

## Unreleased

### Team (preview)
- Teammates' data and transcript branches are fetched at their tip only, not with every chunk ever published behind them, and a removed member's branch disappears from the mirror; the roster keeps its history for the trust walk (#414).
- A member's publish deletes the pre-split transcript chunks still sitting in its `m/<kid>` branch, so a new member's first fetch no longer downloads 1.3 GB of stale chunks (#414).
- Leaders can compact their own branch on the store (Settings › Team, `infinitusctl team-compact`): one commit without the pre-split transcript history, the explicit force-push the spec reserves, so a new member's first fetch is megabytes instead of gigabytes (#339).
- Nearby takes an address too: when a network keeps Macs from seeing each other's Bonjour, type the leader's host or host:port under Nearby (or `infinitusctl team request --address`) and the request goes over the LAN as if the Mac had been found (#355).

### Linux tray
- The Linux companion answers the descriptor and the Files wire, so a paired phone can browse a Linux session's project files.

### Mac
- Workspace: the right panel's Diff tab shows the session's changes from its checkpoints.
- Workspace: the right panel's Files tab browses the thread's project.
- swapd engine (preview): the app can run the new multi-provider engine beside cswap; ignite refreshes the account at once.
- The phone can browse and read a session's project files over the mirror wire (files capability).
- The project list and the composer strip read the branch from the repo's HEAD file instead of spawning git, so a checkout shows on the next pump (#346).
- A debug or fixture instance keeps its mirror snapshot in its own state dir instead of overwriting the app's (INFINITUS_MIRROR_SNAPSHOT).
- The past-session scan remembers each transcript's head instead of re-reading 200 of them every minute (#346).
- Workspace: a newly opened window no longer races the app's first refresh into an empty sidebar (#468).
- Clicking Infinitus in the Dock while Settings is open brings Settings back instead of the pop-out.
- Workspace: a working thread's status reads in sky, the colour the reference uses.
- Workspace: drop files onto a sidebar thread to open it with them attached.
- Workspace: a "Scroll to end" button above the composer while the thread is scrolled away from its newest message.
- Workspace: the new-thread project picker lists each project with its own icon.
- Workspace: an open drawer tucks under the composer the way the reference's does.
- Workspace: links in replies carry the reference's favicon slot.
- Workspace: reply links take the reference's blue with no underline.
- Workspace: inline code in replies wears the reference's chip.
- Workspace: a thread whose session ends stays open with "This session has ended." instead of vanishing.
- Workspace: sidebar rows show their branch and provider, the scope row and top bar carry the reference's controls, and the composer's placeholder follows the thread.
- Workspace: the thread's timestamp row, code-fence header, sidebar search and the git line under the composer now match the reference.
- Settings › Devices lists every phone that has paired — name, route, last seen, what it holds on this Mac — across relaunches, any number of phones, each with Forget.
- gcloud sign-in like AWS: a session whose `gcloud` credentials lapsed (user account or application default) shows the need, the phone or the Mac runs `gcloud auth login` and the session is told to continue (#367).
- The workspace window no longer spawns a git call per project on every fleet tick: branch names are kept a minute per folder and the session list is read once per refresh (#384).
- Settle, snooze and pin land on the session they name, not on whatever process reused its pid after a resume (#391).
- A transcript tail read costs a quarter of what it did: timestamps parse without a formatter and tool output splits on bytes, so a busy Mac spends less on every phone poll and list pass (#380).
- The team loop stops burning seconds every five minutes: a teammate's stats, live state, sessions and fleet docs are decrypted once per blob version instead of through a git subprocess each pass, and the header cache is rewritten hourly rather than on every pass (#346).
- Every team git call returns the moment git exits instead of up to 100 ms later, and a store pass lists each branch once: fetch, publish and the reader's tick spend less time waiting (#370).
- A session nobody has open builds its row's facts from the last 256 KB of its transcript instead of up to 4 MB, so a busy fleet no longer re-parses megabytes twice a minute; the thread you're looking at keeps the full window (#346).
- `infinitusctl team status|fetch|code|approve|decline|create|publish` on a Mac with the app running answer as the app (its identity, its store), and the other team subcommands refuse to mint a second identity beside the app's; `team status` fetches first and says when it is showing a cached roster (#354).
- The Mac idles near 0% again with the pop-out closed: the project list behind the phone's start sheet reuses its walk of past transcripts for a minute instead of re-reading ten thousand files on every refresh (#346).
- "Allow for this session" on a session the app runs itself reaches it as the wire's allow-for-session, not a Yes keypress plus the hook rule; terminal sessions still get the keypress (#430).
- A relaunch inside the hour reuses the machine pane's last tree sizes instead of walking 240k files again: about 3 CPU-seconds less per launch (#346).
- Launch and the hourly machine sample no longer burn ~40 CPU-seconds sizing the transcript, plugin-cache and claude-mem trees: the walk reads one size per file instead of a full attribute dictionary, ~12x faster on 240k files (#346).
- `infinitusctl` builds on Windows again: the POSIX signal calls behind owned sessions and the team's git feed are Darwin/Linux-only, and Windows probes and ends an orphaned child through its process handle (#406).
- `ictl` is the short name for `infinitusctl`: the same binary, shipped beside it in the bundle, and its usage text follows whichever name you typed.
- Workspace groundwork: timeline messages carry updatedAt, tool rows carry their command, slash-command discovery.
- The phone's working Live Activity gets its tok/min pushed on its own beat, every 5 s by default and adjustable in Settings › Sync › Phone lock screen.
- Open workspace: a new window over your sessions, from the popup, ⌘⇧T, or infinitusctl show workspace.
- Workspace: sidebar with project groups, pinned/snoozed/settled shelves, and the thread header bar.
- Workspace: the thread view — timeline, work groups, approvals and questions answered in place, richer markdown.
- Workspace: composer with slash commands, @-file mentions, attachments, new-thread drafts and the ⌘K thread switcher.
- Settings › Team's Syncing line stays one line: git's progress can no longer spill over the pane.
- Team stats days are keyed by the Gregorian date on every Mac, so a member on the Buddhist calendar counts toward today instead of the year 2569 (#409).
- Closing a chat window or switching workspace threads stops its transcript poll within a second instead of up to 25 s later (#399).
- Workspace: a denial with a reason now shows in the activity log like every other answer.
- A streaming session's transcript is read incrementally: each watcher tick parses the lines appended since the last, not the whole 512 KB tail (#346).
- The machine sample groups the process table once for all hook registrations instead of once per hook (#346).
- The resume tick probes the last 64 KB of a transcript before reading 512 KB, and a sub-agent's meta file is decoded once, not on every feed read (#346).
- The machine sample matches hook scripts to processes with a byte search instead of Foundation's `contains` (a second per sample on 70 hooks) (#346).
- The lapsed-sign-in scan over tool results folds bytes instead of Unicode-lowercasing and Foundation-searching each one — 49× faster per result (#346).
- The stats refresh keeps its decoded transcript cache for the app's lifetime and rewrites a caught-up corpus at most every 10 minutes — no more re-decoding 24 MB of JSON every 5 minutes (#346).
- A session's sub-agent folder is re-listed only when it changes or every 30 s, not on every refresh (#346).

### Phone
- A thread's git sheet opens Review changes: the session's checkpoint timeline and turn diffs, from the sheet instead of the old session screen.
- Usage gains its cost tab: the engine's raw token cost for the period, a daily chart, per-account and per-model shares and the token totals, across every paired Mac.
- Home rows follow upstream: Working reads in the Mac's sky tint, a Mac with several accounts shows which one a session runs on beside the Claude mark, and settle, snooze and pin move the row as one transition.
- Settings gains Usage: each Mac's 5-hour, weekly and per-model limits pooled across its accounts, with quota left, pace, the next refill and a per-account detail.
- A thread no longer pulls you to the bottom while you read history: new rows follow only when you are at the end, and a scroll-to-end button appears beside the Working pill otherwise.
- A thread whose session exits keeps its rows under a "This session has ended." banner instead of saying Reconnecting… forever (#400).
- A thread's question card honors a question that withdrew the custom answer, drops the typed text once an option is picked, and refuses a multiple-choice custom answer that would read as two options instead of sending one the Mac rejects.
- Live Activity cards are keyed to their Mac's pairing, not its name, so two Macs sharing a name or a renamed Mac keep their cards apart; the Mac echoes the key into the cards it starts by push (#144).
- A gcloud login from the phone can be one tap: "Sign in here instead" signs in on Google's page in the app and the Mac's gcloud picks the login up by itself, no code to paste (#403).
- A gcloud login need reads as one on the phone — the account instead of a profile, gcloud's own sign-in page in the copy — and the phone tells the Mac which CLI to run (#367).
- A video picked from Photos reaches the Mac as the .mov/.mp4 it is (up to 20 MB) with its path in the message, in both composers, instead of one still frame; the chip shows its first frame with a play badge (#381).
- A long thread scrolls and refreshes without stalling: the feed's rows are derived once per update instead of once per row on every redraw; the Mac's chat window gets the same (#380).
- The new thread folds a finished turn's work behind "Worked for …", groups tool calls with a summary that opens in place, and labels each call the way the reference does (#223).
- The new session screens are on by default — Home list, thread, task sheet and settings sheet; the Appearance toggle brings the previous list and feed back (#223).
- Home orders threads as the reference does — pinned in saved order, then newest first, snoozed and settled shelves — and each row's swipes come from its state (#223).
- The new thread renders markdown the way the reference does — DM Sans body, bold in the strong color, mono inline code, fenced code in a bordered block with its language and a copy button, task lists, tables, rules (#223).
- The new thread list and thread screen hold the same session leases the previous screens held, so the Mac keeps computing facts and full timelines for what the phone shows (#223).
- The new thread screen derives its rows once per update instead of on every redraw, so long threads stop stuttering (#380).
- Home pages the settled tail ten rows at a time behind a Show more footer, and a long press on a row offers Settle, Snooze presets, Pin, Un-settle or Wake as the reference does (#223).
- A custom answer typed under a session's question now reaches Claude Code; it stands in for the picked options, as the reference does.
- Typing / at the start of a line in the thread composer lists the session's slash commands and skills to pick from, as the reference does (#223).
- Team actions on the phone (join, invite, request, file) no longer need the app lock turned on.
- Typing /usage-limits in a thread's composer shows the session's account and its Session, Weekly and per-model limits above the composer, answered on the phone without a turn.
- Settings → Appearance gains Text size: a slider from 11 to 22 pt that scales every session-screen font, 16 pt being the reference.
- A thread's Files pill opens the session's workspace: a searchable folder tree, a file's source with line numbers or its markdown rendered, and Add to message drops @path into the composer (#223).
- The Files tree is built off the main thread and a search re-derives its rows once per keystroke instead of once per redraw.

## 0.4.4-alpha.2

### Mac
- Team Nearby no longer depends on the phone switch: a discoverable Mac or a team member keeps the LAN listener up by itself, and phone connections are refused while "Serve the fleet to my phone" is off (#356).
- A click into an account's name field focuses it at once; only the drag handle starts a reorder now, so the row no longer holds every click until the mouse comes up.
- Stats folds run off the main thread, so a refresh no longer freezes the window for a third of a second.
- Ignite says what it did: the plan line reports "<account>'s window started — resets 3:20 PM" (or the failure) for ten seconds, the armed "Sure?" state is a solid orange pill, and the account's usage refreshes right away (#338).
- The Activity log and `infinitusctl events` survive a relaunch: the last hundred events come back from the durable log at launch (#338).
- The wall honors the biometric lock: while the app is locked it shows the lock, not the sessions (#55).
- `infinitusctl` retries for a second while the app re-binds its control socket, and says which error it hit instead of a flat "not running" (#265).
- A freshly added account shows its email in Settings › Accounts before you name it.
- "Waiting for the token" shows what the sign-in CLI is saying, and a rejected code comes back to the field with the reason.
- The "Almost there" setup card no longer clips the popup's toolbar, names your account once, and explains the AI-agent brief under its button.
- A sign-in code Claude rejects (half-copied, or a failed exchange) comes straight back to the paste field with the reason, instead of waiting forever.
- The setup steps (install the engine, add the first account) show on a solid background instead of glass.
- The private sign-in window keeps your Google login across accounts, so adding or re-logging an account skips the email field.
- The Mac serves a browser page for machines without the app — sessions list, chat with a session, Start a session — at the "Copy Browser Link" address in Settings › Devices (#151).
- Click a session in the sessions card to chat with it in its own window: the live transcript, a composer, and its permission and question prompts answered from the Mac (#151).
- Settings › Machine shows on dev builds and stays hidden on releases.
- Fewer stray notifications: "all sessions finished" needs ten minutes of work first, its stretch and the last-alive warning survive a relaunch, and engine housekeeping events no longer post banners (#231).
- Team members say when they joined, on their row and in their detail; a removed member still readable says when they were removed; `team members` gains `joined` (#219).
- Settings polish: every engine error reads as a sentence, the search highlight fades in and out, Machine labels share one casing, and a `-mock_mode YES` dev instance shows mock accounts (#249).
- Team publishing reuses the Stats scan instead of scanning every transcript a second time, which had taken the app to 5.5 GB (#251).
- Settings › Accounts leads with Add Account, shows Sign In Again only on the account that needs it, and renames an account in its own field, Tab moving to the next.
- Randomize Names can be undone for 30 seconds.
- Regenerating the pairing token, stopping rotation, signing in again, forgetting a stored key or token, and removing a push channel, a profile or a crash report all ask first.
- Settings › Devices puts one QR code and one address up front, with the rest behind Other addresses.
- Every icon button in Settings says what it does and to which account, and an engine error now reads as a sentence with a next step.
- Settings' sidebar is a real list: arrow keys, type-select, a focus ring and VoiceOver names, grouped into General, Accounts, Dashboards and Engines.
- Settings search finds a setting by its own label, opens its pane and flashes the group it lives in; ⌘F jumps to the field.
- The Settings window is called Settings and says which pane you're in.
- Display is five named groups — Menu bar, Popup, Fleet wall, Sessions, Refresh and startup — each with a footer that says what the setting costs.
- The popup's headroom sorting moved to Settings › Display, where the rest of the popup's appearance lives.
- Theme cards show the whole theme instead of hiding half of it in a sideways scroller, and name two accounts the way that theme would.
- Utilization says what its gauge glyphs mean, and its run-rate methodology moved under "How this is measured".
- The Stats tiles fill their last row instead of stranding one tile beside three empty cells.
- About has its own Software Update group, and says "Scripted (Notification Center unavailable)" instead of naming the tool it fell back to.
- The tokens/minute chip speaks the theme — mana/min, baud, knots — with its own icon, on the Mac, the phone, the widgets and both theme previews (#218).
- Settings › Accounts backs up every cswap account to one file and restores from it, asking before it replaces anything (#229).
- All accounts limited: the one that revives first floats to the top with a themed pulse and its own hh:mm:ss countdown inside the revive lead, on the popup, pop-out and the phone's rows.
- Settings › Notifications sets the revive lead (default 10 min): how far ahead of an exhausted account's reset its row counts down live and the phone's reset alarm fires.
- Phone messages and resume nudges reach sessions in every permission mode again: Claude Code 2.1.263 holds a peer message that claims a different permission class than the receiver's, so the app now asserts the session's own (#213).
- "All accounts are exhausted" notifies once per outage and honors its toggle — the engine's ten-minute re-probes no longer repeat it.

### Team (preview)
- An invite code from either leader of a two-leader team joins, whichever leader last edited the roster — the join walks the roster's signed history back to the code's leader (#55).
- Transcripts publish to their own branch per member, fetched only by the teammates they are shared with: every device's routine sync and a new member's first load stay in the kilobytes (#321).
- Requesting to join fetches only the roster and the requests, not every member's transcript history — a join that pulled 1.3 GB now moves kilobytes (#321).
- A slow store never looks hung: Team shows git's own progress, a stalled fetch or push times out with a message, and Approve no longer waits behind a running publish.
- Team actions no longer wait for biometric unlock: create, join, approve, invite, grants and hostnames work with the lock off.
- Nearby no longer lists this Mac as a stranger, re-advertises your role right after you create or join a team, and says when the LAN mirror is off.
- Saving the Cloudflare token and giving a hostname sit behind biometric unlock, like grants (#220).
- Team publishing and fetching run git directly instead of through the macOS xcrun shim, about a quarter faster per call.
- A leader can give each member a stable hostname — a Cloudflare named tunnel under the team's zone, minted from Settings › Team or `infinitusctl team hostname give`, started by their Mac on its next fetch (#220).
- Team session control, driver side: drive a teammate's granted session from their detail on the Mac or with `infinitusctl team send|approve|mode|tail` — over LAN, a tunnel, or the store on their next fetch, each command answered with its lane and outcome (#220).
- Team session control on the Mac, grantor side: grant teammates view, send, approve, mode, resume or key on chosen sessions from Settings › Team or `infinitusctl team grant`; commands arrive at the mirror server, every one is audited, and the sessions popover says who is driving (#220).
- Team session control, core: grants, sealed command and ack envelopes, the verification pipeline and the control routes land in InfinitusCore with tests; nothing is mounted yet (#220).
- Team store hardening: `--team` ids are one path segment, git's stdin is fed without a pipe deadlock or SIGPIPE, the CLI reports encoding failures instead of exiting 0, garbled signer keys read as a bad signature (#55).
- A teammate's fleet — every account with tier, state and headroom — shows in their detail on the Mac and the phone, with a Fleet share row (default: leaders) and a headroom board for leaders (#221).
- A removed teammate's files stay readable up to the moment they were removed, and only later ones are ignored.
- Creating a team refuses a remote that already has content.
- A join the store refuses leaves no credential on this Mac.
- A publish that lost a push race is told apart from one that lost the network.
- The team store ignores an inherited git environment, and clears stale git locks a killed publish left behind.
- The team store reads only its own branches, and a rebuilt mirror re-lists instead of failing.
- `infinitusctl team` masks credentials in its errors, lists envelopes without decrypting them, and checks `--team`.
- A publish seals its batch to disk instead of holding it in memory, and Settings › Team says how much of a big catch-up is left.
- `infinitusctl team leave [--rotate-identity]` leaves a team and can mint a fresh identity on the way out.

### Sessions
- A nudge into a session that has run tools for hours is no longer held by Claude Code as "did not attest its permission mode": the mode comes from how the session was launched when its transcript tail has none.
- When a sign-in lands, a session still stuck in its own `aws login` is released so its command returns now, and the continue nudge tells it not to log in again (#275).
- The Mac chat window wears the phone's chat header — Compact, Stat strip or Game HUD, chosen in Settings › Display › Sessions (#151).
- A question with several parts from a session the app runs shows every part on the Mac window, the phone and the browser page, with one Send that answers them all (#151).
- A "needs AWS login" line met by a sign-in outside the app clears on its own: while it shows, the app asks the CLI every five minutes whether the profile works (#313).
- An `aws login` the app left running when it relaunched is killed at the next launch, and a login past its ten minutes is killed for good — a leftover held the credential broker's lock and failed every caller on that profile (#274).
- A session's AWS-login need reaches the popup and the phone within seconds of the failed command, not at the next fleet poll.
- A headless session shows a plan as the plan when Claude asks to leave plan mode, not as JSON (#151).
- A headless session that hits a usage limit says so in its feed, with the window and when it resets (#151).
- Photos and screenshots sent to a headless session reach Claude as images (#151).
- Interrupting a headless session never leaves it stuck on "busy": the turn closes after five seconds if Claude Code doesn't (#151).
- A headless session's permission prompt reaches the phone, the browser page and the Mac window the moment it parks, instead of up to two seconds later (#151).
- A headless session's row says busy, idle or waiting like any other, and wears a "headless" chip, instead of reading "unknown" (#151).
- "Ask every time" is a permission choice on both start forms and in profiles: every tool asks, even the ones Claude Code would allow on its own (#151).
- A headless session left behind by a crashed Mac app is stopped at the next launch instead of running on unattended (#151).
- Quitting the Mac app never hangs behind a stuck headless session: a child that stops reading its input is terminated instead of waited on (#151).
- Clicking a session row in the popup's footer sessions card opens its chat window again, with past sessions and the driving line, like the rail's card.
- A "needs AWS login" line met by a login that finished before the Mac app relaunched no longer comes back as unmet after the relaunch.
- The Mac popup's session rows take their dot and word from the same facts as the phone — a raised hand for an approval, a question mark for a prompt, snoozed and settled rows dimmed (#223).
- The Mac only computes per-session facts for sessions someone is watching: the phone leases the list, the open feed and the stats tab every 25 s, and the Mac's own popup, pop-out and chat windows count too (#223).
- The browser page draws the timeline rows too — tool groups and folded turns open in place (#223).
- The phone and the Mac chat window draw the new feed: tool runs as one line to open, finished turns folded behind "Worked for 13s", one live row while Claude works (#223).
- Session timelines reduce to feed rows: grouped tool runs, folded turns, one live row while Claude works (#223).
- Sessions ship a T3-shaped timeline — turns, messages and tool activities with stable ids — next to the flat feed, the base for the new phone and Mac feed (#223).
- Start a session headless — no terminal; Infinitus runs it and the Mac window, phone and browser page are its chat — from the popup, the phone, or as the default in Settings › Display (#151).
- The Mac can own a Claude Code session outright — no terminal — and answer its permission prompts and questions from the phone or the popup (#151).

### Phone
- Settings › Appearance › "New session screens" (off by default) opens a session as a chat thread over the live timeline route (#223).
- The new thread's composer attaches photos, camera shots, files and pasted images, and grows when focused (#223).
- The new thread answers a permission prompt or a question from a card over the composer — allow once, allow for the session, decline, or every question's answers in one Submit (#223).
- With the new screens on, + starts a session from a task sheet: pick a project, say what to build, choose the Mac, engine and permissions, send (#223).
- The new thread's gear opens thread settings — permission mode, settle, snooze, pin, stop the turn — and its git pill shows the branch with the actions to come (#223).
- With the new screens on, the sessions list is a flat thread list — project, title, branch · Mac, a status word or age — with snoozed and settled shelves and a search pill (#223).
- With the new screens on, Home's ⋯ opens Settings as a sheet — Macs, Appearance, Dictation, Screenshots, Notifications, Team, About as card rows (#223).
- The new thread's composer capsule, its distance from the last message and the reply inset match the reference to the pixel (#223).
- A send the phone retries lands once: the Mac answers the retry with the first reply, and a turn you stopped keeps its late input out (#223).
- Swipe a session to pin it, settle it or snooze it an hour (long-press for "until tomorrow"); pinned rows lead, snoozed and settled ones sit dimmed at the tail (#223).
- Session rows take their dot and word from the host's facts — a raised hand for an approval, a question mark for a prompt, the plan's "2 of 5" under the row — and the chat header gets a stop button while Claude works (#223).
- Closing the keyboard on a session chat drops the composer straight back to the bottom instead of leaving it floating mid-screen (#294).
- Tapping a "Fleet on a Mac" widget opens the sessions list at that Mac's section (#144).
- A "Fleet on a Mac" widget joins the Fleet widget: pick which paired Mac it shows in the widget's editor (#144).
- Every paired Mac gets its own Live Activities: a working card and a revival countdown per Mac, each kept moving by the Mac it belongs to (#144).
- The share sheet's suggestions row lists sessions from every paired Mac, each named with its Mac (#144).
- Share → Infinitus lists the live sessions of every paired Mac, each row naming its Mac, and posts to that Mac (#144).
- "Start a session on <Mac> in Infinitus" works from Siri and Shortcuts: the Mac is a picked parameter, and blank means the one the start sheet would pick (#144).
- Team members say when they joined, on their row and in their detail (#219).
- Face ID or the passcode can lock the whole app — on launch and on return from the background — not only the Team tab (#212).
- Settings' theme chooser shows every theme as a live row — its gauges, spend line, status word and tab bar — and the Theme row carries its colors.
- Pace fire, content entrance and title flourish are picked from tiles that show the effect instead of a menu of words.
- The pairing token is covered until you tap to reveal it.
- Forgetting a paired Mac asks first and says what it costs.
- Settings leads with the Mac connection: with nothing paired, scanning the Mac's QR code is the first thing on screen.
- Every group in Settings explains itself in a footer, and the Mac's addresses are labeled and editable.
- Updating the Mac from the phone shows its progress and says plainly why when it fails.
- The chat header follows Dynamic Type in all three styles; the Game HUD stops growing at the second accessibility size (#209).
- Other Macs: their sessions and past sessions never reach the primary by mistake, and "+" and Past sessions open once any paired Mac has answered (#215).
- The all-limited Live Activity counts down to the real revival instead of 31 years out, and every surface picks the reviver by parsed reset date, ignoring implausible ones (#226).
- Review changes says why there is nothing to review — checkpoints off on the Mac, a folder outside git, or no prompt checkpointed yet — instead of a caption nobody saw (#214).
- A message Claude Code held instead of delivering shows in the chat as a marker, with where to review it (#213).
- A phone showing the revival countdown skips the duplicate all-dead alert, and a working activity starts silently.

## 0.4.4-alpha.1

### Stats
- Stats show processed tokens, cached vs uncached input, cache writes and the estimated cache savings, per model and engine.
- The activity tables read the ask off your own message — "debug the crash" counts as debugging even when the tools only edited — and the plugin's UserPromptSubmit hook refreshes a session the moment a prompt goes in.

### Phone
- Parked sessions: with the Mac unreachable the phone keeps the last fleet and transcripts, queues one message per session and delivers it once the Mac is back (#168).
- The phone pairs with more than one Mac: other Macs' fleets and sessions show under their name, and any of them can be made primary from Settings › Devices.
- Other Macs' sessions open like the primary's: transcript, replies, approvals, checkpoints and queued messages go to the Mac the session lives on (#144).
- Other Macs park too: their fleets, sessions and transcripts stay on the phone while they're away, and the "+" sheet and Past sessions can start a session on any paired Mac (#144).
- The Sessions list wears the theme: session names in the theme's accent, state words in their state color.
- The share sheet's session picker lists waiting sessions first and names each one by session · repo.
- The Game HUD bars' cool glow (usage behind pace) is a real glow now, scaled to the bar, instead of a tinted rim.
- The chat composer's placeholder speaks the theme's language too ("Send word…" in the Wild West, "Codec open…" while dictating in Metal Gear).
- Allow… on a permission card offers "Allow for this session": the Mac remembers the tool (Bash by command verb) and the plugin's PreToolUse hook skips that prompt for the rest of the session.
- The Sessions tab's clock button lists every session the Mac has ever run, newest first and searchable; swipe Resume reopens one in its folder and lands you in its chat.
- Start a session picks its permissions: Supervised, Auto-accept edits, Auto or Full access, passed to Claude Code as its permission mode.
- Start a session offers the Mac's saved profiles as chips; one tap fills folder, engine, permissions, model, system prompt and first prompt.
- A session started from a profile or in a permission mode says so on its row ("Review · Full access"), on the phone and in the Mac popover.
- Swipe or long-press an account to star it or pause/resume its rotation from the phone; on the Mac, right-click the name in the popup for the same, and a paused row shows a play button to resume.

### Mac
- Infinitus is alpha software from this release on: the version reads 0.4.4-alpha.1 in About, `infinitusctl status` and the phone's Settings.
- An AWS sign-in that lapses inside a sub-agent shows up on the parent session — key badge, Sign in row, push — and the continue nudge after signing in goes to the parent.
- A dice button on each Settings › Accounts row re-rolls that one account's name to a fresh themed one nobody in the fleet wears; `infinitusctl randomize-names <fleet> <n>` does the same.
- Tab and Shift-Tab move between the account name fields in Settings › Accounts, and a click lands the caret at once.
- Sessions whose sub-agents hit a limit get a nudge that the swapped-in account has headroom, so they stop waiting for the reset.
- When a revival countdown ends the Mac asks the engine again right away (three tries a minute apart) instead of waiting for the next poll.
- "<account> is back" notifications, with "reset early" when Anthropic reset before the advertised time and "all accounts are back" when the whole fleet returns (Settings › Notifications).
- `/infinitus:handoff <session>` passes the current task and its context to another live session through the plugin.
- Live Activity pushes drop a phone token from before the bundle id move instead of failing on it every minute.
- "Needs AWS login" banners no longer repeat after a relaunch, and every banner's headline is now its subtitle.
- The Game HUD chat header's bars play the Fleet card's effects: pace fire, the cool halo, HP drops, Lucky 7s, the switch, death and revival flashes.
- The phone raises its own alarms, no push service needed: an exhausted account's limit lifting in 10 minutes, and the account the fleet just swapped to; off in Settings › Notifications.
- Settings shows the Mac's and the phone's versions, can trigger the Mac's update, and says when a newer phone build is out.
- Past sessions: the sessions popover lists the newest transcripts with a Resume button, and `infinitusctl past-sessions` / `resume-session <id>` (also MCP tools) do the same from a terminal or another session.
- Settings › Profiles saves named ways to start a session (folder, engine, permissions, model, appended system prompt, first prompt); `infinitusctl profiles` / `profile-set` / `profile-remove` manage the same list.
- Every prompt checkpoints the repository as a hidden git ref (with the plugin; Display › toggle): `infinitusctl checkpoints <session>` lists them, `checkpoint-diff` compares two or one against the working tree, `checkpoint-restore --yes` puts the files back and keeps a backup checkpoint; the sessions popover's Checkpoints section shows a session's timeline with Restore; the phone shows the timeline (session detail › Checkpoints) with each checkpoint's diff and Restore.
- A running session's permission mode can be widened from the phone (session detail › Permissions) or `infinitusctl session-mode <session> <mode>`; the plugin's PreToolUse hook answers from it and the row chip follows.
- Review a turn's changes from the phone: the chat's Review button (or a checkpoint's diff) lists the hunks, a tap comments one, Approve / Request changes sends the review as the session's next message.
- A profile can list tools its sessions run without asking (Settings › Profiles, `profile-set --allow "Edit, Bash git"`); the plugin's PreToolUse hook honours them from the session's first tool call.
- Siri's and Shortcuts' Start a session take a profile name: its folder, engine, permissions, model and prompts apply.
- Start a session from the Mac too: the sessions popover's Start a session takes a profile chip, folder, engine, permissions and a first prompt.
- Fork a session: Past sessions (Mac popover, phone) and `infinitusctl resume-session --fork` continue a transcript under a new session id, the original untouched — live sessions included.
- The Mac's Checkpoints section shows a checkpoint's diff against now (the stat inline, the patch a Copy away).

### Team (preview)
- Team publishing and fetching run git directly instead of through the macOS xcrun shim, about a quarter faster per call.
- Team: a leader invites a discoverable Mac over the local network, and the invitee accepts from Invitations.
- Team: the phone's Nearby — scan the network, ask a leader to join, invite a Mac, accept an invitation.
- `infinitusctl team nearby invite`, `team invites`, `team accept` and `team ignore` do the same from a terminal.
- Share a kind with Nobody and it never leaves this Mac (`infinitusctl team share transcripts off`).
- Pick which recent sessions' transcripts are shared.
- A publish shows its progress in Settings › Team, and quitting stops it after the current batch.
- The plaintext copies of what you published are capped at 1 GB, oldest transcripts first.
- A failed team create leaves no half-made team behind.
- A git push with chatty progress output no longer hangs the publish.
- Reading the team store remembers each file's header, so a refresh pass reads only new files and the app's memory stays flat.
- A publish sends transcripts only from sessions active in the last two days (stats keep 30) and pushes in 200 MB batches, saving its place after each, so a huge history can't stall or crash it.
- An invite link's request now proves the invite without carrying its secret, so a copied request can't ride someone else's invite; invited requests are approved automatically again.
- `infinitusctl team-create --remote <url>` takes the URL as written.
- `infinitusctl team create --as <name>` names you as the team's founder instead of "Leader".
- Settings › Team: create or join a team, approve requests, see every member's latest publish, today's effort and blockers, and open their Stats and transcripts — the Mac fetches and publishes every 5 minutes.
- Settings › Team: pick which audiences see each kind of your own data, and which project folders publish at all.
- Invite links (QR, copy, share sheet, `infinitus://join/…`) approve the one request they were minted for by themselves once Settings › Team's auto-approve switch is on (on by default); team codes need a tap.
- The Mac deletes its `now.json` from the team store on quit, so teammates stop seeing it "on".
- `infinitusctl team-status|team-create|team-code|team-fetch|team-publish|team-approve|team-decline` drive the app's team over the control socket, and the phone's snapshot carries the same view.
- Leaders see the team: per-member comparison for a period, leaderboards by spend, tokens, commits, PRs, lines, messages, tool calls, waiting time and sessions, who works in which repo, a blockers board, cost by member / model / repo, the hours heatmap and who's on now (`infinitusctl team members --period|insights`).
- Leaders publish the team picture to everyone (`team aggregates publish`), with per-member rows only when the roster's members-see-each-other policy is on, and `team policy` sets that and whether new requests are accepted.
- `infinitusctl team identity export|import` seals your identity with a passphrase (PBKDF2 600k + ChaChaPoly, the same file on every platform), `identity recovery --show` prints the 8-group recovery key, and either restores the same kid on a new machine.
- The site serves the passkey relying-party file for infinitus.run, and a release built with a provisioning profile carries the associated-domains entitlement the passkey identity needs.
- Leaders get Insights in the Team pane: a member comparison, leaderboards by metric, repos, a blockers board, cost by member/model/repo and an hours heatmap; the team picture is published hourly for members.
- Nearby in the Team pane: a Mac on the same network asks a discoverable leader to join, and leaders file network requests for approval.
- Policy in the Team pane: close requests, or let members see each other's detail.
- The recovery key (after Touch ID), a passphrase-sealed export and an import live in the Team pane; the export file is created owner-only from its first byte.
- Quitting waits, briefly, for the team to be told you're gone, on every quit path.
- The phone has a Team tab: roster, requests, invite links and team codes, a teammate's stats and sessions, their shared transcripts, and the leaders' team picture — approve, decline and join from the phone.
- The phone's Team tab locks behind Face ID / Touch ID (Settings › Team); joining from the phone needs the lock on.
- Every theme names the Team tab in its own words (Guild, Crew, Clan, Unit, Org).
- Docs: a README Team guide, and systemd and Task Scheduler timers for Linux and Windows members (`packaging/linux`, `packaging/windows`).

## 0.4.3

### Stats
- Stats reads Codex CLI transcripts too, with two more effort tables, per engine and per effort setting — one full rescan on first refresh.
- Where the effort went: minutes, tokens and spend per activity (review, tests, plan, debugging, browser, simulator, explanations, coding) and per model, on the Mac and the phone — heuristic labels, one full rescan on first refresh.
- Tokens/min records: every day's peak minute, the all-time best and the days it fell, a 30-day sparkline and a week-over-week trend, on the Mac and the phone — one full rescan on first refresh.

### Fixes
- Machine flags a hook whose install keeps dying and retrying — the temp directory growing by pip leftovers every hour, named by the hook that owns the running pip.
- A refresh that carries no usage for an account no longer counts as a revival or a death, so the "is back — reset early" and "hit a limit" pair from one missing sample is gone.
- Machine names who filled the temp directory (pip, Python tempfile, mktemp) and flags a tool that registers several commands on one event, which spawn on every call.
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
- Team publishing and fetching run git directly instead of through the macOS xcrun shim, about a quarter faster per call.
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
