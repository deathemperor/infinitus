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
- `packages/contracts/src/rpc.ts` — `subscribeInfinitus` and
  `infinitus.command` in `WS_METHODS`, their two `Rpc.make`s, both in
  `WsRpcGroup`; `provider.proxyModels` (the add-instance wizard lists an
  Anthropic-compatible proxy's models) the same way;
  `subscribeInfinitusPairing` / `infinitus.pairingDecide` (approve-on-Mac
  pairing, #710) the same way, contracts in `infinitusPairing.ts`;
  `subscribeCaptures` / `captures.apply` (#433) the same way, contracts in
  `captures.ts`.
- `packages/contracts/src/git.ts`, `apps/server/src/vcs/GitVcsDriverCore.ts`, `apps/web/src/hooks/useThreadActions.ts` — worktree cleanup and seeding (#270 A): `VcsRemoveWorktreeInput.keepWork` / `deleteBranch`, `VcsRemoveWorktreeResult`, `createWorktree`'s `.worktreeinclude` seeding. Rules and traps: `docs/internals/worktree-cleanup.md`.
- `packages/contracts/src/environmentHttp.ts` — `EnvironmentHttpApi` adds
  `InfinitusPairingHttpApi`: the phone's two unauthenticated pairing-approval
  routes (#710), and `InfinitusTeamControlHttpApi`: a teammate's sealed team
  command for the Mac (#1313), so the typed HTTP clients carry them.
- `packages/contracts/package.json` — the `./infinitus`,
  `./infinitusPairing`, `./infinitusTeamControl`, `./captures` and
  `./relayInfinitusAlert` (#1375) subpath exports.
- `packages/contracts/src/environment.ts` — the `infinitus`, `turnQueue`
  (#812) and `turnQueueSendAt` (#1318) capabilities on `ExecutionEnvironmentCapabilities`; `alternateHttpBaseUrls` (optional) on
  `ExecutionEnvironmentDescriptor` (#663); `lanHttpBaseUrls` (optional, #651)
  beside it.
- `packages/client-runtime/src/rpc/client.ts` — `subscribeInfinitus`,
  `subscribeInfinitusPairing` and `subscribeCaptures` in
  `EnvironmentSubscriptionRpcTag`, so the client's `subscribe` accepts them.
- `apps/server/src/ws.ts` — pulls `InfinitusService` beside the other services
  and answers the two Infinitus methods; answers `provider.proxyModels` with
  `fetchProxyModels` over the server's `HttpClient`; pulls `InfinitusPairing`
  and answers the pairing stream and `decide` (the approver's session scopes
  go along; only the request id reaches the span); pulls `CaptureStore` and
  answers `subscribeCaptures` / `captures.apply` (#433; the project id and
  the command's type reach the span, a capture's text never).
- `packages/client-runtime/src/state/server.ts` — `serverEnvironment.proxyModels`
  command (single-flight per base URL).
- `apps/web/src/components/settings/AddProviderInstanceDialog.tsx` — the Claude
  Config step renders `ProxyProviderFields` ("Route through a proxy"); on save
  `applyProxyDraft` adds the ANTHROPIC_* environment variables (the key marked
  sensitive), a dedicated `homePath` (`~/.claude-proxy/<instanceId>` unless one
  was typed) and every picked model as a custom model (the loaded list is
  checkboxes with Select all, so the proxy's models populate the picker in one
  click; models already on the instance, by slug or `{slug}`, are not doubled).
- `packages/contracts/src/keybindings.ts` + `packages/shared/src/keybindings.ts`
  — `captures.toggle` (`mod+alt+c`) and `captures.add` (`mod+alt+shift+c`),
  both `!terminalFocus`, in `STATIC_KEYBINDING_COMMANDS` and
  `DEFAULT_KEYBINDINGS` (#433); `accounts.open` the same way;
  `thread.nextAttention` (`mod+alt+n`, `!terminalFocus`; it was `mod+shift+l` until upstream's #11615 took that chord for `composer.previousWorktree` — the fork yields on a default-chord collision) in
  `THREAD_KEYBINDING_COMMANDS` (#270 C).
- `apps/web/src/components/Sidebar.tsx` — `resolveNextAttentionThreadKey`
  (ranks the rendered list: approval, input, failed, held, unseen
  completion; holds read from the rows' atoms via `appAtomRegistry`), the
  `thread.nextAttention` branch of the keydown handler and the
  `onNextAttentionThreadRequest` listener (#270 C).
- `packages/shared/src/projectScripts.ts` — `projectScriptPortBlock` and the
  `T3CODE_PORT`…`T3CODE_PORT_END` keys `projectScriptRuntimeEnv` adds: ten
  ports per checkout, FNV-1a of the worktree path (the project root for a
  local-checkout thread) into 10000–29999, `extraEnv` still overriding
  (#270 J; test `projectScripts.test.ts`). Surfaced by the hint under the
  Command field in `apps/web/src/components/projectScriptEditor.tsx` and the
  `command` description in `packages/contracts/src/t3ProjectFile.ts` (the
  published project file schema); the two exact-env assertions in
  `apps/server/src/project/ProjectSetupScriptRunner.test.ts` became
  `expect.objectContaining`.
- `apps/web/src/components/CommandPalette.tsx` — the "Jump to next waiting
  thread" action (`requestNextAttentionThread`) and its keydown match (#270 C).
- `apps/web/src/components/chat/ChatComposer.tsx` — one block of hooks
  (`useActiveProjectRef`, the captures UI store, the list query,
  `useCapturesShortcuts`) beside the stash effects, `ComposerCapturesBadge`
  in the shoulder dock after the stash badge, and `ComposerCapturesMenu` in
  the anchored layer before the command menu, fed
  `insertComposerTextAtEnd` (#433). Beside them the Prompts block (#270 G):
  `useProjectPromptSnippets`, the prompts UI store, `ComposerPromptsBadge`
  after the Captures badge, `ComposerPromptsMenu` after the Captures menu
  (the Captures guard also checks `!isPromptsMenuOpen`); `useProjectPromptSnippets`
  is read just above the "Derived: composer trigger / menu" block so the
  slash-menu `useMemo` appends `promptSnippetSlashItems(...)` after
  `searchSlashCommandItems`, and `onSelectComposerItem` has a
  `prompt-snippet` branch before the skill one.
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
- `apps/server/src/server.ts` — `InfinitusLayerLive` in
  `RuntimeDependenciesLive`. `InfinitusResumeOnLimitLive` in `ReactorLayerLive`.
  `infinitusPairingHttpApiLayer` and `infinitusTeamControlHttpApiLayer` in
  `makeRoutesLayer`
  (#648). `InfinitusSignInLapseLive` beside it, with its own control
  client (#1076), merged with `InfinitusAgentActivityLive` (#1047). `InfinitusSlackLive` (provided `SlackClientLive` over
  `FetchHttpClient.layer`) beside it (#574). `InfinitusPairingLive` (provided `AuthLayerLive`) beside them, and
  `infinitusPairingHttpApiLayer` in the `HttpApiBuilder.layer` provides
  (#710). `InfinitusSessionHoldLayers` in `ReactorLayerLive` (#616): the hold,
  and the `TurnStartGate` it implements; `InfinitusSessionInterruptLive` just
  before it (#743), a consumer of that gate. `InfinitusForkAnchorGate` just above
  the hold layers (#1013): wraps the gate with the fork-anchor re-check. `CaptureStore.layer` (#433) in the
  state-dir file services' `Layer.mergeAll` beside `Keybindings.layer`.
- `apps/server/src/vcs/GitVcsDriver.ts` (+ its test) — upstream's open PR
  pingdotgg/t3code#10792 carried ahead of upstream (2026-09-12, upstream
  #3646): checkpoint capture seeds its private index from the workspace
  index and resets it to HEAD keeping matching stat metadata, so `git add
-A` re-hashes only what changed instead of every tracked file (banyan:
  13 s → 1.2 s; the fresh index crossed the 30 s `VcsProcess` timeout under
  load and every turn ended with "Checkpoint capture failed"). Falls back to
  the fresh-index path when the index is missing, corrupt, truncated or
  carries assume-unchanged / skip-worktree flags. Drops on the upstream
  sync that brings #10792 in; until then a sync conflict here is resolved
  toward upstream.
- `apps/server/src/orchestration/Layers/ProviderCommandReactor.ts` — the turn
  start's session start + send run through `TurnStartGate.start` (#616);
  `serverRuntimeStartup.ts` — the post-update continuation's forked send does
  the same. Their test harnesses (`ProviderCommandReactor.test.ts`,
  `serverRuntimeStartup.reconcile.test.ts`, `AgentSessionImporter.test.ts`)
  provide the passthrough gate, with a `turnStartGate` override in the first two.
- Chat-only rewind (#270 E1) is upstream's since the 2026-09-12 sync
  (`thread.conversation.revert` → `thread.checkpoint-revert-requested`
  with `restoreFiles: false`, #11358); the fork's `thread.chat.rewind`
  command, its event and `handleChatRewindRequested` are gone. What stays
  fork: `MessagesTimeline.tsx`'s revert menu ("Revert files and chat" /
  "Restore files only" / "Rewind chat only" / "Fork from here",
  `TimelineRevertMode`) and `ChatView.tsx`'s
  `onRevertToTurnCount(turnCount, messageId, mode)`, whose `chat` mode sends
  `revertThreadCheckpoint({ restoreFiles: false })` through the same
  composer hand-back as the full revert; upstream's two-button AlertDialog
  (`pendingRevert`) is dropped at every sync because the menu already asks.
- Restore files, keep the chat (#269 E, Cursor's default checkpoint
  action): `thread.checkpoint.revert` and its `-requested` event carry
  `keepChat?: boolean`; `CheckpointReactor.handleRevertRequested` with it
  restores the checkpoint and refreshes the workspace index, then stops:
  no provider rollback (so no rollback-support guard), no later-checkpoint
  ref deletion, no `thread.revert.complete` — one `checkpoint.restored`
  info activity ("Files restored to turn N", `turnId: null`) instead, and
  the span carries `keepChat`. Web: `TimelineRevertMode` `restore-files`,
  the menu's "Restore files only" between the full revert and the chat
  rewind, its own confirm text, and the mode skips the conversation-rollback
  check. Test beside the E1 one.
- Bash description as the row's headline (#1231): `apps/server/src/orchestration/ActivityPayloadProjection.ts` (`data.description` on `command_execution`), `apps/web/src/session-logic.ts` (`WorkLogEntry.commandDescription`), `apps/web/src/components/chat/MessagesTimeline.logic.ts`, `apps/mobile/src/lib/threadActivity.ts`. Rules and traps: `docs/internals/bash-description-headline.md`.
- Turn footer (#952): `packages/client-runtime/src/turnFooter.ts` (+ test; `turnFooter`, `turnFooterLabel`, exported as `@t3tools/client-runtime/turnFooter`), `apps/server/src/provider/Layers/ClaudeAdapter.ts` (`is_backgrounded` → `TaskStartedPayload.isBackgrounded` in `packages/contracts/src/providerRuntime.ts`, passed through by `ProviderRuntimeIngestion.ts`; `liveBackgroundAgentsMessage`, #974), `apps/server/src/infinitus/Layers/BackgroundAgentsReconcile.ts` (+ test; `infinitus/backgroundAgents.logic.ts`; the `background-agents.reconcile` phase in `serverRuntimeStartup.ts`, #977), `apps/web/src/components/chat/useTurnFooters.ts`, `MessagesTimeline.tsx` (`turnFooters`, `AssistantMessageMeta`), `ChatView.tsx`. Rules and traps: `docs/internals/turn-footer.md`.
- Server-side message queue (#806, the server half of #270 F): `packages/contracts/src/baseSchemas.ts` (`QueueId`), `packages/contracts/src/orchestration.ts` (`OrchestrationQueuedTurn`, `queuedTurns?`, `thread.turn.queue` / `.queue.update` / `.queue.remove` / `.queue.move`, `queuedFrom?`, `thread.turn-queued` / `-queue-updated` / `-queue-removed` / `-queue-moved`), `packages/shared/src/orderKeys.ts`, `apps/server/src/orchestration/decider.ts`, `projector.ts`, `Schemas.ts`, `packages/client-runtime` `threadReducer.ts`, `Layers/ProjectionPipeline.ts` (`projection_thread_queued_turns`, migrations `051`, `059`, `062` (`send_at`, #1318); `persistence/ProjectionThreadQueuedTurns.ts`), `Layers/ProjectionSnapshotQuery.ts`, `Normalizer.ts`, `apps/server/src/server.ts` (`InfinitusTurnQueueLive`), `Services/InfinitusSessionInterrupt.ts` (`paused`); fork-only `apps/server/src/infinitus/Layers/InfinitusTurnQueue.ts` (+ `infinitusTurnQueue.logic.ts`, `queueDrainVerdict`). Rules and traps: `docs/internals/turn-queue.md`.
- Update idle gate (#829): `packages/contracts/src/server.ts` (`ServerRunningTurn`, `ServerUpdateRunningTurnsPolicy`, `runningTurns?` on `ServerSelfUpdateInput` and `ServerSelfUpdateError`, the `waiting` progress stage), `packages/contracts/src/environmentHttp.ts` (`GET /api/infinitus/running-turns`), `apps/server/src/infinitus/Services/InfinitusRunningTurns.ts` + `Layers/InfinitusRunningTurns.ts` (served by `Layers/InfinitusHttp.ts`), `apps/server/src/cloud/selfUpdate.ts` (`awaitIdle`, `commitDesktopUpdate`), `ws.ts`, `server.ts`; `packages/client-runtime/src/state/server.ts`, `apps/web/src/components/ServerUpdateAction.tsx`, `apps/web/src/components/desktopUpdate.logic.ts` (`countRunningLocalTurns`), `sidebar/SidebarUpdatePill.tsx`, `sidebar/DesktopUpdateRunningTurnsDialog.tsx`, `state/desktopUpdate.ts` (`desktopInstallWhenIdleAtom`). Rules and traps: `docs/internals/update-idle-gate.md`.
- Babysit (#269 A, on the #806 queue): `packages/contracts/src/orchestration.ts` (`ThreadBabysit`, `BABYSIT_MAX_ROUNDS`, `babysit?`, `thread.meta.update`'s `babysit?` / `babysitRounds?`, `thread.meta-updated`'s `babysit?`), `apps/server/src/orchestration/decider.ts` (`babysitPatch`), `projector.ts`, `packages/client-runtime/src/state/threadReducer.ts`, `Migrations/052_ProjectionThreadsBabysit.ts` (`projection_threads.babysit_json`; `Layers/ProjectionThreads.ts`, `ProjectionPipeline.ts`, `ProjectionSnapshotQuery.ts`), `PullRequestSyncReactor.ts` (`requestedSync`), `collectNeedsAttention`; fork-only `apps/server/src/infinitus/Layers/infinitusBabysit.logic.ts` (`babysitVerdict`, `settleBabysitMarks`, `seedBabysitMarks`, `babysitPrompt`), `InfinitusBabysit.ts` (`InfinitusBabysitLive`), `apps/web/src/components/ThreadBabysitToggle.tsx` (shown by `BranchToolbarBranchSelector.tsx`). Rules and traps: `docs/internals/babysit.md`.
- Turn usage (#834): `packages/contracts/src/orchestration.ts` (`ThreadTurnUsage`, `ThreadUsageRollup`, `thread.turn.usage.record`, `thread.usage.backfill`), `packages/shared/src/threadUsage.ts`, `providerRuntime.ts` (`turnCostUsd?`, `turnModels?`), `ClaudeAdapter.ts` (+ `claudeTurnUsage.logic.ts`), `ProviderRuntimeIngestion.ts` (+ `orchestration/threadTurnUsage.ts`), decider / projector / reducer, `persistence/ProjectionTurnUsage.ts` (migrations `056`, `057`), `orchestration/Layers/ThreadUsageBackfill.ts`, `apps/web/src/components/chat/ThreadUsagePopover.tsx`, `apps/server/src/usage/UsageService.ts`. Rules and traps: `docs/internals/turn-usage.md`.
- Side question (#269 C): `packages/contracts/src/orchestration.ts` (`sideOf?`; column `side_of`, `Migrations/053_ProjectionThreadsSideOf.ts`), `packages/contracts/src/infinitus.ts` (`InfinitusThreadForkInput.side?`), `apps/server/src/infinitus/ThreadFork.ts`; `apps/web/src/rightPanelStore.ts`, `apps/web/src/components/SideQuestionPanel.tsx` (+ `.logic.ts`), `ChatView.tsx`, `ChatComposer.tsx`, `CompactComposerControlsMenu.tsx`, `Sidebar.tsx`, `CommandPalette.tsx`, Settings › Archived. Rules and traps: `docs/internals/side-question.md`.
- **Best of N (#269 B).** `groupId` on `thread.create`, the created payload and the bootstrap's `createThread` (`apps/server/src/ws.ts`); `ProjectionThreads.ts`, `ProjectionPipeline.ts`, `ProjectionSnapshotQuery.ts` (`group_id`, migration `054`); `apps/web/src/components/chat/bestOf.logic.ts` (`planBestOfMembers`, `bestOfSiblings`, `bestOfMemberStatus`, `bestOfMemberStats`, `bestOfMemberChanges`), `BestOfPicker.tsx`, `apps/web/src/components/BestOfGroupCard.tsx`, `ChatView.tsx` (`onSend(…, bestOf)`). Rules and traps: `docs/internals/best-of.md`.
- **Worktree limit (#269 H).** `packages/contracts/src/settings.ts` (`worktreeMaxCount`), `apps/server/src/ws.ts` (the bootstrap check, `worktreesInFlight`, the `vcs.createWorktree` check), `ProjectionSnapshotQuery.getWorktreeHolders`, `apps/server/src/orchestration/worktreeCap.logic.ts` (`worktreeCapRefusal`), `SettingsPanels.tsx` + `settingsSearch.ts` ("Worktree limit"). Rules and traps: `docs/internals/worktree-limit.md`.
- **Reconnect a turn whose transport went away (#832).** `apps/server/src/provider/Layers/ClaudeAdapter.ts` (`scheduleReconnect`, `reopenForReconnect`, `reconnectQueryOptions`, `RECONNECT_EXHAUSTED_MESSAGE`; + `claudeReconnect.logic.ts`), `apps/server/src/provider/turnContinuation.ts`, `ProviderService.processRuntimeEvent` (`continueAfterServerUpdate`), `packages/contracts/src/orchestration.ts` (`OrchestrationSession.statusReason`), `ProjectionThreadSessions` (`status_reason`, `Migrations/055_ProjectionThreadSessionsStatusReason.ts`), `ProjectionPipeline.ts`, `ProjectionSnapshotQuery.ts`, `apps/web/src/components/chat/ThreadReconnectingNotice.tsx` (mounted in `ChatView.tsx`). Rules and traps: `docs/internals/turn-reconnect.md`.
- Fork from a turn (#270 E2): `packages/contracts/src/infinitus.ts` (`InfinitusThreadForkInput/Result`, `InfinitusThreadForkRefused`), `rpc.ts` (`infinitus.forkThread`; `AuthOrchestrationOperateScope` in `RpcAuthorization.ts`), `apps/server/src/ws.ts`, `apps/server/src/provider/Layers/ClaudeAdapter.ts` (the resume cursor's `anchors` and `fork`, `resumeSessionAtLatest`; `claudeForkFallback.logic.ts`), `CodexResumeCursorSchema` / `openCodexThread` (`thread/fork`, #819), `packages/client-runtime/src/state/infinitus.ts` (`forkThread`), `ChatView.tsx` (`supportsThreadFork`, mode `fork`), `MessagesTimeline.tsx`; fork-only `apps/server/src/infinitus/ThreadFork.ts` (+ test; `forkThreadAtTurn`, `forkSeedMessages`), `InfinitusForkAnchorGate`. Rules and traps: `docs/internals/fork-from-turn.md`.
- `packages/contracts/src/settings.ts` — `infinitusResumeOnLimit` on
  `ServerSettings` (default on) and `ServerSettingsPatch` (#648); the
  `PromptSnippet` schema with its caps and `projectPromptSnippets`
  (`Record(ProjectId, NullOr(Array(PromptSnippet)))`, default `{}`) on both
  (#270 G). `packages/shared/src/serverSettings.ts` —
  `applyServerSettingsPatch` merges `projectPromptSnippets` per project key
  like `projectScriptOverrides`, so one project's save leaves the others.
- `packages/contracts/src/settings.ts` — `InfinitusSlackSettings` as `infinitusSlack` on `ServerSettings` and the patch (#574, the Slack bridge's PR 1); `packages/shared/src/serverSettings.ts` merges it; `apps/server/src/serverSettings.ts` keeps the two tokens in `ServerSecretStore` (`infinitus-slack-app-token` / `-bot-token`). Rules and traps: `docs/internals/slack-bridge.md`.
- `packages/contracts/src/settings.ts` — `advisorModel` on `ClaudeSettings`
  and its patch (#1232: the SDK's `advisorModel` setting, passed by
  `apps/server/src/provider/Layers/ClaudeAdapter.ts` when the instance names
  one and left to Claude Code's own setting when empty), with the
  `customOption` hook on `ProviderSettingsFormAnnotation` that
  `apps/web/src/components/settings/ProviderSettingsForm.tsx`'s select draws
  as a "Custom model ID…" choice opening an input; `ProviderInstanceCard.tsx`
  and `AddProviderInstanceDialog.tsx` add one line under the form when the
  instance routes through a proxy (`hasAnthropicBaseUrl` in
  `proxyProvider.ts`), since the CLI adds the tool on first-party only.
- `packages/contracts/src/settings.ts` — `ComposerSendMode` and
  `composerSendMode` (`queue` default, `steer`) on `ClientSettings` and its
  patch (#270 F); `settings.test.ts` covers the default. Upstream's
  `followUpBehavior` (#11964, the same two literals driving its client-side
  queue) is dropped at every sync — field, Settings › General row,
  `settingsSearch.ts` item, test and `docs/user/composer.md` paragraphs —
  since the fork's setting already decides it; its `thread.steerQueuedMessage`
  keybinding (`mod+shift+enter`) stays, acting only on the client-side queue.
- Queue vs steer (#270 F, #1318; the queue lives on the server since #806): `apps/web/src/composer-logic.ts` (`ComposerSubmissionIntent`, `composerSendModeForEnter`), `ChatComposer.tsx` (`submitComposer`), `ChatView.tsx` (`onSend`; upstream's client-side queue #11673 gated off on a server thread), `components/chat/useQueuedTurnActions.ts`, `ComposerSendQueue.tsx`, `composerSendQueue.logic.ts` (+ test), `hooks/useLegacyQueueMigration.ts`, `ComposerPrimaryActions.tsx` (`runningSendMode`), `SettingsPanels.tsx` + `settingsSearch.ts`; client-runtime `operations/commands.ts` + `state/threadCommands.ts`. Rules and traps: `docs/internals/turn-queue.md`.
- `packages/contracts/src/ipc.ts` — `infinitus-nightly` in
  `DesktopUpdateChannel` / `DesktopUpdateChannelSchema` (#1042); the fork's
  optional `DesktopBridge` methods: `getInfinitusDesktopPrefs` / `setInfinitusQuitWithApp` (#654),
  `openInfinitusSignIn` / `closeInfinitusSignIn` /
  `submitInfinitusSignInCode` (#677), `beginInfinitusOAuthSignIn` /
  `cancelInfinitusOAuthSignIn` (#1213), and `setInfinitusCaptureGestureEnabled`
  / `consumePendingCaptureGestures` / `onCaptureGesturePending` with the
  `DesktopCaptureGestureEvent` schema
  beside `DesktopSnapShotEvent` (#433 slices 2–3), and `consumePendingDeepLink`
  / `onDeepLinkPending` with the `DesktopDeepLink` schema after it (#270 D),
  and `onHistoryGesture` (#1250) after those.
  `packages/contracts/src/infinitus.ts`
  — `captureGestureEnabled` on `InfinitusDesktopPrefs`, and
  `InfinitusOAuthSignInInput` / `InfinitusOAuthSignInResult` after
  `InfinitusSignInCodeResult` (#1213);
  `packages/contracts/src/captures.ts` — `MAX_CAPTURE_TEXT_LENGTH`, the cap
  the desktop's selected-text helper cuts at.
- `apps/desktop/src/ipc/channels.ts`, `apps/desktop/src/ipc/DesktopIpcHandlers.ts`,
  `apps/desktop/src/preload.ts` — the channels, `ipc.handle` lines and
  preload entries for those methods; `apps/desktop/src/main.ts` —
  `InfinitusDesktop.layer` in `desktopApplicationLayer`.
  `apps/desktop/src/app/DesktopPreReadyPlatform.ts` — `deepLinkIntake.attach`
  at the end of the pre-ready setup, and `DesktopEarlyElectronStartup.ts`
  exports `isDevelopmentEnvironment` for its scheme (#270 D).
- `apps/desktop/src/shell/DesktopShellEnvironment.ts` — one block in
  `installPosixEnvironment` (#1078): on darwin the merged PATH takes
  `knownPosixCliPath` between the login-shell (or launchctl) PATH and the
  process's own, so a `.zshrc` slower than the 5 s probe timeout, or a probe
  PATH with no `claude`, still reaches the usual install dirs.
- `apps/web/src/routes/__root.tsx` — `DeepLinkCoordinator` mounted beside
  `DesktopAppActivationCoordinator` (#270 D).
- `apps/server/src/server.test.ts` — a `Layer.mock(InfinitusService)` in the
  harness's stub stack, since the routes layer now needs the service; a
  `Layer.mock(InfinitusPairing)` and a `Layer.mock(CaptureStore)` beside it.
- `apps/server/src/serverLogger.ts` — `ServerLoggerLive` adds the fork's file
  logger (`infinitus/serverLogFile.ts`, below) beside `consolePretty` and
  `tracerLogger` (#1182); `apps/server/src/config.ts` — `serverLogNdjsonPath`
  (`<logsDir>/server.log.ndjson`) on `ServerDerivedPaths` beside upstream's
  `serverLogPath`; `apps/server/src/cli/triage.ts` and `triagePrompt.ts` —
  the path in the triage context so `t3 triage` names it.
- `apps/server/src/http.ts` — the `/.well-known/t3/environment` handler passes
  the descriptor through `withAlternateHttpBaseUrls` (#663).
- `packages/client-runtime/src/connection/catalog.ts` — `alternateHttpBaseUrls`
  and `lastGoodHttpBaseUrl` (both optional keys) on `BearerConnectionProfile`;
  `connection/resolver.ts` — the bearer broker walks `bearerHostOrder` and
  writes `learnedBearerProfile` back; `connection/onboarding.ts` — a pairing
  keeps the descriptor's alternates, an edit keeps them and drops the roamed
  host; `connection/presentation.ts` — `connectionCatalogAlternateHosts` /
  `connectionCatalogRoamedHost`; `authorization/service.ts` —
  `authorizeBearer` takes `descriptorTimeoutMs` and returns the descriptor's
  alternates (#663).
- `apps/mobile/src/components/AndroidScreenHeader.tsx` — `AndroidHeaderAction`
  gains an optional `menu` (`AndroidAnchoredMenuProps`' actions, title and
  `onPressAction`); an action carrying one renders the icon button inside
  `AndroidAnchoredMenu` with the function child, so its tap opens the
  choices — the Android form of an iOS header menu item, uncapped (an
  `Alert` shows at most three buttons; #269 F's PR menu reaches four).
- `apps/mobile/src/features/connection/ConnectionEnvironmentRow.tsx` — the
  `roamingHostsLine` under a saved environment's host (#663).
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
  2026-09-16 — identifiers follow in #1368's later slices). Comments stay.
- `apps/web/vite.config.ts` — `productNamePlugin` rewrites index.html's
  boot-shell title and splash labels, and `src/lib/bootError.ts`'s copy, to
  `PRODUCT_NAME` (that module is copied standalone by `bundledDev.test.ts`
  and cannot import the constant).
- `packages/shared/src/git.ts` — `WORKTREE_BRANCH_PREFIX` is `infinitus`
  (#823: a branch name is on screen), `LEGACY_WORKTREE_BRANCH_PREFIX` keeps
  upstream's `t3code` so temporary branches minted before the rename are
  still recognised (`isTemporaryWorktreeBranch`) and regenerated
  (`ProviderCommandReactor.buildGeneratedWorktreeBranchName` strips both);
  `GitManager.ts` / `BitbucketApi.ts` build fork-PR checkout branches from the
  constant. Upstream's own `t3code/…` fixtures in tests stay as legacy data.
- `packages/shared/src/cliRelease.ts` — `CLI_RELEASE_REPOSITORY` is `deathemperor/infinitus` and `cliReleaseChannelOf` reads the fork's nightly suffix (#1042, #1192); re-flipped after every sync with its two fixtures, `packages/shared/src/cliRelease.test.ts` and `packages/ssh/src/tunnel.test.ts`. Rules and traps: `docs/internals/release-and-updates.md`.
- `packages/shared/package.json` — the `./productName`, `./homeDir` and
  `./desktopIdentity` exports.
- `apps/desktop/src/app/DesktopEnvironment.ts` — `userDataDirName` comes from
  `@t3tools/shared/desktopIdentity` (`infinitus-desktop` / `infinitus-desktop-dev`), plus the
  `adoptsLegacyUserDataDir` flag that gates upstream's legacy-directory rule.
- `apps/desktop/src/**` — the same rule and guard test, allowlisting the
  installed app's real `T3 Code (Alpha)`/`(Dev)` directory names and the KDE
  component name; `resolveDesktopAppBranding` titles every packaged build
  plain `PRODUCT_NAME` (no stage suffix) and keeps upstream's `(Dev)` and
  `(Nightly)` for a dev run and an upstream nightly (#823 layer 3); a fork
  nightly's stage label is `Nightly`, its title plain (#1042).
- `apps/desktop/src/app/DesktopAppIdentity.ts` — `resolveUserDataPath` returns
  the fork's directory without probing a legacy one unless the build adopts it
  (it never does), so an installed `T3 Code (Alpha)` is left alone.
- `apps/desktop/src/electron/ElectronProtocol.ts` — the production and
  development schemes come from `@t3tools/shared/desktopIdentity`; everything
  else (CSP, renderer origin, Clerk renderer, the Linux handler) follows
  `getDesktopScheme`.
- `apps/server/src/http.ts` — `DESKTOP_RENDERER_ORIGINS` built from the same
  two scheme constants.
- `scripts/build-desktop-artifact.ts` — the mac and Linux `protocols` blocks
  (name `Infinitus`, schemes `infinitus` / `infinitus-dev`);
  `resolveDesktopBuildIconAssets` / `resolveDesktopWebAssetBrand` return the
  `infinitus` artwork for fork versions; the Screen Recording usage text and
  the artifact's package `description` say `DESKTOP_PRODUCT_NAME`, and
  `stageDesktopDmgBackground` re-letters the stable DMG artwork ("Drag T3 Code
  into Applications") for the `infinitus` channel before rasterizing (#601).
- `infra/relay/src/db.ts`, `infra/relay/alchemy.run.ts`,
  `.github/workflows/deploy-relay.yml` — the relay's Postgres is a Neon
  project (`RelayNeonProject`, retained, `prod`; `RelayNeonBranch` on every
  other stage) in place of upstream's PlanetScale database, branch and
  runtime role (#1322: PlanetScale's cheapest cluster needs a card on file).
  Same shape, Neon's owner role, Hyperdrive on the project's direct origin.
  The workflow feeds `NEON_API_KEY` (repository secret) and `NEON_ORG_ID`
  (repository variable). The PlanetScale provider and env are gone: the
  deploy of #1366 dropped the two rows the first deploys had left `creating`
  in the state store (Alchemy dies on a persisted row whose provider is not
  registered, which is why they stayed for that one deploy).
- `packages/contracts/src/relay.ts`, `infra/relay/src/worker.ts` — the
  `infinitusAlert` group (`POST /v1/environments/:environmentId/alerts`,
  #1375) added to `RelayApi` beside upstream's server group, and its handler
  and publisher merged into the worker's API and runtime layers; the alert
  publisher gets the same FCM queue sender `FcmDeliveries` is given, hoisted
  into `fcmDeliveryQueueSenderLayer`. The runtime layer pipe has twenty
  stages, the most `pipe` takes: a new layer joins an existing stage.
- `infra/relay/src/agentActivity/apnsDeliveryJobs.ts`, `ApnsClient.ts`,
  `ApnsDeliveries.ts` — `ApnsNotificationPayload.threadId` is optional
  (#1375): an Infinitus account alert names no thread, so the request omits
  the key, the freshness recheck stands down and the attempt rows carry
  `null`. `FcmDeliveries.ts` — the queue job's optional `alert`
  (`FcmAlertData`): a ready-made alert with a null state, sent over the card
  the consumer computes anyway and never acknowledged as a card delivery.
- `infra/relay/scripts/deploy.ts` — the `AlchemyContext` the deploy runs
  under carries `updateStateStore: options.yes` beside `adopt` (#1322).
  Upstream forwards only `adopt`, so on a Cloudflare account with no Alchemy
  state store yet (ours; upstream's has had one for months) the CI deploy
  died at `Cloudflare State store not found … or pass --yes` although the
  workflow passes `--yes`. Alchemy's own `deploy --yes` sets the same field,
  and with it the first deploy bootstraps the store itself.
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
  the row's `options` drive the select.
- Upstream tests carrying the renderer origin or the userData directory
  (`DesktopAppIdentity`, `DesktopClerk`, `ElectronProtocol`, `DesktopWindow`,
  `DesktopLinuxUrlHandler`, `DesktopPreReadyPlatform`, `server.test.ts`,
  `build-desktop-artifact.test.ts`, and the web fixtures that stub a desktop
  origin) use the fork's scheme.
- `knip.jsonc` — `scripts/fork-visual-pass.mjs`, `fork-visual-fixture.mjs` and
  `fork-visual-check.ts` as scripts entries (run by hand and by the
  fork-visual-pass workflow; nothing imports them).
- `patches/expo-widgets@57.0.15.patch` — upstream's patch (#11604, system
  glass for Live Activities) plus the fork's hunk (#1277): `WidgetsModule.swift`
  observes `Activity<LiveActivityAttributes>.activityUpdates` and each
  activity's `activityStateUpdates` and emits `onExpoWidgetsActivityUpdate`
  `{activityId, name, state}` (`started`, then ActivityKit's own state names);
  `addActivityUpdateListener` and `ActivityUpdateEvent` on the JS side (src,
  build and index). One patch file per package version is pnpm's rule, so
  the two live together. Its one consumer, the thread-card bridge, left with
  #1375: drop the hunk (`pnpm patch` / `pnpm patch-commit`, the lockfile's
  `patch_hash` follows) the next time upstream bumps expo-widgets or
  rewrites its patch, rather than re-applying it.
- `apps/mobile/package.json` — `expo-audio` pinned exact (`57.0.4`, not
  upstream's `~57.0.4`): `scripts/release-smoke.ts` deletes the lockfile and
  resolves afresh, and once npm carried 57.0.5 the range resolved past the
  exact key of upstream's `patches/expo-audio@57.0.4.patch`, failing the
  Release Smoke job with `ERR_PNPM_UNUSED_PATCH`. Drop the pin when upstream
  bumps the package and its patch together.
- `apps/mobile/app.config.ts` — the `infinitus` app variant (bundle id
  `run.infinitus.mobile`, the Infinitus Apple team, the native phone's icon;
  `appleTeamId` per variant), selected with `APP_VARIANT=infinitus`; its
  `universalLinkHost` (`infinitus.run`, #724) adds `applinks:infinitus.run`
  to the iOS associated domains and `autoVerify` intent filters for
  `https://infinitus.run/pair` and `/join` (#1313) on Android (the site serves the AASA
  `applinks` for `Q783W6B4FA.run.infinitus.mobile` and `assetlinks.json`);
  `extra.productVersion` is the root `VERSION` (#823 layer 3), which
  `SettingsRouteScreen` shows in place of the store version.
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
  (Settings › Team, #1313; `team?code=…` is where an invite link lands).
- `apps/mobile/src/features/settings/components/settings-sheet-targets.ts` —
  `SettingsAccounts` and `SettingsTeam` in the settings target union.
- `apps/mobile/src/features/settings/SettingsRouteScreen.tsx` — the
  `SettingsInfinitusSection` (Accounts and Team rows, the reset alarms
  toggle, sending mode) after General.
- `apps/mobile/src/App.tsx` — `appLinking`'s universal pair-link rewrite (`features/connection/universalPairLink.logic.ts`, #724, #746), the team invite-link rewrite (`features/team/team.logic.ts`, #1313: `infinitus.run/join#<code>` → `team?code=`) and the mounted bridges: `InfinitusAlarmsBridge`, `InfinitusNotificationPresenter`, `InfinitusHoldsBridge` (#1278). Rules and traps: `docs/internals/phone-app-bridges.md`.
- `apps/mobile/src/persistence/mobile-preferences.ts` — the
  `infinitusAlarmsEnabled` / `infinitusPinAtCreation` (#742) /
  `infinitusComposerSendMode` (#807, `"queue" | "steer"`) keys (interface
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
- `apps/mobile/src/features/threads/ThreadDetailScreen.tsx` — the fork's slots (`infinitusReconnectingNotice` #832, `infinitusHoldBanner` #742, `infinitusQueuedTurns` #806, `infinitusBestOfCard` #269 B, `infinitusTurnFooters` #952) and the thread header menu (`useThreadHeaderMenu`, #941; `usePullRequestHeaderItem`, #269 F), built in `ThreadRouteScreen.tsx`. Rules and traps: `docs/internals/phone-thread-screen.md`.
- `apps/mobile/src/features/threads/ThreadFeed.tsx` — the optional `infinitusMessageMenu` prop (revert to a message the user sent; `useRevertMessageMenu` + `revertMessage.logic.ts`, `restoreAttachments.ts`). Rules and traps: `docs/internals/phone-thread-screen.md`.
- `apps/mobile/src/features/threads/thread-list-v2-items.tsx` — an idle
  active row whose current linked PR is open, out of draft, with green (or
  no) checks and no verdict reads "Ready for review" in place of its time
  (`useThreadReadyForReview`, #269 F); settled rows keep their stamp. A
  babysat idle row reads "Babysitting r/10" ahead of that (`babysitLabel`,
  #269 A).
- `apps/mobile/src/features/threads/threadListV2.ts`,
  `thread-list-v2-items.tsx`, `threadPresentation.ts` — the `Monitoring`
  status the phone was dropping: the server ships `backgroundLiveness` on
  every thread shell and upstream's web sidebar reads it
  (`resolveSidebarThreadStatus`, `resolveThreadStatusPill`), but both mobile
  resolvers stopped at the session row, so a thread whose turn settled while
  watch loops ran read as a plain timestamp. Both now end in the web's two
  branches (working fleets, then monitoring watch loops) after the failed
  check, each taking its own web counterpart's treatment: the v2 list label
  is full-strength and hueless like `Sidebar.tsx`'s, the v1 row's pill keeps
  Working's hue like `resolveThreadStatusPill`'s, and neither pulses —
  monitoring is background presence, not progress. A babysat row still
  labels ahead of it, since `babysitLabel` says the same thing with the
  round count.
- `apps/mobile/src/state/entities.ts` — `useThreadShells` drops side
  questions (`sideOf != null`, #269 C) and `useThreadShell` answers null for
  one, so a side question is in no phone list and never opens as a page;
  `apps/mobile/src/features/archive/ArchivedThreadsRouteScreen.tsx` filters
  the archived snapshots the same way (`features/infinitus/sideQuestions.ts`,
  #863).
- `apps/mobile/src/features/threads/ThreadRouteScreen.tsx` — a side question
  from the phone (#269 C, #881): `useSideQuestionHeaderItem`'s `action` is
  the thread menu's "Ask a side question" (above, #941) on a Claude Agent
  thread of an `infinitus` server; a tap forks the session's latest completed turn (`infinitus.forkThread`
  with `side: true`, no `turnCount`, #887) and opens `SideQuestionSheet`
  (`apps/mobile/src/Stack.tsx`, a form sheet in `WORKSPACE_OVERLAY_ROUTES`,
  no link): `apps/mobile/src/features/infinitus/InfinitusSideQuestionSheet.tsx`
  subscribes to the side fork, asks in plan mode, and "Bring to main" appends
  the latest answer to the main composer's draft (`sideQuestions.ts` carries
  the web `SideQuestionPanel.logic.ts` helpers, kept local).
- `apps/mobile/src/features/threads/ThreadRouteScreen.tsx` — the thread's
  usage from the phone (#834): `useThreadUsageHeaderItem`'s `action` is the
  thread menu's "Thread usage" (above, #941) once the shell carries `usage`
  (a turn was recorded; no choice before, and none on a server without the
  rollup); a tap opens `ThreadUsageSheet`
  (`apps/mobile/src/Stack.tsx`, a form sheet in `WORKSPACE_OVERLAY_ROUTES`,
  no link): `apps/mobile/src/features/infinitus/InfinitusThreadUsageSheet.tsx`
  reads the live shell's rollup and draws `threadUsage.logic.ts`'s rows —
  worded like the web popover (#907): turns (with the subagent count), tool
  calls and duration when the server counted them (#927), each non-zero
  token share, model(s), cost ("Cost not recorded" for null, never $0.00),
  last turn — every estimate prefixed "≈", and the caveat lines under them.
- `apps/mobile/src/features/threads/NewTaskDraftScreen.tsx` (`InfinitusPinAtCreationControl`, #742), `apps/mobile/src/state/use-thread-outbox-drain.ts` (+ test) — `usePinAtCreation` after a delivered creation, `threadsByKey` (#1278), `queueBehindRunningTurn` around both `resolveThreadOutboxDeliveryAction` calls (#807) and its `thread.turn.queue` form on a `turnQueue` server (#812: `sendQueuedMessage` `via`, `completeQueuedMessageDelivery` `retainInFeed`). Rules and traps: `docs/internals/phone-outbox-drain.md`.
- `apps/mobile/src/features/home/HomeScreen.tsx` — the thread list's header:
  `InfinitusSignIns` (lapsed AWS / gcloud sign-ins of paired Macs).
- `apps/mobile/src/features/home/HomeHeader.tsx` — the header's
  brand slot (and `components/CompactBrandTitle.tsx`, the iOS one) shows
  `PRODUCT_NAME` where upstream draws the T3 glyph + "Code" (#601).
- `apps/mobile/src/features/review/shikiReviewHighlighter.ts`,
  `apps/mobile/src/features/diffs/nativeReviewDiffHighlighter.ts` — an
  explicit `tokenizeTimeLimit` (5 s) on both `codeToTokensBase` calls: shiki's
  500 ms default is spent by a cold JavaScript regex engine compiling its
  patterns, which fused the first line into one token on loaded CI (#610).
- `apps/web/src/components/settings/settingsSearch.ts` — the eight Infinitus
  `SettingsPath`s and their labels (Themes and Animations since #747 step 1,
  Priority since #743, Lock since #747 step 3), the `infinitusOnly` search flag with the
  `hasInfinitusEnvironment` availability it reads, and
  `isSettingsSectionActive` so a nested page's nav item is the only one lit.
- `apps/web/src/lib/infinitusNotifications.logic.ts`, `apps/web/src/components/desktop/DesktopBadgeCoordinator.tsx`, `apps/web/src/components/desktop/NotificationModeMigration.tsx`, `apps/web/src/components/settings/DesktopBadgeSettings.tsx`, `apps/desktop/src/electron/ElectronNotification.ts`, `apps/desktop/src/ipc/methods/notifications.ts`, and one block in upstream's `ThreadNotificationCoordinator.tsx` — what the fork layers on upstream's thread notifications (#11481, ruling #1032): held / limited banners, `quietForViewer`, the queue rule, the Dock badge, the one-time mode migration. Rules and traps: `docs/internals/notifications.md`.
- `apps/web/src/components/settings/SettingsSidebarNav.tsx` — an icon per
  Infinitus path and the capability filter that hides all eight where no
  connected server reaches an Infinitus app.
- `apps/web/src/components/settings/useAvailableSettingsSearchItems.ts` —
  fills `hasInfinitusEnvironment` from the environments' capabilities.
- `apps/web/src/components/settings/settingsSearch.test.ts` — the availability
  records it builds gained that field.
- `apps/web/src/routes/pair.tsx` — one early return: a link with the phone
  marker (`isPhonePairingLink`, #724) renders `InfinitusPhoneLinkSurface`
  instead of the pairing form, so the browser does not spend a phone's token.
- `apps/web/src/routes/settings.infinitus*.tsx` (eight new files in upstream's
  routes directory; Themes and Animations are `InfinitusPrefsPanel` pages over
  the catalog's `themes` / `animations` sections, #747 step 1, and Priority
  over its `priority` section (#743: `priority_mode` with the `interrupt`
  choice, `priority_low_pct`, `priority_abundant_pct`, copy in `PREF_COPY`,
  the mode row labelled "Thread priority" since #1069) —
  the Menu bar page keeps `display` + `about`; the Priority page reads the
  catalog's `priority` section and, on a build before that rename,
  `sessions`; a section the build lacks
  renders "no … settings yet"; Lock is `InfinitusLockPanel`, #747 step 3)
  and
  `apps/web/src/routeTree.gen.ts` — regenerated with
  `@tanstack/router-generator`, never edited by hand.
- `apps/web/src/routeTree.gen.ts` — regenerated (with the installed
  `@tanstack/router-generator`, never hand-edited) whenever a fork route is
  added; the upstream sync re-generates it.
- `apps/web/src/components/sidebar/SidebarChrome.tsx` — the Accounts utility
  item and its `infinitus` capability gate, and `/accounts`
  in the `currentFooterPage` selector (so the Back button appears on the page).
- `packages/contracts/src/keybindings.ts` — `accounts.open` in
  `STATIC_KEYBINDING_COMMANDS`.
- `apps/web/src/components/CommandPalette.tsx` — the "Open accounts" action and
  the `keydown` listener that turns `accounts.open` into a navigation, both
  behind the `infinitus` capability.
- `scripts/install.sh`, `scripts/install.ps1` — `repo` is this repository and
  the home `~/.infinitus`, the same flip as `CLI_RELEASE_REPOSITORY` (#1192);
  the shell script installs on Linux only and says plainly that no macOS or
  Windows archive exists (exit 1 before any fetch, never upstream's), resolves
  only the release train (a `v…` tag without a nightly/preview suffix — the
  fork's nightly is the rolling tag and ships no archive), and is served at
  `https://infinitus.run/install.sh` as the checked-in copy
  `apps/mac/site/public/install.sh`: `scripts/sync-install-script.ts` writes
  it, `--check` and its test fail on drift, and the test fails while the
  source names upstream's owner. The PowerShell script stops at once (no
  Windows archive) and is not served. Regenerate the copy after any edit; the
  site deploy is by hand from `apps/mac/site`.
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
  section appended at the end (#1178): Settings › Infinitus › Devices, the
  push key and the registered phones, and the lock-screen thread card with
  its phone Settings rows (#1265). Upstream's text above it says Infinitus
  Connect (#1368) and is otherwise untouched.
- **The project file is `infinitus.json`** (#823 layer 1): `packages/contracts/src/t3ProjectFile.ts` (`T3_PROJECT_FILE_NAME`, `LEGACY_T3_PROJECT_FILE_NAME`, `T3_PROJECT_FILE_NAMES`, `T3_PROJECT_FILE_SCHEMA_URL`), the four read sites (`T3ProjectFileLoader.ts`, `useT3ProjectFileScripts.ts`, `t3ProjectFileDefaults.ts`, `new-task-flow-provider.tsx`), the copy, `scripts/build-project-file-schema.ts` → `apps/mac/site/public/schema/infinitus.json`, the repository's own `infinitus.json`. Rules and traps: `docs/internals/project-file.md`.
- `.github/workflows/ci.yml` — `runs-on` swapped from Blacksmith runners to
  GitHub-hosted ones, timeouts widened, `workflow_dispatch:` added so the
  upstream-sync workflow can start CI on its branch. The sync workflow
  re-applies the runner swap after every merge. It pushes with the
  `UPSTREAM_SYNC_TOKEN` secret when present (a fine-grained PAT: contents,
  workflows, pull requests — write), since the default token cannot push a
  branch that touches `.github/workflows` (#658); without it such a sync
  is done by hand.
- Upstream workflows that deploy or publish (Release, Forward to Cursor
  hygiene, Mobile EAS Preview/Production, Publish AUR, Issue Labels, Desktop
  macOS Preview, Web Preview, Mobile Showcase Screenshots, Thread Transfer
  Report, Desktop macOS Preview Publish — new with the 0310cbf9 sync,
  `pull_request_target` on close/unlabel) are disabled in the repository's
  Actions settings, not deleted, so merges stay clean. Upstream's Deploy T3
  Connect relay (`deploy-relay.yml`) is the exception since #1322
  (2026-09-16): enabled unchanged, it deploys `infra/relay` as the
  Infinitus relay (`relay.infinitus.run`, the `production` environment's
  vars and secrets) on every push to `main`, and
  `infinitus-release.yml`'s `connect` job reads that environment so builds
  carry the relay's Clerk config.
