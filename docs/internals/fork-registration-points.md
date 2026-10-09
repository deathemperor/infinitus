# Registration points — upstream files the fork edits on purpose

The fork's code lives in new files, new routes and new settings sections;
edits to upstream files stay at the registration points listed here so
upstream merges stay small (INFINITUS.md, "Upstream merges daily"). One
bullet per upstream file or feature, saying what the edit is and why. Add
a bullet when you edit an upstream file; rewrite or drop it when the edit
changes or leaves. Fork-owned files are listed in
`fork-only-files.md`. Moved whole from INFINITUS.md (#1339); per-feature
pages under `docs/internals/` keep taking narratives out of these bullets.

- `CLAUDE.md` — adds `@INFINITUS.md`.
- Fleet-wide Claude resets (#1554): `packages/contracts/src/infinitus.ts`
  (`InfinitusAccount.resets`, `InfinitusAccountResets`, additive) is
  fork-owned; the upstream edits are the hub section left unmounted —
  `apps/web/src/components/settings/ProviderSettingsPanel.tsx` (no
  `UsageProviderSettings` mount, no `usage-providers` search target),
  `UsageProviderSettings.tsx` (a plain title in place of the search id, so
  the unmounted file still compiles), `knip.jsonc` (that file and
  `AddUsageLimitSourceDialog.tsx` ignored as unused files) and
  `settingsSearch.ts` (+ test, the `usage-providers` and `cursor-keychain-usage`
  entries dropped; the Cursor Keychain toggle upstream's #13870 put in that
  section is reached from the Usage page's enable action) — since
  the Accounts page reads every hub through the Mac app. The rest is
  fork-owned (`fork-only-files.md`); rules: `docs/internals/accounts-page.md`.
- Claude banked resets (#1553): `apps/server/src/provider/claudeResetCredits.ts`
  (+ test) is the fork's whole module, taken over upstream's #13118 on every
  sync: ours reads the macOS keychain and the token's profile, upstream's
  skips macOS and reads `.claude.json` (#1601). `Drivers/ClaudeDriver.ts`
  (the instance's `login` location, a reset-credits cache on the probe's
  TTL, `consumeClaudeResetCredit` with the capabilities cache dropped before
  the re-probe), `ProviderInstanceRegistry.test.ts` (upstream's redeem tests
  also answer the fork's profile request and match the usage URL's query),
  `packages/contracts/src/providerUsageLimits.ts`
  (`ServerProviderResetCredits.label` / `nextHold`, additive), and the reset
  control's held state on `apps/web/src/components/usage/UsageLimits.tsx`
  (`resetHoldText`), `UsageLimitsPooled.tsx` and
  `apps/mobile/src/features/usage/UsageLimitsSection.tsx`.
- `apps/web/src/components/sidebar/mainAppLocation.ts` — `isSidebarUtilityPage`
  also answers for `/accounts`, `/stats` and `/utilization`, the fork's pages
  in the sidebar's utility row, so their Back returns to the main app (#1601).
- `apps/desktop/src/updates/updatesTestHarness.ts` — the `resourcesPath`
  option (#1042); under upstream's no-op file system, reads below it go to
  the real disk so the feed-swap test's own `app-update.yml` is found.
- `packages/contracts/src/rpc.ts` — `subscribeInfinitus`, `infinitus.command`,
  `infinitus.launch` and `infinitus.secret` (#747) in `WS_METHODS`, their
  `Rpc.make`s, all in `WsRpcGroup`; `subscribeInfinitusPairing` /
  `infinitus.pairingDecide` (approve-on-Mac pairing, #710) the same way,
  contracts in `infinitusPairing.ts`; `subscribeCaptures` / `captures.apply`
  (#433) the same way, contracts in `captures.ts`; `server.getStats` (#659,
  contracts in `stats.ts`); `vcs.removeWorktree` answers
  `VcsRemoveWorktreeResult` (#270 A).
- `packages/contracts/src/git.ts`, `apps/server/src/vcs/GitVcsDriverCore.ts`, `apps/web/src/hooks/useThreadActions.ts` (+ `apps/web/src/worktreeCleanup.ts`: `branchDeletionPrompt`, `describeSavedWorktreeWork`) — worktree cleanup and seeding (#270 A): `VcsRemoveWorktreeInput.keepWork` / `deleteBranch`, `VcsRemoveWorktreeResult`, `createWorktree`'s `.worktreeinclude` seeding; the `removeWorktree` mocks in `apps/server/src/mcp/WorktreeMcpService.test.ts` and `apps/server/src/orchestration-v2/ThreadLaunchService.test.ts` answer that result shape. Rules and traps: `docs/internals/worktree-cleanup.md`.
- `packages/contracts/src/environmentHttp.ts` — `EnvironmentHttpApi` adds
  `InfinitusPairingHttpApi`: the phone's two unauthenticated pairing-approval
  routes (#710), so the typed HTTP clients carry them (the git-store team's
  `InfinitusTeamControlHttpApi` left with #1592); the `infinitus` group's
  `GET /api/infinitus/thread-defaults` (#1315, the model `infinitusctl thread
new` creates on) and `POST /api/infinitus/alert` (#1375, the Mac's account
  alert), both on the operate scope.
- `packages/contracts/package.json` — the `./infinitus`,
  `./infinitusPairing`, `./captures`,
  `./infinitusAlert`, `./relayInfinitusAlert` (#1375) and
  `./relayInfinitusTeam` (#1592) subpath exports.
- `packages/contracts/src/environment.ts` — the `infinitus` and `stats` (#659)
  capabilities on `ExecutionEnvironmentCapabilities`; `alternateHttpBaseUrls`
  (optional) on `ExecutionEnvironmentDescriptor` (#663); `lanHttpBaseUrls`
  (optional, #651) beside it.
- `packages/client-runtime/src/rpc/client.ts` — `subscribeInfinitus`,
  `subscribeInfinitusPairing` and `subscribeCaptures` in
  `EnvironmentSubscriptionRpcTag`, so the client's `subscribe` accepts them.
- `apps/server/src/ws.ts` — pulls `InfinitusService`, `InfinitusCompanion`,
  `InfinitusSecret`, `InfinitusPairing` and `CaptureStore` beside the other
  services and answers the Infinitus methods: `subscribeInfinitus` /
  `infinitus.command`, `infinitus.launch`, `infinitus.secret` (the session's
  id and scopes along), the pairing stream and `decide` (the approver's
  session scopes go along; only the request id reaches the span);
  `subscribeCaptures` / `captures.apply` (#433; the project id and the
  command's type reach the span, a capture's text never); `server.getStats`
  → `usage.readStats` (#659).
- `packages/client-runtime/src/state/server.ts` — the `serverEnvironment.stats`
  query atom family over `server.getStats` (#659), refreshed with the usage
  prices.
- `packages/contracts/src/keybindings.ts` + `packages/shared/src/keybindings.ts`
  — `captures.toggle` (`mod+alt+c`) and `captures.add` (`mod+alt+shift+c`),
  both `!terminalFocus`, in `STATIC_KEYBINDING_COMMANDS` and
  `DEFAULT_KEYBINDINGS` (#433); `accounts.open` the same way. The fork yields
  on a default-chord collision: at upstream's #13212 its plain `mod+[`/`mod+]`
  for `thread.previous`/`thread.next` (#840) went, so those keys are
  upstream's `navigation.back`/`navigation.forward`. The startup sync had
  written those rules into user configs, so `apps/server/src/keybindings.ts`
  drops exact copies (`RETIRED_DEFAULT_KEYBINDINGS`) and upstream's keys
  backfill in their place. `mergeWithDefaultKeybindings` in the shared file
  treats a user rule identical to a shipped default as a snapshot
  (`resolvedKeybindingSignature`), not an override of its command, so a
  config written before a command gained a second default keeps that default.
- `packages/shared/src/projectScripts.ts` — `projectScriptPortBlock` and the
  `T3CODE_PORT`…`T3CODE_PORT_END` keys `projectScriptRuntimeEnv` adds: ten
  ports per checkout, FNV-1a of the worktree path (the project root for a
  local-checkout thread) into 10000–29999, `extraEnv` still overriding
  (#270 J; test `projectScripts.test.ts`). Surfaced by the hint under the
  Command field in `apps/web/src/components/projectScriptEditor.tsx` and the
  `command` description in `packages/contracts/src/t3ProjectFile.ts` (the
  published project file schema); the exact-env assertion in
  `apps/server/src/project/ProjectSetupScriptRunner.test.ts` became
  `assert.include`.
- `apps/web/src/components/chat/ComposerCommandMenu.tsx` — the
  `prompt-snippet` variant of `ComposerCommandItem` (label + description
  render through the default row) (#270 G).
- `apps/web/src/components/settings/ProjectSettingsPanel.tsx` —
  `ProjectPromptSnippetsSection` between the "Project" and "Checkout"
  sections, fed the group's checkouts (`promptSnippetTargets`, the
  representative first) and the panel's `reportFailure` (#270 G).
- `apps/web/src/components/CommandPalette.tsx` — the `accounts.open`
  listener and palette entry; an "Open captures" entry while a thread has
  a project (#433).
- `apps/server/src/auth/RpcAuthorization.ts` — a scope for each of them; the
  table is `satisfies Record<WsRpcMethod, …>`, so a new RPC without one is a
  type error.
- `apps/server/src/observability/RpcInstrumentation.ts` — the fork's RPCs in
  `RPC_AGGREGATES`: `server.getStats` under `server`, the Infinitus methods
  (`subscribeInfinitus`, `infinitus.command` / `.launch` / `.secret`,
  `subscribeInfinitusPairing`, `infinitus.pairingDecide`) under `infinitus`,
  `subscribeCaptures` / `captures.apply` under `captures`.
- `apps/server/src/server.ts` — `layerInfinitus` below `layerAuth`:
  `InfinitusServerPortLive` (it mints infinitusctl's session, so it needs
  the auth service, #822), `InfinitusCompanionLive`, `InfinitusSecretLive`
  (#747) and `InfinitusUsageAttributionLive` (#779) over `InfinitusLive` and
  the control client; `layerUsage` is provided it; the block is merged into
  `layerRuntimeDependencies`, `InfinitusPairingLive` (provided `layerAuth`,
  #710) after it. `infinitusPairingHttpApiLayer` and `infinitusHttpApiLayer`
  (provided `InfinitusAlertRelayLive` over the secret store and
  `FetchHttpClient.layer`, #1375) in `layerMakeRoutes`. `CaptureStore.layer`
  (#433) in the state-dir file services' `Layer.mergeAll` beside
  `Keybindings.layer`. The tunnel log lines say `CONNECT_NAME`.
- `apps/server/src/project/RepositoryIdentityResolver.ts` (+ its test) — a
  remote `gh repo set-default` marked (`remote.<name>.gh-resolved`) wins over
  upstream's `upstream`-then-`origin` rule, read only when a checkout has more
  than one remote. The fork's sync loop keeps `upstream = pingdotgg/t3code`,
  so without it every infinitus checkout that syncs was read as upstream and
  the pull requests page listed upstream's PRs.
- `apps/server/src/vcs/GitVcsDriver.ts` — `checkpoints.diffCheckpoints`
  restricts its diff to the pathspec from `checkpointDiffPathspec.ts` (#1403):
  one call before the command and the `--literal-pathspecs` / `-- <paths>`
  arguments; `removeWorktree` answers `VcsRemoveWorktreeResult` (#270 A);
  the checkpoint author and committer names are `PRODUCT_NAME`.
- `packages/contracts/src/providerRuntime.ts` — optional fields left from
  dropped features (#1627): `TaskStartedPayload.prompt` (#1567) and
  `isBackgrounded` (#952), `TurnCompletedPayload.turnCostUsd` / `turnModels`
  (#834), `usageLimited` (#648) and `cacheTtlSeconds`. No orchestration-v2
  adapter fills them and no client reads them; drop with the next sync that
  touches the file.
- `packages/contracts/src/settings.ts` — the `PromptSnippet` schema with its
  caps and `projectPromptSnippets`
  (`Record(ProjectId, NullOr(Array(PromptSnippet)))`, default `{}`) on
  `ServerSettings` and `ServerSettingsPatch` (#270 G); `desktopBadgeAttention`
  (#270 B), `desktopKeepAwake` (#1075) and the four `desktopNotifyOn*` seeds
  (#1032, read once by `NotificationModeMigration`) on `ClientSettings` and
  its patch. `packages/shared/src/serverSettings.ts` —
  `applyServerSettingsPatch` merges `projectPromptSnippets` per project key
  like `projectScriptOverrides`, so one project's save leaves the others.
- `packages/contracts/src/ipc.ts` — `infinitus-nightly` in
  `DesktopUpdateChannel` / `DesktopUpdateChannelSchema` (#1042); the fork's
  optional `DesktopBridge` methods: `getInfinitusDesktopPrefs` / `setInfinitusQuitWithApp` (#654),
  `openInfinitusSignIn` / `closeInfinitusSignIn` /
  `submitInfinitusSignInCode` (#677), `beginInfinitusOAuthSignIn` /
  `cancelInfinitusOAuthSignIn` (#1213), `listenInfinitusSignInRedirect` /
  `stopInfinitusSignInRedirect` (the stand-in for the engine's loopback
  listener, `docs/internals/accounts-page.md`), and `setInfinitusCaptureGestureEnabled`
  / `consumePendingCaptureGestures` / `onCaptureGesturePending` with the
  `DesktopCaptureGestureEvent` schema
  beside `DesktopSnapShotEvent` (#433 slices 2–3), and `consumePendingDeepLink`
  / `onDeepLinkPending` with the `DesktopDeepLink` schema after it (#270 D),
  and `onHistoryGesture` (#1250) after those, `setBadgeCount` (#270 B) and
  `setKeepAwake` (#1075), and `getInfinitusEngines` /
  `setInfinitusEngineSettings` / `controlInfinitusEngine` for the engines the
  shell runs.
  `packages/contracts/src/infinitus.ts`
  — `captureGestureEnabled` and `engines` on `InfinitusDesktopPrefs`, and
  `InfinitusOAuthSignInInput` / `InfinitusOAuthSignInResult` after
  `InfinitusSignInCodeResult` (#1213); the engine-supervision schemas
  (`InfinitusEngineKey` / `-Mode` / `-RunState` / `-Supervision` / `-Settings`
  / `-SettingsInput` / `-ControlInput` / `InfinitusEngines`) before the prefs;
  `packages/contracts/src/captures.ts` — `MAX_CAPTURE_TEXT_LENGTH`, the cap
  the desktop's selected-text helper cuts at.
- `apps/desktop/src/ipc/channels.ts`, `apps/desktop/src/ipc/DesktopIpcHandlers.ts`,
  `apps/desktop/src/preload.ts` — the channels, `ipc.handle` lines and
  preload entries for those methods; `apps/desktop/src/main.ts` —
  `InfinitusDesktop.layer` and `ElectronNotification.layer` in
  `desktopApplicationLayer`.
  `apps/desktop/src/app/DesktopPreReadyPlatform.ts` — `deepLinkIntake.attach`
  at the end of the pre-ready setup, and `DesktopEarlyElectronStartup.ts`
  exports `isDevelopmentEnvironment` for its scheme (#270 D).
- `apps/desktop/src/shell/DesktopShellEnvironment.ts` — one block in
  `installPosixEnvironment` (#1078): on darwin the merged PATH takes
  `knownPosixCliPath` between the login-shell (or launchctl) PATH and the
  process's own, so a `.zshrc` slower than the 5 s probe timeout, or a probe
  PATH with no `claude`, still reaches the usual install dirs.
- `apps/web/src/routes/__root.tsx` — the fork's mounts: `DeepLinkCoordinator`
  beside `DesktopAppActivationCoordinator` (#270 D); `NotificationModeMigration`,
  `DesktopBadgeCoordinator` and `DesktopKeepAwakeCoordinator`
  (`docs/internals/notifications.md`, `desktop-keep-awake.md`);
  `CaptureGestureCoordinator` (#433); `InfinitusEventToasts`;
  `InfinitusPeerFleets` beside it, Electron only (#1545), and
  `InfinitusSettingsSync` under it (`docs/internals/settings-sync.md`).
- `apps/server/src/serverLogger.ts` — `ServerLoggerLive` adds the fork's file
  logger (`infinitus/serverLogFile.ts`, in `fork-only-files.md`) beside `consolePretty` and
  `tracerLogger` (#1182); `apps/server/src/config.ts` — `serverLogNdjsonPath`
  (`<logsDir>/server.log.ndjson`) on `ServerDerivedPaths` beside upstream's
  `serverLogPath`; `apps/server/src/cli/triage.ts` and `triagePrompt.ts` —
  the path in the triage context so `t3 triage` names it; the test
  `ServerConfig`s in `apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.testkit.ts`
  and `orchestration-v2/testkit/ProviderReplayHarness.ts` carry the field.
- `apps/server/src/persistence/Migrations.ts` (+ `initializeV2Database.test.ts`,
  whose V1 ledger ends at 64) — the fork's own `051`–`064` stay in the ledger
  (queued turns, babysit, side questions, groups, session status reason, turn
  usage, message context, title state, PR files viewed, auto-settle; their
  features left with #1627, but existing fork databases recorded them, so
  they are schema history, not live code) and upstream's `055`–`060`
  (OrchestrationV2 onward) are renumbered `065`–`070` on every sync
  (INFINITUS.md). Upstream's `reconcileV2PreviewMigration` is not carried: no
  fork database recorded its preview numbers, and 53 and 54 are taken here.
- `apps/server/src/usage/UsageService.ts` — `readStats` (#659, the Stats
  page's fold over the transcript and repository scanners in
  `apps/server/src/stats/`), the `UsageAttribution` hook (#779), and
  `CACHE_RETENTION_DAYS = 800` (Stats compares calendar years) with
  upstream's 92 kept as `CURSOR_RETENTION_DAYS` for the Cursor history reads.
- `packages/provider-core/src/server/mcpSession.ts` —
  `withProviderSessionEnvironment`: the device-environment wrapper plus
  `T3_THREAD_ID` / `T3_ENVIRONMENT_ID`, which `infinitusctl` reads inside a
  thread's terminal (#822). `apps/server/src/terminal/Manager.ts` (the
  terminal spawn env; the environment id from `ServerEnvironment` when it is
  provided) and `apps/server/src/provider/Drivers/AntigravityDriver.ts` call
  it where upstream calls `withAgentDeviceEnvironment`.
- `apps/server/src/**` — the same `PRODUCT_NAME` / `CONNECT_NAME` rule for
  the strings a user or an agent reads: `vcs/GitVcsDriver.ts` (the
  checkpoint author), `provider/ClaudeProvider.ts`, `cli/triage.ts` +
  `triagePrompt.ts`, `server.ts` and `relay/AgentAwarenessRelay.ts` (the
  tunnel log lines), `orchestration-v2/PullRequestWatchReactor.ts` (the
  agent-facing notices), `provider/Drivers/AntigravityDriver.ts` (the
  `clientInfo` names). Re-applied to upstream's new strings on every sync,
  with the tests that assert them (`provider/ProviderRegistry.test.ts`,
  `provider/CodexDeveloperInstructions.test.ts`). The one exception is
  `orchestration-v2/RestartBackgroundNote.ts`: a Claude replay fixture
  records the note verbatim, so it keeps upstream's words (allowlisted in
  `scripts/connect-name.guard.test.ts`).
- `packages/provider-*/src/**` — the same rule for the provider packages
  (status messages, text-generation errors, the Muse `clientInfo` title, the
  shared orchestration instructions in `provider-core`), with their tests
  (`provider-core/.../orchestrationInstructions.test.ts`,
  `provider-pi/.../mcpInjection.test.ts`, `provider-muse/.../status.test.ts`).
  `scripts/connect-name.guard.test.ts` scans these roots too.
- `apps/server/src/orchestration-v2/Adapters/MuseAdapterV2.testkit.ts` —
  `replayValueMatches` compares strings with upstream's product name mapped
  to `PRODUCT_NAME` on both sides: the recorded Muse transcripts carry
  upstream's runtime instructions. `testkit/fixtures/claude_local_bash_task/output.ts`
  asserts the recorded command without its package scope, which the rename
  script rewrites in the assertion but not in the transcript.
- `packages/client-runtime/src/connection/outdatedHostUpdate.ts` (+
  `resolver.test.ts`) — the "Update T3 Code on …" messages say `PRODUCT_NAME`.
- `packages/client-runtime/src/connection/catalog.ts` — `alternateHttpBaseUrls`
  and `lastGoodHttpBaseUrl` (both optional keys) on `BearerConnectionProfile`;
  `connection/resolver.ts` — the bearer broker walks `bearerHostOrder` and
  writes `learnedBearerProfile` back; `connection/onboarding.ts` — a pairing
  keeps the descriptor's alternates, an edit keeps them and drops the roamed
  host; `connection/presentation.ts` — `connectionCatalogAlternateHosts` /
  `connectionCatalogRoamedHost`; `authorization/service.ts` —
  `authorizeBearer` takes `descriptorTimeoutMs` and returns the descriptor's
  alternates (#663); `connection/resolver.test.ts` carries the roaming cases
  (its harness's `profilePuts`).
- `apps/mobile/src/components/AppSymbol.tsx` — the Android icons for the
  symbols only the fork's surfaces use (`alarm`, `checkmark.shield`,
  `pencil.tip`, `person.3`, `push_pin`); upstream's
  `AppSymbolName` admits no symbol without one.
- `apps/mobile/src/features/connection/ConnectionEnvironmentRow.tsx` — the
  `roamingHostsLine` under a saved environment's host (#663).
- `apps/mobile/src/features/connection/EnvironmentConnectionNotice.tsx` and
  `apps/mobile/src/features/home/workspace-connection-status.ts` — the
  connection icon says what the label says. The header status returns label
  and `showsProgress` from one function, so a retry that recorded a failure
  keeps its spinner instead of reading "Reconnecting to X" beside a
  wifi-slash; the full-screen notice drops `bolt.horizontal.circle` and
  shows wifi-slash for every non-retrying phase.
- `apps/mobile/src/features/connection/ConnectionsNewRouteScreen.tsx` — mounts
  `InfinitusNearbyServers` above the Host field (#651) and
  `InfinitusAskToApprove` under the code field (#710), whose approved
  credential goes through the screen's own `connectAndClose`.; and its
  deep-link prefill goes through `pairPrefill.logic.ts` (#724): host and code
  fill in for the Infinitus variant outside `__DEV__` too, auto-connect stays
  development-only.
- `apps/server/src/environment/ServerEnvironment.ts` — fills the `infinitus`
  capability from `resolveInfinitusControlSocketPath`, and `lanHttpBaseUrls`
  from `infinitus/Layers/LanBaseUrls.ts` (#651: the routable IPv4 addresses
  on the listening port while the bind is beyond loopback).
- `apps/web/src/branding.ts` — `APP_BASE_NAME` falls back to `PRODUCT_NAME`
  (window title, auth/pairing surfaces) instead of "T3 Code".
- `apps/web/src/**` — every user-facing "T3 Code" (brand mark, first-run
  heading, copy, errors, labels, the boot-shell fallback) reads `PRODUCT_NAME`;
  `productName.guard.test.ts` fails on a new literal outside its allowlist (the
  GNOME extension's shipped name), and on a "T3 Connect" since #1368: the
  relay feature is `CONNECT_NAME` ("Infinitus Connect", user ruling
  2026-09-16 — identifiers follow in #1368's later slices). Comments stay. Re-applied to upstream's new strings on every sync; this
  one's: `cloud/useCloudLinkController.ts`, `components/NightlyMobileBeta.tsx`,
  `chat/McpAppFrame.tsx`, `chat/MessagesTimeline.tsx` + `.logic.ts`,
  `onboarding/WelcomeWizard.tsx`, `preview/PreviewView.tsx`,
  `settings/AcpSessionManagementSection.tsx`, `settings/CliCommandSettingsRow.tsx`,
  `settings/ConnectionsSettings.tsx`, `settings/SettingsPanels.tsx`,
  `settings/StorageSettings.tsx`, `ServerUpdateAction.tsx`, `ChatView.tsx`,
  `RightPanelTabs.tsx`, and the tests `desktopUpdate.logic.test.ts`,
  `settings/settingsSearch.test.ts`, `chat/MessagesTimeline.logic.test.ts`,
  `chat/MessagesTimeline.test.tsx` and `cloud/CloudEnvironmentConnectList.test.tsx`
  (the thread labels read "an Infinitus thread": `packages/shared/src/t3McpToolPresentation.ts`
  and `chat/MessagesTimeline.logic.ts` carry the article, and
  `t3McpToolPresentation.ts` also accepts the fork's `infinitus` MCP server
  name beside upstream's aliases; `packages/client-runtime/src/connection/routes.test.ts`
  and `packages/shared/src/t3McpToolPresentation.test.ts` assert the same).
- `apps/web/src/components/settings/ProjectSettingsPanel.test.tsx` — the
  `useEnvironmentSettings` mock applies the selector, which the mounted
  `ProjectPromptSnippetsSection` (#270 G) passes.
- `apps/web/vite.config.ts` — `productNamePlugin` rewrites index.html's
  boot-shell title and splash labels, and `src/lib/bootError.ts`'s copy, to
  `PRODUCT_NAME` (that module is copied standalone by `bundledDev.test.ts`
  and cannot import the constant).
- `apps/web/src/components/SidebarStageBackdrop.tsx` — the sidebar header's
  stage artwork on the release track: `resolveSidebarStageBackdropVariant`
  answers the night sky (`nightly`) for the stage label `Alpha` too, and
  `resolveEnvironmentIdentificationPillLabel` answers `"Alpha"`. Upstream
  leaves its stable channel bare because the art is how it marks a
  prerelease; here every version is `0.5.0-alpha.N`
  (`resolveDesktopAppStageLabel` → `Alpha`), so the release build is the only
  one a user installs and there is nothing to set apart — which is why the
  match is by name and `Latest` (hosted web) stays bare, pinned by
  `SidebarStageBackdrop.test.tsx`. No new art and no CSS: `--stage-night-*`
  is already defined for `:root` and every `sidebarArtwork` theme. The pill
  label is widened with it because `SettingsPanels.tsx`'s
  `showEnvironmentIdentification` row is derived from that function — without
  it the artwork would have no off switch — so that row's `settingsSearch.ts` terms follow (`alpha artwork
background`). Riding along, all
  upstream code the fork does not touch: `AppSidebarLayout.tsx`'s floating
  sidebar trigger turns white, `ComposerPrimaryActions.tsx` draws the send
  button on the art, and `AuthSurfaceShell.tsx` (no mode gate — the auth
  surface has no settings) gives the CLI-connect pages the sky in place of
  its hardcoded blue gradient. `apps/server/src/cloud/cliAuthHtml.ts`'s
  `.stage-*` CSS is a separate mechanism off `__T3CODE_BUILD_CHANNEL__` and
  is unaffected.
  A theme then picks WHICH scene: `StageArtScene`
  (`packages/shared/src/themePalettes.ts`) names the five — upstream's
  `nightly` and `dev` plus the fork's `tide`, `dawn` and `nebula` — and the
  optional `stageArt` beside `sidebarArtwork` on `ThemeDefinition` is what
  each built-in claims (t3-chat, grove and iris `nebula`, ocean `tide`,
  ember `dawn`). `themeStageArtScene` in `themePalette.ts` is
  the reader, `themeAllowsSidebarArtwork`'s sibling: built-ins only, so a
  user theme can never name one, and `serializeThemeFile`'s explicit
  `ThemeFile` omits it the way it already omits `sidebarArtwork`. The stage
  label still decides WHETHER art draws — a theme's scene replaces the
  default the label would pick, the blueprint included, so a dev build is
  themed like any other — which is why
  `resolveSidebarStageBackdropVariant` takes the scene as an optional third
  argument and `AuthSurfaceShell.tsx`'s two-argument call keeps working
  untouched. `StageBackdropArt` dispatches through a
  `Record<StageArtScene, …>`, so a new scene is one map entry and one
  component; `resolveSidebarStageFocusRingOffsetClass` tests for `dev`
  rather than `nightly` because every other scene reads the night palette.
  Still no CSS and no new art files: each scene is inline SVG over the
  `--stage-night-*` vars that already resolve for every theme, tiled in a
  `<pattern>` on the 8192-wide canvas, `useId`-prefixed def ids (the test
  renders each scene twice and asserts globally unique ids) and no
  animation. Two traps a new scene meets: the `sidebar-stage-backdrop`
  utility masks the container to transparent from 55 % down, so nothing
  below y≈53 of the 96-unit canvas renders at all — ground detail is
  impossible here, which is why upstream's clouds sit low (they are meant
  to dissolve) and why a first cut of every scene put its horizon where it
  could never be seen; and the brand wordmark sits around y≈28–40, so
  geometry there reads as clutter behind the product name. A scene's
  content belongs between them. Three attempts at a vertical-curtain
  `aurora` for grove never read as well as `nebula` does in grove's own
  palette, so grove shares that scene and the fourth was dropped rather
  than shipped weak (user ruling).
- `packages/shared/src/themePalettes.ts` — the `StageArtScene` union and the
  optional `stageArt` on `ThemeDefinition`, plus the scene each of the five
  artwork themes claims. Described with the backdrop above.
- `apps/web/src/themePalette.ts` — `themeStageArtScene` and the scene union's
  re-export. Described with the backdrop above.
- `packages/shared/src/git.ts` — `WORKTREE_BRANCH_PREFIX` is `infinitus`
  (#823: a branch name is on screen), `LEGACY_WORKTREE_BRANCH_PREFIX` keeps
  upstream's `t3code` so temporary branches minted before the rename are
  still recognised (`isTemporaryWorktreeBranch`) and regenerated;
  `GitManager.ts` / `BitbucketApi.ts` build fork-PR checkout branches from the
  constant. `apps/server/src/orchestration-v2/ThreadLaunchService.test.ts`
  expects `infinitus/<hash>` where upstream's fixtures say `t3/<hash>`.
  Upstream's own `t3code/…` fixtures in tests stay as legacy data.
- `apps/mobile/src/widgets/AgentActivity.tsx` and the Android
  `AgentActivityPresentation.kt` — a `monitoring` awareness phase (tint, sort
  bucket, `ActivityPhase.MONITORING`) left from the fork's watch-loop phase
  (#1635): nothing publishes it since the orchestration rewrite and the
  contracts no longer name it (#1627); drop with the next sync that touches
  the files.
- `packages/shared/src/cliRelease.ts` — `CLI_RELEASE_REPOSITORY` is `deathemperor/infinitus` and `cliReleaseChannelOf` reads the fork's nightly suffix (#1042, #1192); re-flipped after every sync with its two fixtures, `packages/shared/src/cliRelease.test.ts` and `packages/ssh/src/tunnel.test.ts`. Rules and traps: `docs/internals/release-and-updates.md`.
- `packages/shared/package.json` — the `./productName`, `./homeDir`,
  `./desktopIdentity`, `./infinitusControl`, `./infinitusControlSocket`,
  `./orderKeys`, `./stats` (#659) and `./infinitusTeamRedaction` (#1592)
  exports.
- `apps/desktop/src/app/DesktopUserData.ts` — `resolveUserDataPath` answers
  the fork's directory from `@infinitus/shared/desktopIdentity`
  (`infinitus-desktop` / `infinitus-desktop-dev`) and probes nothing: upstream
  adopts and seeds from its pre-rename `T3 Code (Alpha)` / `t3code` profiles
  here, which are the installed app's live state. Its test is the fork's.
- `apps/desktop/src/**` — the same rule and guard test, allowlisting the
  installed app's real `T3 Code (Alpha)`/`(Dev)` directory names and the KDE
  component name; `resolveDesktopAppBranding` titles every packaged build
  plain `PRODUCT_NAME` (no stage suffix) and keeps upstream's `(Dev)` and
  `(Nightly)` for a dev run and an upstream nightly (#823 layer 3); a fork
  nightly's stage label is `Nightly`, its title plain (#1042).
- `apps/desktop/src/electron/ElectronProtocol.ts` — the production and
  development schemes come from `@infinitus/shared/desktopIdentity`; everything
  else (CSP, renderer origin, Clerk renderer, the Linux handler) follows
  `getDesktopScheme`.
- `apps/server/src/http.ts` — `DESKTOP_RENDERER_ORIGINS` built from the same
  two scheme constants.
- `scripts/build-desktop-artifact.ts` — the mac and Linux `protocols` blocks
  (name `Infinitus`, schemes `infinitus` / `infinitus-dev`);
  `resolveDesktopBuildIconAssets` / `resolveDesktopWebAssetBrand` return the
  `infinitus` artwork for fork versions; the Screen Recording usage text and
  the artifact's package `description` say `DESKTOP_PRODUCT_NAME`, and
  `stageDesktopDmgBackground` rasterizes a per-channel SVG, so the `infinitus`
  channel has artwork of its own (#601, #732; the file is in `fork-only-files.md`).
- `infra/relay/src/db.ts`, `infra/relay/alchemy.run.ts`, `.github/workflows/deploy-relay.yml` — the relay's Postgres is a Neon project in place of upstream's PlanetScale database (#1322, #1366). Rules and traps: `docs/internals/release-and-updates.md`.
- `docs/operations/connect-setup.md` — the "Sign in with Apple (phone)" section: the Apple Services ID, key and Clerk connection App Review's guideline 4.8 requires next to Google (#10, 2026-09-22).
- `infra/relay/package.json`, `infra/relay/README.md`, `infra/relay/.env.example`, the root `.env.example`, every `infra/relay/src` service tag, `infra/relay/src/http/Api.ts` (`expectedClerkAudiences`), `docs/operations/connect-setup.md` — the relay's fork-owned names are `infinitus-relay` (#1368 B, #1322); the Alchemy stack and the Axiom names stay. Rules and traps: `docs/internals/infinitus-rename.md`.
- `packages/contracts/src/relay.ts`, `infra/relay/src/worker.ts` — the
  `infinitusAlert` group (`POST /v1/environments/:environmentId/alerts`,
  #1375) added to `RelayApi` beside upstream's server group, and its handler
  and publisher merged into the worker's API and runtime layers; the alert
  publisher gets the same FCM queue sender `FcmDeliveries` is given, hoisted
  into `fcmDeliveryQueueSenderLayer`. The runtime layer pipe has twenty
  stages, the most `pipe` takes: a new layer joins an existing stage. The
  `infinitusTeam` and `infinitusTeamEnvironment` groups (#1592) are built
  in `relay.ts` by `makeRelayInfinitusTeamGroups(RelayInternalError)` and
  added with their auth middleware; the worker merges their handlers, the
  team service (store, R2 transcript store on the retained
  `InfinitusTeamTranscripts` bucket, `Cloudflare.R2.ReadWriteBucketBinding`
  in the binding stage) and the cron's `prune`.
- `infra/relay/src/persistence/schema.ts` — re-exports
  `../infinitusTeam/schema.ts` (#1592): `Drizzle.Schema` in `db.ts` reads
  this one path, so the team tables join it here and their migration is
  generated locally (`drizzle-kit generate … --name infinitus_team`) and
  committed.
- `infra/relay/src/agentActivity/apnsDeliveryJobs.ts`, `ApnsClient.ts`,
  `ApnsDeliveries.ts` — `ApnsNotificationPayload.threadId` is optional
  (#1375): an Infinitus account alert names no thread, so the request omits
  the key, the freshness recheck stands down and the attempt rows carry
  `null`. `FcmDeliveries.ts` — the queue job's optional `alert`
  (`FcmAlertData`): a ready-made alert with a null state, sent over the card
  the consumer computes anyway and never acknowledged as a card delivery.
  `ApnsDeliveries.ts` and `AgentActivityPublisher.ts` — `sendForTarget`
  takes the `publishedThread` (#1636): the no-card alert push used to ring for
  the aggregate's top row, so a waiting thread rang again on every other
  thread's publish; it rings for the published thread's own state now, as
  Android's `androidAlertForState` always did.
- `scripts/build-cli-archive.ts` — one call before the stage is copied:
  `applyWebBrandAssets(resolveWebAssetBrandForPackageVersion(version),
"apps/server/dist/client")`, so a runtime unpacked from the archive serves
  the fork's favicons at its own origin instead of upstream's (#1196). The
  same repo-relative target and call shape `build-desktop-artifact.ts` uses —
  `applyWebBrandAssets` joins its target against the repo root, so the
  archive's temp stage is not a target it can take, and branding the build
  output in place is the only shape that reuses the function as written.
- `apps/desktop/gnome-extension/metadata.json` — the bundled extension is
  named "Infinitus SnapShots" (uuid `snap-shot@t3.codes` unchanged), matching
  the setup copy that tells the user to find it; `KdeSnapShot.ts`'s desktop
  entry `Name=` follows `PRODUCT_NAME` the same way (#601).
- `scripts/lib/brand-assets.ts` — the `infinitus*` entries in
  `BRAND_ASSET_PATHS`, the `infinitus` `WebAssetBrand` (favicons, apple-touch),
  and `resolveWebAssetBrandForPackageVersion` mapping every version but an
  upstream nightly (first prerelease id `nightly`) to it (#823 layer 3, #1042).
- `apps/web/public/{favicon.ico,favicon-16x16.png,favicon-32x32.png,apple-touch-icon.png}`
  — the fork's mark, checked in. `applyWebBrandAssets` brands only a BUILD's
  output (`build-desktop-artifact.ts`, `build-cli-archive.ts` → `dist/client`),
  so anything serving `public/` directly — a dev server, the hosted web app —
  served upstream's T3 blueprint tile, favicon and boot-shell splash logo
  (`index.html`'s `#boot-shell-logo` is `/apple-touch-icon.png`), against the
  #823 layer 1 rule that the upstream name and mark never reach a screen. The
  text beside them was already fine: `vite.config.ts`'s `productNamePlugin`
  rewrites index.html wholesale, so `alt` and `aria-label` follow
  `PRODUCT_NAME`. These four files therefore diverge from
  `DEVELOPMENT_PUBLIC_ICON_OVERRIDES` on purpose: `vp run icons:export` would
  put the dev blueprint back, and `icons:check` lists them as stale — it is not
  in any CI workflow and already reports 21 other pre-existing drifts on main,
  so a fork sync leaves it alone rather than "fixing" it. The build-time brand
  pass still runs and is now idempotent for `infinitus` versions.
- `apps/desktop/scripts/electron-launcher.mjs` — `APP_PROTOCOL_SCHEMES`
  mirrors the shared constants (a node script cannot import the workspace's
  TypeScript); the dev-only bundle id stays `com.t3tools.*`. The dev bundle
  and its helpers are named "Infinitus (Dev)" and the macOS usage prompts say
  Infinitus (#823 layer 1); `apps/desktop/package.json`'s `productName` is
  "Infinitus (Dev)" too (packaged builds get theirs from
  `scripts/build-desktop-artifact.ts`).
- `apps/web/src/components/settings/SettingsPanels.tsx` (+ `.logic.ts`) —
  `resolveDesktopUpdateTrackRow`: a fork build's select offers Release
  (`infinitus`) and Nightly (`infinitus-nightly`, #1042) instead of upstream's
  Stable / Nightly, which would hand it the real T3 Code with no way back;
  the row's `options` drive the select. The General panel also mounts
  `DesktopKeepAwakeSettings` after the background-activity row (#1075) and
  the restore / dirty-label lists carry `desktopKeepAwake`.
- `apps/server/src/binCli.ts` — the CLI's root command is `infinitus`, not
  `t3` (the archive's binary, `docs/user/install.md`); `cli/pair.test.ts` and
  `cli/app.test.ts` assert that command path.
- `packages/effect-codex-app-server/src/replay.ts` — `normalizeReplayFrame`
  ignores the initialize frame's `clientInfo.name` and `title` next to
  upstream's `version`: the Codex replay fixtures were recorded under
  upstream's product name and the client sends `PRODUCT_NAME`.
- `apps/web/src/components/chat/ChatComposer.tsx` — three fork mounts, each
  additive at an upstream anchor: the Captures badge and popover with
  `useCapturesShortcuts` (#433; `useActiveProjectRef` is the one route read
  the project-scoped features share), the Prompts badge and popover plus the
  project's snippets appended to the `/` menu and applied on select
  (`prompt-snippet`, #270 G), and the image attachment's "Draw on" button
  opening `ImageMarkupDialog`, whose save swaps the attachment for the marked
  PNG under a new id (#875).
- Upstream tests carrying the renderer origin or the userData directory
  (`DesktopAppIdentity`, `DesktopClerk`, `ElectronProtocol`, `DesktopWindow`,
  `DesktopLinuxUrlHandler`, `DesktopPreReadyPlatform`,
  `build-desktop-artifact.test.ts`, and the web fixtures that stub a desktop
  origin) use the fork's scheme.
- `scripts/build-desktop-artifact.test.ts` — the cross-architecture Windows
  probe test asserts on the probe's executable, not on `ELECTRON_RUN_AS_NODE`
  in any spawned env: the bundle self-check inherits the host's env, and a
  runner hosted by the desktop app (an agent inside Infinitus) carries that
  variable, so the upstream assertion failed there.
- `apps/server/src/usage/UsageService.test.ts` — the fixture home is the
  temp directory's real path: the service canonicalises transcript roots,
  and macOS keeps its temp directory behind a symlink (`/var` → `/private/var`),
  so two upstream tests failed on a Mac. Plus the fork's account-attribution cases (#779).
- `knip.jsonc` — `scripts/fork-visual-pass.mjs`, `fork-visual-fixture.mjs`,
  `fork-visual-check.ts`, `fold-changelog.mjs` (+ `.d.mts`),
  `infinitus-rename.ts` and `export-infinitus-splash.ts` as scripts entries
  (run by hand and by the fork's workflows; nothing imports them).
- `packages/shared/src/codexAuthHandoff.ts` and `providerAuthReturnUrl.ts` — the ChatGPT
  sign-in handoff (upstream #14290) names the desktop URL scheme and the hosted web
  origin; here they come from `desktopIdentity.ts` (`infinitus://`, #624) and
  `connectAuth.ts`'s `DEFAULT_HOSTED_APP_URL`. Their tests build URLs from the same
  constants; `apps/desktop/src/app/DesktopClerk.test.ts` spells the scheme out.
- `apps/mobile/src/lib/mobileTheme.ts` — settings groups (`--color-grouped-card`) take the tonal fill in every theme whose surface matches its chrome, not only the default one (2026-09-22). Upstream's palette alignment (#12534) gave grove, ocean, ember and iris the same colour for both, so their Settings cards painted invisibly on the phone. Pinned by `mobileTheme.test.ts` ("separates settings groups … in every theme"); drop the bullet once upstream fixes the derivation.
- `apps/mobile/app.config.ts` — the `infinitus` app variant (bundle id
  `run.infinitus.mobile`, the Infinitus Apple team, the native phone's icon
  and the splash images `scripts/export-infinitus-splash.ts` renders from it;
  `appleTeamId` per variant), selected with `APP_VARIANT=infinitus`; its
  `universalLinkHost` (`infinitus.run`, #724) adds `applinks:infinitus.run`
  to the iOS associated domains and an `autoVerify` intent filter for
  `https://infinitus.run/join` (#1313) on Android (the site serves the AASA
  `applinks` for `Q783W6B4FA.run.infinitus.mobile` and `assetlinks.json`);
  `extra.productVersion` is the root `VERSION` (#823 layer 3), which
  `SettingsAboutRouteScreen` shows in place of the store version.
- `apps/mobile/eas.json` — the `infinitus` build profile, the only one that
  selects that variant (`APP_VARIANT=infinitus`): `distribution: internal`
  (this app is not shipped to the App Store) and its own `channel`, so a fork
  build never takes an upstream channel's updates. No `environment` key:
  upstream's `preview` / `production` profiles name EAS server-side
  environments holding upstream's secrets, and the fork has none. The repo's
  `owner` and EAS `projectId` in `app.config.ts` are still upstream's, so a
  build needs an account with access to that project, or `eas init` under one
  of ours.
- `apps/mobile/plugins/withWidgetLogoAsset.cjs` (+ its test) — the mark the
  lock-screen card draws in its header comes from the variant
  (`SOURCE_BY_VARIANT`, #941): the `infinitus` build gets
  `assets/widget/InfinitusMark.svg`, every upstream variant keeps
  `T3Mark.svg` — they build the real T3 Code side by side. Only the artwork
  copied in changes; the catalog entry keeps the `T3Mark` name
  `AgentActivity.tsx` asks for, and the Infinitus mark's viewBox is padded to
  the 3:2 the widget's `renderLogo` frames it at, so the glyph is not
  stretched and upstream's widget file needs no edit. The plugin's ordering
  rule (listed BEFORE `expo-widgets`) is unchanged and still load-bearing.
- `apps/mobile/src/Stack.tsx` — the `SettingsAccounts` route (Settings ›
  Accounts, the Infinitus fleet per paired Mac) and the `SettingsTeam` route
  (Settings › Team, #1313, on the relay since #1592; `team?code=…` is where an invite link lands).
- `apps/mobile/src/features/settings/components/settings-sheet-targets.ts` —
  `SettingsAccounts` and `SettingsTeam` in the settings target union.
- `apps/mobile/src/features/settings/SettingsRouteScreen.tsx` — the rows of
  `SettingsInfinitusRows.tsx`, spread over upstream's sections (no
  "Infinitus" section: the whole app is Infinitus): Accounts, Team and the
  reset alarms toggle at the end of Connections in both the local and the
  configured screen (`InfinitusFleetRows`, `InfinitusAlarmsRow`). The Account
  and About rows say the product name; `SettingsAboutRouteScreen.tsx` and
  `SettingsNotificationsRouteScreen.tsx` (upstream's split of this screen)
  carry the product-name strings and the product version.
- `apps/mobile/src/features/settings/lib/legal-document-url.ts` and its
  test — the marketing-site base is `infinitus.run`, not `t3.codes`:
  Settings › App › Legal is the one client surface that shows a legal
  document, and upstream's bind T3 Tools, Inc. and describe services this
  fork does not run. Everything else (the four document URLs, the WebView
  allowlist) derives from that one constant. The test pins the old host as
  rejected, which is the regression. The documents themselves are the
  fork's, under `apps/mac/site/public/` — deployed by hand with
  `npx wrangler deploy`, never by CI.
- `.github/SECURITY.md` — reports go to this fork's maintainer (GitHub
  private vulnerability reporting, or the maintainer's email) and the
  policy link is `infinitus.run/security-policy`; upstream's routes them
  to `security@ping.gg`, who do not maintain this fork.
- `third-party-licenses.config.json`, `apps/web/src/components/settings/OpenSourceLicenses.tsx`,
  `apps/mobile/src/features/settings/SettingsOpenSourceLicensesRouteScreen.tsx` — the fork ships
  upstream's MIT-licensed source, whose license requires the notice travel with "substantial
  portions" of it. A `customNotices` entry named "T3 Code" carries upstream's copyright line and
  MIT text into the generated manifest, and both licenses screens lead with a "Built on T3 Code"
  section (hidden while searching) crediting the fork's origin — the generated entry alone sorts
  to position ~703 of 771, among the npm packages.
- `apps/mobile/src/components/BrandMark.tsx` and
  `apps/mobile/src/lib/mobileBranding.ts` — the brand lockup's icon is
  chosen through `resolveMobileBrandMarkVariant`, which maps the fork's
  `infinitus` variant to `apps/mobile/assets/infinitus-ios-1024.png`.
  Upstream's chain knows only `development` / `preview` / `prod`, so the
  fork's build fell through to upstream's T3 mark and drew the T3 logo
  beside the Infinitus wordmark on every loading screen. Any new
  variant-keyed asset needs an `infinitus` branch for the same reason.
- `apps/mobile/src/App.tsx` — `appLinking`'s team invite-link rewrite (`features/team/team.logic.ts`, #1313, #1592: `infinitus.run/join#<token>` → `team?code=`) and the mounted bridges: `InfinitusAlarmsBridge`, `InfinitusNotificationPresenter`. Rules and traps: `docs/internals/phone-app-bridges.md`.
- `apps/mobile/src/persistence/mobile-preferences.ts` — the
  `infinitusAlarmsEnabled` / `infinitusPinAtCreation` (#742) keys (interface
  and sanitizer).
- `apps/mobile/src/features/agent-awareness/notificationPayload.ts` —
  `INFINITUS_ACCOUNTS_DEEP_LINK` (`/settings/accounts`) accepted whole by
  `extractAgentNotificationDeepLink` beside the thread links (#1375): an
  environment's account alert rides the relay's ordinary push and a tap
  opens Settings › Accounts. `dataFromNotificationResponse` falls back to
  the push trigger's `payload` (`pushPayloadFromRequest`): expo-notifications
  on iOS fills `content.data` for a remote push from a `body` key alone, and
  the relay's keys sit at the top level beside `aps`, so `data` is empty
  there — for upstream's thread taps as much as the fork's alert. Two cases
  in `notificationNavigation.test.ts`.
- `apps/mobile/modules/t3-agent-notifications/android/.../AgentNotifications.kt`
  — `contentIntent` takes `/settings/accounts` beside `/threads/…` for the
  same alert (#1375).
- `apps/mobile/src/components/FilePreviewModal.tsx` (+ `FilePreviewModal.types.ts`, where the source types moved) — the optional `cachedUrl` on an environment-hosted source, and the one retry with a fresh URL when a reused one is refused (`previewUrlReuse.logic.ts`). Why: `docs/internals/mobile-navigation.md`.
- `packages/client-runtime/package.json` — the fork's `./state/infinitus*` subpath exports (`infinitusAccounts`, `infinitusUtilization`, `infinitusQuotaTimeline` and the rest), one entry per fork-owned model file, and `./relay/infinitusTeam` + `./relay/infinitusTeamLogic` (#1592).
- `apps/web/src/timestampFormat.ts` — `timestampLocale` exported, so the Accounts page's quota timeline (`QuotaTimeline.tsx`) writes its day labels in the same locale as every other timestamp.
- `apps/mobile/src/features/threads/ThreadFeed.tsx` — `MessageAttachmentImage`: a haptic on press, and the thumbnail's URL handed to the preview as `cachedUrl` (`previewUrlReuse.logic.ts`).
- `apps/mobile/src/features/threads/NewTaskRouteScreen.tsx` (`selectExistingThread` and its row above the project list, shown only for a pending share), `apps/mobile/src/Stack.tsx` (the `NewTaskShareThread` route in the new-task sheet), `docs/user/composer.md` (the share-sheet sentence) — a native share lands in an existing thread through the fork's `features/sharing/ShareToThreadRouteScreen.tsx`.
- `apps/mobile/src/Stack.tsx` (`RootStackLayout`'s share effect), `apps/mobile/src/features/sharing/IncomingShareProvider.tsx` (`discardShare`), `apps/mobile/src/features/sharing/incoming-share-presentation.ts` (`shareIdToDiscard`), `docs/user/composer.md` (the closing-the-sheet sentence) — closing the new-task sheet over an unimported share discards it, files included. Upstream keeps the item durable and only remembers the dismissal in memory, so a declined share reopened the sheet on every cold launch.
- `apps/mobile/src/features/threads/NewTaskDraftScreen.tsx` (`InfinitusPinAtCreationControl`, #742; `useProjectPromptSnippets` for the picked project's `/` menu, #270 G), `apps/mobile/src/state/use-thread-outbox-drain.ts` — `usePinAtCreation` after a delivered creation.
- `apps/mobile/src/lib/composerImages.ts` (+ test) — `originalImagePassthroughMimeType`: a picked still over `ORIGINAL_STILL_IMAGE_MAX_BYTES` (2 MB) takes upstream's bounded-JPEG path instead of passing through up to the 10 MB provider cap; a GIF keeps the cap. A 7.7 MB screenshot could not finish uploading over the relay before it cut the request (2026-09-19).
- `apps/mobile/src/lib/attachmentUpload.ts` (+ test) — `uploadFileBytes` aborts and fails a transfer after `ATTACHMENT_UPLOAD_TIMEOUT_MS`: the relay cut a 7.7 MB image at two minutes, iOS's background session kept replaying it, and the one-at-a-time outbox held every queued reply behind it (2026-09-19). The session stays `background` on purpose, so an upload survives a locked phone. Offered upstream as well; drop this bullet once their copy carries it.
- `apps/mobile/src/features/home/HomeScreen.tsx` — the thread list's header:
  `InfinitusSignIns` (lapsed AWS / gcloud sign-ins of paired Macs).
- `apps/mobile/src/components/CompactBrandTitle.tsx` — the iOS header's brand
  slot shows `PRODUCT_NAME` where upstream draws the T3 glyph + "Code" (#601).
- `apps/mobile/src/features/review/shikiReviewHighlighter.ts`,
  `apps/mobile/src/features/diffs/nativeReviewDiffHighlighter.ts` — an
  explicit `tokenizeTimeLimit` (5 s) on both `codeToTokensBase` calls: shiki's
  500 ms default is spent by a cold JavaScript regex engine compiling its
  patterns, which fused the first line into one token on loaded CI (#610).
- `apps/web/src/components/settings/settingsSearch.ts` — the six Infinitus
  `SettingsPath`s and their labels (Menu bar, Animations since #747 step 1,
  Team, Notifications, Devices, Engines; the Themes page of #747 step 1
  folded into the Menu bar page), the `infinitusOnly` search flag with the
  `hasInfinitusEnvironment` availability it reads, `isSettingsSectionActive`
  so a nested page's nav item is the only one lit, the `desktop-keep-awake`
  item (#1075) and `CONNECT_NAME` as the Connect section's title.
- `apps/web/src/lib/infinitusNotifications.logic.ts`, `apps/web/src/components/desktop/DesktopBadgeCoordinator.tsx`, `apps/web/src/components/desktop/NotificationModeMigration.tsx`, `apps/web/src/components/settings/DesktopBadgeSettings.tsx`, `apps/desktop/src/electron/ElectronNotification.ts`, `apps/desktop/src/ipc/methods/notifications.ts` — what the fork layers on upstream's thread notifications (#11481, ruling #1032): held / limited banners, `quietForViewer`, the queue rule, the Dock badge, the one-time mode migration. Rules and traps: `docs/internals/notifications.md`.
- `apps/web/src/components/settings/SettingsSidebarNav.tsx` — an icon per
  Infinitus path and the capability filter that hides all six where no
  connected server reaches an Infinitus app.
- `apps/web/src/components/settings/useAvailableSettingsSearchItems.ts` —
  fills `hasInfinitusEnvironment` from the environments' capabilities.
- `apps/web/src/components/settings/settingsSearch.test.ts` — the availability
  records it builds gained that field.
- `apps/web/src/routes/settings.{menu-bar,animations,team,notifications,devices,engines}.tsx`
  and `settings.infinitus.$.tsx` (new files in upstream's routes
  directory; the pages are top-level since 2026-09-18 — no "Infinitus"
  section, the whole app is Infinitus — and the splat redirects the old
  `/settings/infinitus[/…]` paths older menu bar apps and bookmarks still
  send, `settingsInfinitusRedirect.logic.ts`; Animations is an
  `InfinitusPrefsPanel` page over the catalog's `animations` section, #747
  step 1, the Menu bar page keeps `display` + `themes` + `about`, and a
  section the build lacks renders "no … settings yet") and
  `apps/web/src/routeTree.gen.ts` — regenerated with
  `@tanstack/router-generator`, never edited by hand.
- `apps/web/src/routeTree.gen.ts` — regenerated (with the installed
  `@tanstack/router-generator`, never hand-edited) whenever a fork route is
  added; the upstream sync re-generates it.
- `apps/web/src/components/settings/settingsSearch.ts` —
  `isSettingsSectionActive` counts a prefix match only for the deepest nav
  item above the path, so Engines' Activity sub screen
  (`/settings/engines/activity`) lights Engines alone.
- `apps/web/src/components/sidebar/SidebarChrome.tsx` — the Accounts, Stats
  and Utilization utility items (Accounts behind the `infinitus` capability
  gate), the header's brand mark as plain `PRODUCT_NAME`, and the backdrop
  read through `useSidebarStageBackdropVariant` so the theme's scene applies.
- `packages/contracts/src/keybindings.ts` — `accounts.open` in
  `STATIC_KEYBINDING_COMMANDS`.
- `apps/web/src/components/CommandPalette.tsx` — the "Open accounts" action and
  the `keydown` listener that turns `accounts.open` into a navigation, both
  behind the `infinitus` capability; "Open activity" and "Open utilization"
  (#747) behind the same gate, "Open stats" (#659) ungated.
- `scripts/build-cli-archive.ts`, `scripts/smoke-cli-archive.ts`, `scripts/build-desktop-artifact.ts`, `packages/shared/src/cliRelease.ts`, `apps/server/src/cloud/pinnedRuntime.ts`, `packages/ssh/src/tunnel.ts`, `apps/desktop/src/wsl/DesktopWslEnvironment.ts`, `apps/server/src/cli/*.ts`, `apps/server/src/cloud/{bootService,selfUpdate}.ts`, `infinitus-release.yml`'s `publish` job — the server binary and its archive are named `infinitus` (#1368 D); re-applied on every sync with their fixtures (`apps/server/src/cloud/selfUpdate.test.ts` among them: the archive and binary names). Rules and traps: `docs/internals/infinitus-rename.md`.
- `scripts/install.sh`, `scripts/install.ps1` (+ `scripts/sync-install-script.ts` and the served copy `apps/mac/site/public/install.sh`) — this repository, `~/.infinitus`, Linux only, release train only (#1192). Rules and traps: `docs/internals/release-and-updates.md`.
- `README.md` — the fork notice at the top, and the Installation section
  below the rule: this product's releases (the DMG, the Linux server archives,
  what is not published yet) in place of upstream's npm, winget, brew and AUR
  paths (#1192). `docs/user/install.md` (the install sections) and
  `docs/user/background-service.md` (whole) say the same; `updating.md`,
  `remote-access.md`, `welcome-wizard.md`, `install.md`'s mobile section
  (installed from a build, no store), `docs/operations/release.md` (a fork
  note at the top pointing at `infinitus-release.yml` and
  `apps/mac/docs/RELEASING.md`; upstream's text below it is untouched) and
  `docs/operations/observability.md`'s two `npx t3` examples follow (#1207).
- `docs/user/mobile-notifications.md` — the "Alerts from an Infinitus Mac"
  section appended at the end (#1178, rewritten for #1375): a Mac's account
  alerts ride Infinitus Connect's Device Notifications and open Settings ›
  Accounts; the Devices page names the Mac and pairs a phone. Upstream's
  text above it says Infinitus Connect (#1368) and is otherwise untouched.
- **The project file is `infinitus.json`** (#823 layer 1): `packages/contracts/src/t3ProjectFile.ts` (`T3_PROJECT_FILE_NAME`, `LEGACY_T3_PROJECT_FILE_NAME`, `T3_PROJECT_FILE_NAMES`, `T3_PROJECT_FILE_SCHEMA_URL`), the read sites (`T3ProjectFileLoader.ts`, `GitVcsDriverCore.ts`'s submodule read, `useT3ProjectFileScripts.ts`, `SettingsScopeContext.tsx`, `t3ProjectFileDefaults.ts`, `new-task-flow-provider.tsx`), the copy, `scripts/build-project-file-schema.ts` → `apps/mac/site/public/schema/infinitus.json`, the repository's own `infinitus.json`. Rules and traps: `docs/internals/project-file.md`.
- `.github/workflows/ci.yml` — `runs-on` swapped from Blacksmith runners to
  GitHub-hosted ones, timeouts widened, `workflow_dispatch:` added so the
  upstream-sync workflow can start CI on its branch, and the Lint job
  runs `scripts/infinitus-rename.ts --check` after `vp check`. The Mac
  jobs sit after upstream's `Check` aggregator and are not in its `needs`:
  they are path-filtered and required by the ruleset on their own. The sync workflow
  re-applies the runner swap after every merge, and once
  `scripts/infinitus-rename.ts --check` passes on `main` it renames
  upstream's tip on its own branch before merging (#1368 C,
  `docs/internals/infinitus-rename.md`). It pushes with the
  `UPSTREAM_SYNC_TOKEN` secret when present (a fine-grained PAT: contents,
  workflows, pull requests — write), since the default token cannot push a
  branch that touches `.github/workflows` (#658); without it such a sync
  is done by hand.
- `apps/mobile/src/dependency-graph.test.ts` — the upward-import ceilings (`state`/`components` → `features`) are the fork's counts: `features/infinitus` (pin-at-creation) is reached from `state/`, so upstream's numbers fail here. On a sync keep the fork's ceilings, and when the test prints a higher count set it to that.
- Upstream's deploy and publish workflows — disabled in the repository's Actions settings, never deleted; `deploy-relay.yml` is the one enabled (#1322). Rules and traps: `docs/internals/release-and-updates.md`.
