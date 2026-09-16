# Fork-only files

The files that exist only in the Infinitus fork, with what each one does
and the traps a maintainer would not find from the source. One bullet per
file or directory. Upstream files the fork edits are in
`fork-registration-points.md`. Moved whole from INFINITUS.md (#1339);
per-feature pages under `docs/internals/` keep taking narratives out of
these bullets.

- `apps/server/src/infinitus/Layers/InfinitusSlack.ts` (+ `infinitusSlack.logic.ts`, `Services/InfinitusSlackClient.ts` — the `SlackClient` seam, tests) — the Slack bridge's reactor (#574, PR 2 of 4); state in `<stateDir>/infinitus-slack/threads.json`. Rules and traps: `docs/internals/slack-bridge.md`.
- `apps/web/src/components/settings/infinitus/` — the Infinitus settings panes and their pure logic: Engines (`InfinitusEngineSecrets` + `engines.logic`, #1177; Routing, #1235), the Devices pane's "Pair a phone" (`InfinitusPairPhoneCard` + `pairPhone.logic`, #724) and "Pairing requests" (`InfinitusPairingRequestsCard` + `pairingRequests.logic`, #710) cards. Rules and traps: `docs/internals/infinitus-settings-panes.md`.
- `apps/web/src/state/infinitus.ts` — the web app's instance of the Infinitus
  snapshot and command atoms (`packages/client-runtime/src/state/infinitus.ts`,
  which also holds the pairing stream + decide command, #710, and the
  `secret` command for `infinitus.secret`, #747: a pane hands a `Redacted`
  value through, keyed by the manifest's bare arg names; the atom keeps
  nothing of its input and the request observer sees the method only).
- `apps/web/src/hooks/useInfinitusPairingToasts.ts` — a toast per phone
  asking to pair (#710): title with the device name, one Open action to
  `/settings/infinitus/devices`. Never an Approve in the toast (a spoofed
  device name must not be let in by reflex) and never the match code; every
  unseen id is toasted once, including those already pending at load. Mounted
  from `InfinitusEventToasts` beside the events hook. Silent when the stream
  is refused for want of a scope; any other failure is logged once (#730).
- `apps/web/src/hooks/useInfinitusEventToasts.ts`,
  `apps/web/src/hooks/infinitusEventToasts.logic.ts`,
  `apps/web/src/components/InfinitusEventToasts.tsx` — the host's new events
  (an account switch, every account exhausted, and the Mac's own `alert` /
  `notice` announcements) as the app's toasts; nothing from the first
  snapshot, deduped by the server's event id. An urgent one also rings and
  raises a real `Notification` while the window is away, through the client's
  `notificationMode` — this machine's only notifier for that news
  (`docs/internals/notifications.md`). Every toast has
  one Open action to /accounts; nothing is sent to the Infinitus socket
  (the waiting-session toast left with the sessions sweep, #1041). Mounted
  once from `apps/web/src/routes/__root.tsx`
  (an upstream file: that line and `CaptureGestureCoordinator`'s are the
  fork's only edits there).
- `apps/web/src/components/settings/infinitus/InfinitusLockPanel.tsx` (+
  `lock.logic.ts`, route `settings.infinitus.lock.tsx`) — Settings › Infinitus
  › Lock (#747 step 3): the Mac's biometric lock over `infinitus.command`'s
  `lock-status` / `lock on|off|now|relock <arg>` / `unlock` (native #788),
  each answering `{enabled, locked, relock}`. The switch turns the lock on
  (the Mac's own prompt runs there; the row says "Confirm on the Mac" while
  it waits) or off (the team refusal and its `--yes` left with Team, #1061).
  Re-lock is a select over the four native labels
  (`RELOCK_CHOICES` maps "5 min" ↔ `5m` and so on); the status row offers
  Lock now or Unlock (the unlock prompt runs on the Mac too). Every error is
  the app's text verbatim; the pane holds no secret. Gated on the manifest
  carrying all three verbs, else "no lock commands (needs ≥ 5bc33fa5c0)".
- `apps/web/src/components/captures/`, `apps/web/src/state/captures.ts` — the composer's Captures popover (#433, PR B): `ComposerCapturesBadge`, `ComposerCapturesMenu`, `captures.logic`, `capturesUiStore`, `useCaptures`, and `CaptureGestureCoordinator` (+ `captureGesture.logic`), the desktop gesture's landing. Rules and traps: `docs/internals/captures.md`.
- `apps/web/src/components/prompts/` — per-project prompt snippets (#270 G): `promptSnippets.logic`, `promptsUiStore`, `ComposerPromptsBadge`, `ComposerPromptsMenu`, `useProjectPromptSnippets`, `ProjectPromptSnippetsSection`, `promptSnippetSlashItems`; the phone's half is `apps/mobile/src/features/threads/promptSnippetItems.ts`. Rules and traps: `docs/internals/prompt-snippets.md`.
- `apps/web/src/components/sidebar/nextAttentionBus.ts` — the window
  event the palette uses to ask the sidebar for the next waiting thread
  (#270 C); `Sidebar.logic.ts` `resolveAttentionRank` /
  `resolveNextAttentionThreadId` + tests.
- `apps/web/src/components/sidebar/SidebarNeedsAttention.tsx` (+
  `sidebarNeedsAttention.logic.ts` + test) — the "Needs attention" section
  above the sidebar's list (#269 D): every thread whose status is approval,
  input, held or limited, across all projects and environments, in that
  order and longest wait first (`collectNeedsAttention`; a hold's `since`, else the
  thread's `updatedAt`), hidden when empty, collapsible (localStorage
  `t3code:sidebar:needs-attention-expanded`, open by default, the count in
  the collapsed header). One derived atom reads every Infinitus
  environment's `infinitusEnvironment.holds` (the same family the rows
  subscribe to); rows click through `handleThreadClick` like the list.
- `apps/web/src/components/deepLinks/` — the desktop's deep links landing
  (#270 D): `DeepLinkCoordinator` pulls the shell's latest link once the
  primary environment is connected and on every `onDeepLinkPending` ping;
  `thread` navigates to `/$environmentId/$threadId`, `new` resolves the
  project (`deepLink.logic` `resolveDeepLinkProject`: id, then title, then
  workspace-root basename, case-insensitive) and opens the composer through
  `useNewThreadHandler` with the prompt set on the draft — never sent; an
  unknown project toasts.
  `join` (#1313, the Team rebuild) parks the whole link — it is the team
  code, a secret — in `pendingTeamJoin.ts` (memory only, taken once) and
  opens Settings › Infinitus; the Team page's Join field takes it when that
  page lands, and nothing joins on its own. Only the link's kind is ever
  logged; `pair` stays the native app's.
- `packages/contracts/src/captures.ts`, `apps/server/src/captures/CaptureStore.ts`, `packages/client-runtime/src/state/captures.ts` (exported as `@t3tools/client-runtime/state/captures`) — captures (#433): one list per project, kept as `<stateDir>/captures/<projectId>.json`, streamed by `subscribeCaptures`, written by `captures.apply`. Rules and traps: `docs/internals/captures.md`.
- `packages/client-runtime/src/state/infinitusExhausted.ts` (exported as
  `@t3tools/client-runtime/state/infinitusExhausted`) — the all-accounts-
  exhausted band's verdict (#659): a fleet whose every unheld account has a
  usage window at its limit that has not rolled yet, and the earliest revival
  (each account's LAST maxed reset; the engine's `nextRecovery` when no reset
  can be ranked; within an 8-day horizon) — a port of native
  `AccountVitals.isDead` / `RecoveryMath.revival`. Drawn by
  `apps/web/src/components/accounts/ExhaustedBand.tsx` inside each fleet
  section ("All accounts exhausted · next revival HH:MM (account)", the
  time in the user's timestamp format), replacing the pop-out's reviver band.
- `apps/web/src/routes/stats.tsx`, `apps/web/src/components/stats/` — the `/stats` page (#659): `packages/client-runtime/src/state/infinitusStats.ts` folds `stats --period p`, read through `infinitusEnvironment.stats` and the snapshot's `needs: ["stats"]` lease scope (#587). Rules and traps: `docs/internals/stats-page.md`.
- `apps/web/src/routes/activity.tsx`, `apps/web/src/components/activity/` — the
  `/activity` page (#659): the pop-out's Activity pane in the fork — the
  app's event log newest first, sectioned by local day (`activity.logic.ts`),
  a kind chip per line. Reads `events --limit 100` once through
  `infinitusEnvironment.events` (a query atom with no refresh, dropped a
  minute after the page leaves) and then folds in `snapshot.events` deltas
  from the shared subscription, deduped by id
  (`packages/client-runtime/src/state/infinitusActivity.ts`, exported as
  `@t3tools/client-runtime/state/infinitusActivity`) — no polling of its own.
  The engine poller's per-minute `poll` / `no switch — …` lines (kind `other`
  on native; `isPollRow` reads the text) stay in the store but are hidden until
  the header's "Show polls" toggle, persisted like the Stats period (#696).
  Sidebar "Activity" beside Stats.
- `apps/web/src/routes/utilization.tsx`, `apps/web/src/components/utilization/` — the `/utilization` page (#747): forecast off the snapshot (`buildForecast`), history / five-hour windows / weekly waste / run rate off the Mac's `utilization --days n` (`infinitusEnvironment.utilization`, `InfinitusUtilization` in `packages/contracts/src/infinitus.ts`, the fold in `packages/client-runtime/src/state/infinitusUtilization.ts`). Rules and traps: `docs/internals/utilization.md`.
- Live token rate (#1127): `packages/contracts/src/infinitus.ts` (`InfinitusLiveTokenRate`), `rpc.ts` (`infinitus.liveTokenRate`, `AuthOrchestrationReadScope` in `RpcAuthorization.ts`), `apps/server/src/persistence/ProjectionTurnUsage.ts` (`listCompletedSince`), `apps/server/src/infinitus/liveTokenRate.logic.ts` (+ test; `EMPTY_LIVE_TOKEN_RATE`), `ws.ts`; client `infinitus.ts` (`liveTokenRate`), `infinitusUtilization.ts` (`liveRateText`), `LiveRateLine` on the Utilization page. Rules and traps: `docs/internals/live-token-rate.md`.
- `apps/web/src/components/usage/UsageAccounts.tsx` — the "By account" table on `/usage` (#779): `InfinitusUsageAttributionLive` (`apps/server/src/infinitus/Layers/`) reads the app's `history <fleet>` verb once per scan, `infinitusUsageAttribution.logic.ts` gives `accountAt(ms)`, `UsageAggregator`'s `attribute` hook sums the optional `UsageSummary.accounts`. Rules and traps: `docs/internals/usage-attribution.md`.
- `apps/web/src/routes/accounts.tsx`, `apps/web/src/components/accounts/` — the Accounts page and its Sign-ins section (`SignInsSection.tsx`, `signIns.logic.ts`; models in `packages/client-runtime/src/state/infinitusAccounts.ts`, `infinitusPageState` #693); Add account / Sign in again (`addAccount.logic.ts`, #671, #1213), the desktop's in-app sign-in (`apps/desktop/src/infinitus/InfinitusSignIn.ts`, `signIn.logic.ts`, #677) and the paste-code path over `infinitus.secret` (#747 step 2). Rules and traps: `docs/internals/accounts-page.md`.
- `apps/web/src/routes/settings.infinitus.{index,notifications,devices,engines}.tsx`
  — the four Settings › Infinitus routes, thin shells over the panes above.
  Profiles (#165, the Mac's "named way to start a session") left with the
  #1041 sessions sweep, its `profiles` contract with it, and the fixture's
  canned reply with the Mac's own verb (#1091).
- `apps/web/src/test/animationFrame.ts` — the `requestAnimationFrame` polyfill
  registered in `apps/web/vite.config.ts` test setup (an upstream test needs it
  under the fork's runner).
- `packages/contracts/src/relayInfinitusAlert.ts`, `infra/relay/src/infinitusAlerts/` (`InfinitusAlertPublisher.ts`, `InfinitusAlertApi.ts`, tests) — the relay's thread-less account alert route (#1375): an environment-signed proof (`RELAY_INFINITUS_ALERT_TYP`, same registered claims as the activity proof, the alert in place of the state, the nonce in the DPoP replay table under `infinitus-alert:`) fanned out to every phone of every linked user with notifications on — iOS as an APNs notification job without `threadId`, Android as an FCM `alert` job whose `alert_id` is the proof's `jti`. Answers with the agent-activity publish errors so the server's relay client understands every status. Why it exists and what calls it: issue #1375.
- `packages/contracts/src/productName.ts` — `PRODUCT_NAME`, the one constant
  every user-facing string routes through (#601 phase 2); contracts holds it
  because shared depends on contracts, and `packages/shared/src/productName.ts`
  re-exports it so `@t3tools/shared/productName` imports keep working.
- `apps/server` — rule: any string the user reads (CLI help and command
  descriptions, log lines, errors, HTTP/HTML pages, pairing and service copy,
  MCP tool descriptions, the git author name, the prompts and runtime
  instructions the assistant echoes) says `${PRODUCT_NAME}`, never a literal
  "T3 Code"; identifiers stay (`t3` binary and package, `T3CODE_*` env vars,
  the `t3-code` MCP server id, the `t3code/<version>` UA token, upstream URLs)
  until #1368's later slices rename them; "T3 Connect" is `CONNECT_NAME`
  (`productName.ts`, "Infinitus Connect", #1368 slice A) on every surface —
  web, mobile, server, `packages/*`, `docs/user` — and the web and desktop
  guard tests, `scripts/connect-name.guard.test.ts` (server, phone, packages,
  relay) and the visual pass fail on a new literal. The same three guards
  fail on a bare "T3" used as the product noun ("T3 Account", "Open T3",
  "a T3 thread"; #1368 follow-up) — identifiers never match — with an
  allowlist for the wordmark glyph, the relay's live column default and the
  triage playbook that must stay byte-identical to upstream's file. The
  lock-screen widgets say a literal "Infinitus": a widget body serializes
  into the extension and cannot reach an imported constant.
- `apps/mobile` — rule: screen copy, alerts, brand text, a11y labels,
  the auth device label and the `infinitus` variant's
  permission strings read `PRODUCT_NAME`; the `development`/`preview`/
  `production` variants keep their upstream names (they build the real T3 Code
  app side by side), the `t3code` URL scheme and bundle ids stay, and the
  T3 wordmark glyph remains only as the work log's own-step icon (as on web).
- `packages/contracts`, `packages/shared`, `packages/ssh`,
  `packages/client-runtime` — rule: schema descriptions, error messages, the
  askpass failure lines and the relay API title read `${PRODUCT_NAME}`; doc
  comments, fixtures and the installed app's real `T3 Code (Alpha)` name stay
  literal. `PRODUCT_NAME` is interpolated into generated shell and PowerShell
  scripts (`packages/ssh/src/auth.ts`), so it must never contain `'`, `"` or
  `$`.
- `packages/shared/src/homeDir.ts` — `DEFAULT_HOME_DIR_NAME`, the fork's
  default state directory (`~/.infinitus`, never the real T3 Code's `~/.t3`).
- `packages/shared/src/desktopIdentity.ts` — the desktop URL scheme
  (`infinitus` / `infinitus-dev`), the Electron `userData` directory names
  (`infinitus-desktop` / `infinitus-desktop-dev` — never `infinitus`, which is
  the native app's `Application Support/Infinitus` on case-insensitive APFS), and
  `adoptsLegacyDesktopUserDataDir` (empty list: the fork adopts no legacy
  directory, least of all the installed app's `T3 Code (Alpha)`).
- `packages/shared/src/infinitusControl.ts` — the control-socket path rule
  (`INFINITUS_CONTROL_SOCKET`, then the per-platform default).
- `packages/shared/src/infinitusControlSocket.ts` — the control-socket wire
  client itself (one connection per request, one JSON line each way, the
  contract's request/reply schemas), shared by the server's control client
  and the desktop shell's quit-with-app hook so the protocol exists once.
- `apps/server/src/orchestration/Services/TurnStartGate.ts` — the one seam a
  provider turn start passes through (#616, session priority mode). `start`
  takes the thread and the send and answers `started` (ran now) or `held`
  (kept for later; the gate captures the caller's context and runs it under
  that later). The passthrough layer is the server's default; the hold layer
  replaces it.
- `apps/server/src/infinitus/Layers/InfinitusSessionHold.ts` (+ `infinitusSessionHold.logic.ts`, `Services/InfinitusSessionHold.ts`) — session priority mode, hold (#616): the `TurnStartGate` that holds a background start while the fleet reads `low`/`critical`; `infinitus.releaseThread`, `subscribeInfinitusHolds` (#741), `packages/client-runtime/src/state/infinitusThreadHold.ts`, `apps/web/src/components/chat/useInfinitusHoldBanner.tsx` (+ `infinitusHoldBanner.logic.ts`), `sidebar/useInfinitusHeldSummary.ts`, `chat/PinAtCreationToggle.tsx`. Rules and traps: `docs/internals/session-priority.md`.
- `apps/server/src/infinitus/Layers/InfinitusSessionInterrupt.ts` (+ `infinitusSessionInterrupt.logic.ts`, `Services/InfinitusSessionInterrupt.ts`) — session priority mode, interrupt (#743): pauses running background turns while the fleet reads `critical` and resumes them with `CONTINUATION_PROMPT` through `TurnStartGate`. Rules and traps: `docs/internals/session-priority.md`.
- `apps/server/src/infinitus/Layers/InfinitusSecret.ts` (+ `Services/InfinitusSecret.ts`) — `infinitus.secret` (`orchestration:operate`; the sign-in and team-join verbs for any client, the rest `access:write`), the fork's one secret-carrying path (#747): the value rides the control request line's `secret` field for a verb whose manifest entry says `stdin: "secret"` (native #766). Rules and traps: `docs/internals/infinitus-secret.md`.
- `apps/server/src/infinitus/Layers/InfinitusServerPort.ts` (the credential step), `apps/server/src/infinitus/Layers/InfinitusHttp.ts`, the `infinitus` group in `packages/contracts/src/environmentHttp.ts` — the server half of `infinitusctl`'s desktop verbs (#822): the `infinitusctl` session and its 60 s heartbeat (#1137), `GET /api/infinitus/holds`, `POST /api/infinitus/release-thread`, `GET /api/infinitus/thread-defaults` (#1315). Rules and traps: `docs/internals/infinitusctl-desktop-verbs.md`.
- `apps/server/src/infinitus/` — the server's Infinitus adapter: the control client, the `InfinitusService` poller behind `subscribeInfinitus` / `infinitus.command` (`events --after`, #346), the fork-port publisher (`prefs set fork_server_port`, withheld from dev and worktree servers, #640), the verb-only spans (#676). Rules and traps: `docs/internals/server-adapter.md`.
- `apps/server/src/infinitus/Layers/InfinitusSlackSocket.ts` (+ `infinitusSlackSocket.logic.ts` — `parseSocketFrame`, `reconnectDelaySeconds`; test) — the Socket Mode client, `SlackClientLive` (#574, PR 4). Rules and traps: `docs/internals/slack-bridge.md`.
- `apps/web/src/components/settings/infinitus/InfinitusSlackCard.tsx` (+ `slack.logic.ts` — `parseAllowedUserIds`, `slackStatusLine`; test) — Settings › Infinitus › Slack (#574, PR 3), mounted from `settings.infinitus.index.tsx`'s footer, search item `infinitus-slack`. Rules and traps: `docs/internals/slack-bridge.md`.
  `Layers/InfinitusResumeOnLimit.ts` (+ `infinitusResumeOnLimit.logic.ts`) is
  resume-on-limit for the threads this server runs (#648), and since the
  sessions sweep (#1041) the only one left — the Mac's terminal nudge went
  with the sessions it typed into: the Claude adapter's parked-turn
  warning (`rate_limit_info.status: "rejected"`) or a limit-failed
  `turn.completed` records a stop (a parked turn's failed completion is the
  same stop ending, one row, the window kept); while any thread is stopped
  the layer subscribes to the snapshot and waits for the swapd fleet's
  active account — the one the plain CLI spends; the proxy fleets never
  count — to read `ok` from a probe taken after the stop (native's
  ResumeGate). swapd's `ok` is a credential status, not headroom (the
  account that just ran out reads `ok` on the next poll, which resumed a
  turn onto it every cooldown), so `resumeTarget` also reads the account's
  usage for the stop's window (`rateLimitType` on the stop): under 100 %
  counts, full does not; a reading without that window lets a different
  account through and the same one only once the stop's `resetsAt` passed.
  Then the parked turn is interrupted, a `infinitus.turn.resumed` work-log row
  names the account, and the thread continues with upstream's continuation
  prompt from its resume cursor. The stop itself leaves an
  `infinitus.thread.limited` row ("Limit hit on <account>") and joins the
  layer's `InfinitusLimitStops.stopped` list (#270 I), which `ws.ts` merges
  into `subscribeInfinitusHolds` beside the held starts so the sidebar reads
  "Limit" with the account in the tooltip; the banner reads "Stopped on a
  usage limit" with no button; the resumed row or a new turn closes it. A
  parked stop's row and stream entry carry `resetsAt` (ISO) from the SDK's
  `rate_limit_info`; the SDK re-announces a parked turn as its reset moves,
  and the stream entry follows while the row stays as written; the tooltip
  and the banner add "resets <time>" in the user's timestamp format while
  the instant is still ahead (`infinitusHoldBanner.logic.ts` `limitedLine`
  / `resetLabelFor`, `sidebar/HeldTooltipText.tsx`). A failed stop names no
  reset. A thread on an instance whose environment carries
  `ANTHROPIC_BASE_URL` (a proxy, #1088) spends no swapd account: its stop
  reads "Limit hit on the proxy instance <display name>", names no account,
  starts no snapshot watch and is never resumed — the banner stays until the
  user sends again. Once per stop, 2-min cooldown per thread,
  a user turn cancels; off by the `infinitusResumeOnLimit` server setting
  (`apps/web/src/components/settings/infinitus/InfinitusResumeCard.tsx` on
  Settings › Infinitus).
  `Layers/InfinitusCompanion.ts` is the one-app companion (#654 step 1): on a
  Mac whose socket is still quiet 3 s after the server starts it runs `open
-g -b run.infinitus` once (LaunchServices, no path, no retry, one log line;
  withheld from dev/worktree servers and from any instance running with an
  `INFINITUS_CONTROL_SOCKET` override — an isolated instance by definition,
  which must never `open` the installed app — exactly like the port
  publish; a socket FILE that exists but refuses — the app never unlinks
  its socket, so that is an Infinitus mid-relaunch whose own reopen shell
  will `open` it, #637/#756 — is re-probed every 2 s for 20 s and only a
  file still refusing after that counts as a crash's stale leftover and is
  opened over, `infinitus.companion.stale-socket`), and the
  same body answers `infinitus.launch` (operate scope) for the web's "Launch
  Infinitus" button — `{launched}` or `{launched: false, reason}`, never an
  error; the app coming up is the snapshot flipping. With the menu-bar app
  nested in the desktop bundle (#777): the packaged macOS desktop sets
  `INFINITUS_DESKTOP_BUNDLE` for its backend, the companion resolves the
  helper at `Contents/Library/LoginItems/Infinitus Menu Bar.app` and its
  version (PlistBuddy on its Info.plist), opens it by path first (`open -g
-a`; a fresh DMG install is not in LaunchServices yet, and a brew-cask
  copy may still carry the bundle id, #7) with the bundle id as the
  fallback, and reconciles at startup: an answering helper whose
  `status.bundlePath` is that nested path and whose `version` is not the
  shipped one (the updater installs by moving bundles, so the old helper
  keeps running) is sent `quit`, re-probed every 2 s until the socket stops
  answering (never an `open` on top of a shutdown, #637), then reopened by
  path. A standalone helper is left alone whatever its version; one that
  reports no `bundlePath` only has its skew logged
  (`infinitus.companion.skew-unarmed`).
- `apps/server/src/infinitus/serverLogFile.ts` (+ test) — the backend's own
  log file (#1182). Upstream keeps a server's log lines only through whoever
  started it: a boot service redirects stdout into `server.log`
  (`cloud/bootService.ts`) and the desktop's main process drains the child's
  pipes into `server-child.log` — which the packaged desktop stopped
  receiving, while `server.trace.ndjson` holds spans only (a log becomes a
  span event only inside a sampled span). So `ServerLoggerLive` also writes
  `<logsDir>/server.log.ndjson`, whoever spawned the process: one
  `Logger.formatJson` record per line, batched (1 s, flushed when the layer's
  scope closes) into the shared `RotatingFileSink` (10 MiB × 10, the trace
  file's sizing). A separate file from `serverLogPath` on purpose — a boot
  service redirects stdout there, and writing both would put every line in
  that file twice, in two formats. A sink that cannot write swallows it: a
  log file is never worth failing a turn over.
- `apps/server/src/infinitus/Layers/InfinitusSignInLapse.ts` (+ `infinitusSignInLapse.logic.ts`, tests) — lapsed AWS / gcloud sign-ins read off the Claude driver's tool results (#1076): one `infinitus.signin.needed` row per hit and the Mac's `aws-login` / `gcloud-login` flow through `InfinitusService.command`. Rules and traps: `docs/internals/sign-in-lapse.md`.
- `apps/server/src/infinitus/Layers/InfinitusAlertRelay.ts` (+ `Services/InfinitusAlertRelay.ts`, test; `packages/contracts/src/infinitusAlert.ts`) — the server half of an account alert (#1375): `POST /api/infinitus/alert` on the desktop credential's operate scope, signed with the environment's relay link key for the relay's `infinitusAlert` route (`relayInfinitusAlert.ts`), deep link `/settings/accounts`. Unlinked answers 503 `InfinitusAlertRelayUnlinked` (the Mac keeps the notice local); a relay refusal is logged with its cause and answers 500. The link is read per call, as `AgentAwarenessRelay` reads it. It replaced the Mac-key thread-card fold (`InfinitusAgentActivity.ts`, #1047 part 3): the relay draws the card now.
- `apps/desktop/src/infinitus/` — the shell's Infinitus side (#654 step 1):
  `InfinitusDesktopPrefs.ts` keeps `<stateDir>/infinitus-desktop.json`
  (`quitInfinitusWithApp`, default off; upstream's desktop-settings.json is
  untouched), `InfinitusQuitWithApp.ts` listens to `before-quit` and, with
  the knob on, sends the menu-bar app its `quit` verb over the socket — only
  when the running app's manifest lists the verb, never by version; one send
  per process, skipped for an updater-driven quit. Reached from the web over
  the bridge's optional `getInfinitusDesktopPrefs` / `setInfinitusQuitWithApp`
  (`ipc/methods/infinitus.ts`); the switch is the "This window" card on
  Settings › Infinitus (`InfinitusDesktopCard.tsx`, hidden in a browser or
  under an older shell). `InfinitusLaunchButton.tsx` is the launch button on
  the Accounts offline card and every Infinitus pane's unavailable notice,
  drawn only when the server's host is a Mac.
- `apps/desktop/src/captures/` — the capture gesture, a double tap of Shift capturing the frontmost app's selected text (#433 slices 2 and 3): `MacDoubleTapShiftProcess.ts`, `MacSelectedText.ts`, `InfinitusCaptureGesture.ts`, `setInfinitusCaptureGestureEnabled` / `consumePendingCaptureGestures`. Rules and traps: `docs/internals/captures.md`.
- `apps/desktop/src/infinitus/InfinitusOAuthSignIn.ts` (+ `InfinitusSwapdProcess.ts`, `infinitusSwapd.logic.ts`, test) — the sign-in the shell runs itself by spawning `swapd add-oauth` (#1213); methods `beginInfinitusOAuthSignIn` / `cancelInfinitusOAuthSignIn`, contracts `InfinitusOAuthSignInInput` / `-Result`. Rules and traps: `docs/internals/accounts-page.md`.
- `apps/desktop/src/infinitus/InfinitusKeepAwake.ts` — sleep held off while a turn runs (#1075): `apps/web/src/lib/desktopKeepAwake.logic.ts` `keepAwakeWanted`, the `setKeepAwake` bridge method, `DesktopKeepAwakeCoordinator`, `DesktopKeepAwakeSettings`. Rules and traps: `docs/internals/desktop-keep-awake.md`.
- `apps/desktop/src/infinitus/InfinitusHistoryGesture.ts` — the mouse's back and forward buttons arriving as the system page-swipe gesture (#1250): `INFINITUS_HISTORY_GESTURE_CHANNEL`, `onHistoryGesture`, `swipeHistoryIntent` in `lib/backNavigation.ts`. Rules and traps: `docs/internals/desktop-history-gesture.md`.
- `apps/desktop/src/shell/InfinitusPosixCliDirs.ts` (+ test) — the POSIX
  sibling of upstream's `knownWindowsCliDirs` (#1078): `~/.claude/local`,
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.nvm/versions/node/*/bin` newest first, `~/.volta/bin`, `~/.bun/bin`,
  existing ones only, joined to PATH after the login-shell probe's own
  entries and only when that probe answered nothing or a PATH without
  `claude` (`resolvePosixCliDirFallback`, pure over `exists` /
  `listDirectory`); one info line names the dirs added and the one holding
  `claude`. darwin only; a probe that answers in time still wins.
- `apps/desktop/src/infinitus/InfinitusDeepLinks.ts` — deep links `thread`, `new` and `join` on the `infinitus` / `infinitus-dev` scheme (#270 D, #1313): `deepLinkIntake`, `consumeInfinitusDeepLink` in `ipc/methods/infinitus.ts`. Rules and traps: `docs/internals/desktop-deep-links.md`.
- `apps/mobile/assets/infinitus-ios-1024.png` — the Infinitus phone icon
  (copied from the native phone's asset catalog).
- `apps/mobile/assets/widget/InfinitusMark.svg` — the twin loop for the
  lock-screen card's header (#941), monochrome so the widget's foreground
  tint applies: the same geometry `apps/mac/make-icon.swift` draws (rings at
  (6, 8) and (11, 8), radius 3.2, stroke 2, the right one broken between 10°
  and 70° with the swap arrow on the break), hand-traced as filled paths and
  checked against that renderer's own output. Redraw it from there if the
  mark changes.
- `assets/infinitus/` — the desktop and web artwork for fork builds: the
  native Mac app's 1024 icon master (`make-icon.swift` on `native`), the
  phone's full-bleed mark for Linux/apple-touch, and the `.ico`/favicon sizes
  derived from them with ImageMagick. Regenerate by hand when the mark changes.
- `apps/mobile/src/state/infinitus.ts`, `apps/mobile/src/features/accounts/` —
  the Infinitus atoms and the Accounts screen (row model imported from
  `@t3tools/client-runtime/state/infinitusAccounts`).
- `apps/server/src/infinitus/Layers/InfinitusTeamControlHttp.ts`,
  `packages/contracts/src/infinitusTeamControl.ts` — delegated control's
  network lane (#1313, spec §8): `POST /api/infinitus/team/command`,
  unauthenticated like pairing, hands the sealed envelope to the Mac's
  `team-inbox` and answers `{ack}`; never a reason. The Mac side
  (`TeamControl*.swift`, the `team-grant`/`team-drive`/`team-pending` verbs) is
  `apps/mac`'s.
- `apps/mobile/src/features/team/` — Settings › Team (#1313): members, the
  leader's requests, join from a code or the site's `/join#<code>` invite
  link; the phone's subset of the web pane's `team.logic.ts`.
- `packages/client-runtime/src/connection/roaming.ts`, `apps/server/src/infinitus/Layers/InfinitusDescriptor.ts`, `apps/mobile/src/features/connection/roamingHosts.ts` — pair on the LAN, roam to the tunnel (#663): the descriptor's `alternateHttpBaseUrls`, re-learned on every connect; public hosts (the tunnel) are dialed before private ones (the LAN address). Rules and traps: `docs/internals/roaming.md`.
- `apps/mobile/src/features/threads/promptSnippetItems.ts` (+
  `usePromptSnippets.ts`) — the phone's read-only half of per-project prompt
  snippets (#270 G): `useProjectPromptSnippets(environmentId, projectId)`
  reads `projectPromptSnippets` off the environment's server config (which
  carries the server settings, so no request of its own) and
  `promptSnippetCommandItems(snippets, query)` turns them into `/` menu rows
  filtered by name (a leading `/` or `prompt:` ignored). Registration:
  `ComposerCommandPopover.tsx` gains the `prompt-snippet` variant (icon
  `doc.text`); `use-composer-command-menu.ts` takes an optional
  `promptSnippets` input, appends the rows after commands and skills on the
  slash trigger, and `resolveComposerCommandSelection` replaces the trigger
  with the body (no trailing space); `ThreadComposer.tsx` feeds it the
  thread's project, `NewTaskDraftScreen.tsx` the picked project. Editing
  stays on the desktop.
- `apps/mobile/modules/infinitus-markup/` (fork-owned local Expo module, iOS) —
  `InfinitusMarkup.markUpImage(uri, title)`: Quick Look with editing on over a
  private temporary copy of a draft image; resolves with the edited file's URL
  or null (#269 I). `apps/mobile/src/features/infinitus/markup.ts` binds it
  (`requireOptionalNativeModule`, so a build without the module shows no
  pencil); `markupAttachment.logic.ts` picks the source bytes, sizes and
  renames the result, and swaps it into the draft's list in place;
  `useMarkUpDraftImage` runs the flow and replaces the attachment under a new
  id through `replaceComposerDraftAttachments`, so it uploads again.
  Registration: `ComposerAttachmentStrip.tsx` takes an optional `onMarkUp`
  and draws a pencil badge on image tiles; `ThreadComposer.tsx` supplies it
  (idle while voice input is busy). `apps/mobile/.swiftlint.yml` lists the
  module's `ios/` directory. Android and the new-task draft screen are
  unchanged.
- `apps/mobile/modules/infinitus-loopback-catch/` (fork-owned local Expo module, iOS; `apps/mobile/src/features/infinitus/loopbackCatch.ts` binds it) — the phone catches a relay sign-in's loopback redirect itself and hands the URL to the Mac as `infinitus.secret {command: "aws-login-callback"}`; the flow, and the card's default code-paste flow with the AWS account rows to copy, is in `InfinitusSignIns.tsx`. Rules and traps: `docs/internals/loopback-catch.md`.
- `apps/mobile/src/state/threadOutboxQueue.logic.ts` (+ `threadOutboxHolds.ts`) — the phone outbox's queue rule (#807, #812, #1325): `queueBehindRunningTurn`, `outboxQueueMode` (`infinitusComposerSendMode`), `resolveThreadOutboxDelivery`, `queueTurnCommandInput`, `queuedTurnSendAt`, `readHeldThreads`. Rules and traps: `docs/internals/phone-outbox-drain.md`.
- `apps/mobile/src/features/infinitus/lanDiscovery.logic.ts` (+ `lanDiscovery.ts`, `InfinitusNearbyServers.tsx`) — "Find Macs on this network" on the add-connection form (#651, #661, #669, #787): a /24 sweep for `/.well-known/t3/environment` on port 3773, `sweepSummary`, `shouldRetrySweep`; `missingPairingInput` in `pairing.ts`. Rules and traps: `docs/internals/lan-discovery.md`.
- `apps/mobile/src/features/infinitus/pairingApproval.logic.ts` (+ `pairingApproval.ts`,
  `InfinitusAskToApprove.tsx`) — "Ask this Mac to approve" under the code
  field (#710, PR 3): the phone POSTs a request with a random secret to the
  server at the Host field's address (same scheme rule as `buildPairingUrl`,
  so the approval and the credential exchange hit one origin), shows the
  four-character match code, and polls every 2 s until the Mac's Devices card
  decides; approval hands `connectAndClose` the one-time credential exactly as
  a typed code would. Denied, expired (the server's 404, or 30 s past
  `expiresAt` with nothing answering), refused (429) and unreachable each get
  a banner; Cancel aborts the wait. `ConnectionsNewRouteScreen.tsx` only mounts
  it and maps the credential to the existing connect path.
- `apps/mobile/src/features/infinitus/InfinitusHoldBanner.tsx` (+
  `holdBanner.logic.ts`, `pinThread.ts`, `pinThread.logic.ts`) — the phone's
  held-thread card (#742, the web's #745): "Waiting for headroom" with the
  held row's line, **Run now** (`infinitus.releaseThread`, then what the hold
  answered) and **Pin** (capability-gated; pins like the thread list does,
  top-of-run order key on reordering servers, and pinning releases the hold on
  the server). Derived from the work-log marker rows via
  `@t3tools/client-runtime/state/infinitusThreadHold`; nothing persisted.
  A turn interrupt mode paused (#743) gets the same card as "Paused for
  headroom" with **Resume now**; a limit stop (#270 I) has no button and
  adds "· resets 2:13 PM" from the row's `resetsAt` (`resetLabelFor`: the
  device's clock format — the phone has no timestamp setting — null once
  the instant is past).
- `apps/mobile/src/features/infinitus/InfinitusThreadCardBridge.tsx` (+ `threadCardBridge.controller.ts`, `liveActivityStarts.ts`, `testCard.logic.ts`, `cardSync.logic.ts`) — the phone half of the lock-screen thread card (#1047 part 2, #1265, #1277): files the `agent-activity-start` / `agent-activity` tokens with `pusherMac` through `activities-token`, re-scans `getInstances()` (`cardsToEnd`), the test card (`TEST_CARD_STATE`, `testCardState`); `packages/contracts/src/infinitus.ts` `InfinitusActivityPushKind`. Rules and traps: `docs/internals/phone-thread-card.md`.
- `apps/mobile/src/features/infinitus/InfinitusPinAtCreationControl.tsx` (+
  `pinAtCreation.ts`, `pinAtCreation.logic.ts`) — "Pin on create" for the
  phone (#742, the web's #753): a "Pin" pill in the new-task composer, shown
  only for a project whose server pins threads, backed by the
  `infinitusPinAtCreation` preference (off by default); the outbox drain reads
  it as each creation is delivered and pins through `usePinThread`, silently
  on failure (the held banner still offers Pin).
- `apps/mobile/src/features/infinitus/liveActivity.logic.ts`,
  `pushRegistration.ts`, `pushForget.ts` — the phone's `activities-token`
  registration with the Mac for the `alert` kind (the Mac's account-event
  pushes reach the phone as banners); `pusherMac` picks the Mac the alerts
  come from (`infinitusLiveActivityMac`). `pushRegistration.ts` logs a
  refused `activities-token` (`[infinitus-push]`) since the bridge sends
  with `reportFailure: false`.
- `apps/mobile/src/features/infinitus/pushRetry.logic.ts` (+ test) — the thread-card bridge's re-send rule (#941): `nextRetry`, `RETRY_DELAYS_MS`, `isEnvironmentUnreachable`. Rules and traps: `docs/internals/phone-thread-card.md`.
- `apps/mobile/src/features/infinitus/pushDiagnostics.ts` (+ `pushDiagnostics.logic.ts`, test) — the "Card push registration" row in Settings › Infinitus (#941, #1265): `tokenSender`, `agentActivityPushSummary`, `useForgetOnSwitchOff`, `forgetTokensOutcome`. Rules and traps: `docs/internals/phone-thread-card.md`.

- `apps/mobile/src/features/review/shikiReviewHighlighter.coldEngine.test.ts`
  — the #610 regression: a mocked regex engine whose first scan outlives
  shiki's default per-line budget must still tokenize the whole line.

- `scripts/infinitus-md-size.test.ts` — the INFINITUS.md byte cap (16 KB, #1339):
  every session loads that file whole, so a feature's narrative goes in a
  `docs/internals/<feature>.md` page and one ledger line here.
- `scripts/fork-visual-pass.mjs` — the visual pass harness: one headless Chrome over CDP pairs with a running web app and screenshots each route (`shot-<route>.png` + `text-<route>.txt`). Rules and traps: `docs/internals/fork-visual-pass.md`.
- `scripts/fork-visual-fixture.mjs` (+ `fork-visual-fixture.data.json`, `fork-visual-fixture.guard.test.ts`) — the canned Infinitus control socket the pass runs against in CI, kept honest against `apps/mac/Sources/InfinitusCore/{ControlProtocol,PrefCatalog}.swift` (#1091, #1139). Rules and traps: `docs/internals/fork-visual-pass.md`.
- `scripts/fork-visual-routes.ts` (+ `.test.ts`), `scripts/fork-visual-check.ts` — the route table the pass asserts (one marker per populated page, `ALWAYS_ABSENT` phrases) and the checker that applies it. Rules and traps: `docs/internals/fork-visual-pass.md`.
- `.github/workflows/fork-visual-pass.yml` — "Fork visual pass", on every PR to `main` and by hand: fixture, server from source, `fork-visual-pass.mjs`, `fork-visual-check.ts`; artifact `fork-visual-pass` (#825, #831). Rules and traps: `docs/internals/fork-visual-pass.md`.
- `.github/workflows/infinitus-nightly.yml` — the nightly (#1042, "One
  release" above): a `version` job dates the root `VERSION`, `build` is
  `infinitus-release.yml` through `workflow_call` with that version
  (`secrets: inherit`, so the Mac job signs and notarizes as for a release),
  `publish` — `main` only, on the schedule or a dispatch with `publish` —
  force-moves the `nightly` tag, clobbers the assets, removes older nights'
  versioned assets and edits the title.
- `.github/workflows/infinitus-release.yml` — the one release (INFINITUS.md "One release"): the `desktop` job nests the `mac` job's `Infinitus-Menu-Bar-<version>.zip` as a login item (#777, `--native-helper`), the `cli` job builds the Linux CLI archives and `SHA256SUMS` (#1192, upstream's `cli_archive` steps copied). Rules and traps: `docs/internals/release-and-updates.md`.
- `packages/contracts/src/providerProxy.ts`, `apps/server/src/provider/proxyModels.ts`,
  `apps/web/src/components/settings/proxyProvider.ts`,
  `apps/web/src/components/settings/ProxyProviderFields.tsx` — "Route through a
  proxy" for a Claude instance: 9Router / CLIProxyAPI / custom presets, model
  slots picked from the proxy's `GET <baseUrl>/models`, everything stored on
  the ordinary instance (env vars + CLAUDE_CONFIG_DIR), no settings file written.
