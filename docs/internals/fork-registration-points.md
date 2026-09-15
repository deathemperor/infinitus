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
- `packages/contracts/src/git.ts`, `apps/server/src/vcs/GitVcsDriverCore.ts`,
  `apps/web/src/hooks/useThreadActions.ts` — worktree cleanup and seeding
  (#270 A). `VcsRemoveWorktreeInput` gains `keepWork` (commit whatever the
  worktree holds uncommitted to its branch, `wip: work saved when the thread
was deleted`, before the forced remove) and `deleteBranch` (`git branch -D`
  after the remove, skipped whenever `keepWork` had to commit: that commit
  is the work's only copy), and answers `VcsRemoveWorktreeResult`
  `{branch, savedWorkCommit, branchDeleted}`. The thread delete flow always
  sends `keepWork`, asks "Also delete branch …?" as a second confirm (off by
  default, like Conductor's delete-branch-on-archive) when the thread has a
  branch, and toasts the saved commit. `createWorktree` seeds the new tree
  with the parent's untracked files that `.worktreeinclude` at the project
  root names (gitignore syntax, matched by `git ls-files --others --ignored
--exclude-from`), or `.env*` when the file is absent; best-effort, logged,
  never rolls back the worktree, and runs before the setup script.
- `packages/contracts/src/environmentHttp.ts` — `EnvironmentHttpApi` adds
  `InfinitusPairingHttpApi`: the phone's two unauthenticated pairing-approval
  routes (#710), so the typed HTTP clients carry them.
- `packages/contracts/package.json` — the `./infinitus`,
  `./infinitusPairing` and `./captures` subpath exports.
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
  `RuntimeDependenciesLive`. `InfinitusResumeOnLimitLive` in `ReactorLayerLive`
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
- Bash description as the row's headline (#1231):
  `apps/server/src/orchestration/ActivityPayloadProjection.ts` — the
  client-bound projection rebuilds a tool row's `data` and drops `input`
  whole, so for `command_execution` it now carries `data.description`
  (Claude's Bash `input.description`, trimmed) beside `data.command`;
  `apps/web/src/session-logic.ts` — `WorkLogEntry.commandDescription` from
  it, merged forward like `command` (the started row can arrive before the
  input finished streaming); `apps/web/src/components/chat/MessagesTimeline.logic.ts`
  — `workEntryDisplayLabel`, `singleToolCallLabel` and `liveWorkEntryLabel`
  prefer it over the command, and `buildToolCallExpandedBody` (unchanged)
  then adds the command as the expanded row's first block, since it differs
  from the visible label. Rows without a description are as before.
  `apps/mobile/src/lib/threadActivity.ts` (an upstream file) mirrors it:
  `WorkLogEntry.commandDescription` derived from `data.description` on a
  `command_execution` row (whitespace collapsed), merged forward in
  `mergeDerivedWorkLogEntries`, and preferred over the command in
  `workEntryRowLabel` (compact and expanded), `singleToolCallLabel` and
  `liveToolActivitySummary`; the expanded body already leads with the
  command block.
- Turn footer (#952): `packages/client-runtime/src/turnFooter.ts` (+ test; `turnFooter`, `turnFooterLabel`, exported as `@t3tools/client-runtime/turnFooter`), `apps/server/src/provider/Layers/ClaudeAdapter.ts` (`is_backgrounded` → `TaskStartedPayload.isBackgrounded` in `packages/contracts/src/providerRuntime.ts`, passed through by `ProviderRuntimeIngestion.ts`; `liveBackgroundAgentsMessage`, #974), `apps/server/src/infinitus/Layers/BackgroundAgentsReconcile.ts` (+ test; `infinitus/backgroundAgents.logic.ts`; the `background-agents.reconcile` phase in `serverRuntimeStartup.ts`, #977), `apps/web/src/components/chat/useTurnFooters.ts`, `MessagesTimeline.tsx` (`turnFooters`, `AssistantMessageMeta`), `ChatView.tsx`. Rules and traps: `docs/internals/turn-footer.md`.
- Server-side message queue (#806, the server half of #270 F): `packages/contracts/src/baseSchemas.ts` (`QueueId`), `packages/contracts/src/orchestration.ts` (`OrchestrationQueuedTurn`, `queuedTurns?`, `thread.turn.queue` / `.queue.update` / `.queue.remove` / `.queue.move`, `queuedFrom?`, `thread.turn-queued` / `-queue-updated` / `-queue-removed` / `-queue-moved`), `packages/shared/src/orderKeys.ts`, `apps/server/src/orchestration/decider.ts`, `projector.ts`, `Schemas.ts`, `packages/client-runtime` `threadReducer.ts`, `Layers/ProjectionPipeline.ts` (`projection_thread_queued_turns`, migrations `051`, `059`, `062` (`send_at`, #1318); `persistence/ProjectionThreadQueuedTurns.ts`), `Layers/ProjectionSnapshotQuery.ts`, `Normalizer.ts`, `apps/server/src/server.ts` (`InfinitusTurnQueueLive`), `Services/InfinitusSessionInterrupt.ts` (`paused`); fork-only `apps/server/src/infinitus/Layers/InfinitusTurnQueue.ts` (+ `infinitusTurnQueue.logic.ts`, `queueDrainVerdict`). Rules and traps: `docs/internals/turn-queue.md`.
- Update idle gate (#829): `packages/contracts/src/server.ts` (`ServerRunningTurn`, `ServerUpdateRunningTurnsPolicy`, `runningTurns?` on `ServerSelfUpdateInput` and `ServerSelfUpdateError`, the `waiting` progress stage), `packages/contracts/src/environmentHttp.ts` (`GET /api/infinitus/running-turns`), `apps/server/src/infinitus/Services/InfinitusRunningTurns.ts` + `Layers/InfinitusRunningTurns.ts` (served by `Layers/InfinitusHttp.ts`), `apps/server/src/cloud/selfUpdate.ts` (`awaitIdle`, `commitDesktopUpdate`), `ws.ts`, `server.ts`; `packages/client-runtime/src/state/server.ts`, `apps/web/src/components/ServerUpdateAction.tsx`, `apps/web/src/components/desktopUpdate.logic.ts` (`countRunningLocalTurns`), `sidebar/SidebarUpdatePill.tsx`, `sidebar/DesktopUpdateRunningTurnsDialog.tsx`, `state/desktopUpdate.ts` (`desktopInstallWhenIdleAtom`). Rules and traps: `docs/internals/update-idle-gate.md`.
- Babysit (#269 A, on the #806 queue): `packages/contracts/src/orchestration.ts` (`ThreadBabysit`, `BABYSIT_MAX_ROUNDS`, `babysit?`, `thread.meta.update`'s `babysit?` / `babysitRounds?`, `thread.meta-updated`'s `babysit?`), `apps/server/src/orchestration/decider.ts` (`babysitPatch`), `projector.ts`, `packages/client-runtime/src/state/threadReducer.ts`, `Migrations/052_ProjectionThreadsBabysit.ts` (`projection_threads.babysit_json`; `Layers/ProjectionThreads.ts`, `ProjectionPipeline.ts`, `ProjectionSnapshotQuery.ts`), `PullRequestSyncReactor.ts` (`requestedSync`), `collectNeedsAttention`; fork-only `apps/server/src/infinitus/Layers/infinitusBabysit.logic.ts` (`babysitVerdict`, `settleBabysitMarks`, `seedBabysitMarks`, `babysitPrompt`), `InfinitusBabysit.ts` (`InfinitusBabysitLive`), `apps/web/src/components/ThreadBabysitToggle.tsx` (shown by `BranchToolbarBranchSelector.tsx`). Rules and traps: `docs/internals/babysit.md`.
- Turn usage (#834): `packages/contracts/src/orchestration.ts` (`ThreadTurnUsage`, `ThreadUsageRollup`, `usage?`, `thread.turn.usage.record`, `thread.turn-usage-recorded`, `thread.usage.backfill`, `thread.usage-backfilled`), `packages/shared/src/threadUsage.ts`, `packages/contracts/src/providerRuntime.ts` (`turnCostUsd?`, `turnModels?`), `apps/server/src/provider/Layers/ClaudeAdapter.ts` (+ `claudeTurnUsage.logic.ts`), `Layers/ProviderRuntimeIngestion.ts` (+ `orchestration/threadTurnUsage.ts`), `decider.ts`, `projector.ts`, `Schemas.ts`, `threadReducer.ts`, `persistence/ProjectionTurnUsage.ts` (migrations `056`, `057`), `Layers/ProjectionPipeline.ts`, `ProjectionThreads.ts`, `ProjectionSnapshotQuery.ts`, `orchestration/Layers/ThreadUsageBackfill.ts` (+ `threadUsageBackfill.logic.ts`; `ThreadUsageBackfillLive` in `server.ts`), `apps/web/src/components/chat/ThreadUsagePopover.tsx` (+ `threadUsage.logic.ts`), `ChatHeader.tsx`'s `usage` prop from `ChatView.tsx`; `apps/server/src/usage/UsageService.ts` (`readSessionUsage`), and the upstream tests `ProviderRuntimeIngestion.test.ts`, `threadReducer.test.ts`, `UsageService.test.ts`. Rules and traps: `docs/internals/turn-usage.md`.
- Side question (#269 C): `packages/contracts/src/orchestration.ts` (`sideOf?` on `thread.create`, `thread.created`, `OrchestrationThread`, `OrchestrationThreadShell`; column `side_of`, `Migrations/053_ProjectionThreadsSideOf.ts`; decider, projector, `threadReducer.ts`, `ProjectionThreads`, `ProjectionPipeline.ts`, `ProjectionSnapshotQuery.ts`), `packages/contracts/src/infinitus.ts` (`InfinitusThreadForkInput.side?`), `apps/server/src/infinitus/ThreadFork.ts` (`forkCreateFields`, `latestClaudeSessionEnd`); `apps/web/src/rightPanelStore.ts` (`side-question`, `openSideQuestion`, `openSideQuestionPending`, `failSideQuestionPending`), `apps/web/src/components/SideQuestionPanel.tsx` (+ `SideQuestionPanel.logic.ts`: `isSideQuestionMessage`, `isSideQuestionGone`), `ChatView.tsx` (`askSideQuestion`, `cleanupRightPanelSurfaces`), `ChatComposer.tsx` (`ComposerFooterModeControls`), `CompactComposerControlsMenu.tsx`, `Sidebar.tsx`, `CommandPalette.tsx`, `getLatestThreadForProject`, Settings › Archived. Rules and traps: `docs/internals/side-question.md`.
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
  patch (#270 F); `settings.test.ts` covers the default.
- Queue vs steer (#270 F; the queue lives on the server since #806):
  `apps/web/src/composer-logic.ts` — `ComposerSubmissionIntent` has `queue`
  and `composerSendModeForEnter` (⌘↩ on a non-draft thread flips the mode;
  drafts keep ⌘↩ = background); `ChatComposer.tsx` — `submitComposer`
  resolves the intent to `queue` while `phase === "running"` (never for a
  question or approval answer) and hands it to `ChatView.onSend`, which runs
  the usual preflight and uploads then dispatches `thread.turn.queue`
  instead of `thread.turn.start` (no optimistic row, no local dispatch, no
  title step; runtime/interaction mode still persist so the drain reads
  them); `components/chat/useQueuedTurnActions.ts` — the rows from
  `thread.queuedTurns` and their actions (send now = `thread.turn.start`
  with `queuedFrom`; edit = `.queue.remove`, then for a row with context
  records (#969) the composer's `importContextRecords` from this
  environment — the stash restore's path, chips back and attachments
  transferred by id — and the text with its links rewritten to the
  re-minted ids (`restoredQueuedTurnText`, #971); a row without records
  has its attachments fetched back through the asset URL first, then text
  and files into the composer; move = `.queue.move` with
  `queuedTurnMoveKey`; remove); `ComposerSendQueue.tsx`
  renders them; `composerSendQueue.logic.ts` (+ test) — `orderedQueuedTurns`,
  `queuedTurnSnippet`, `queuedTurnEditableText`, `restoredQueuedTurnText`,
  `queuedTurnMoveKey`, and the legacy-stash helpers; `hooks/useLegacyQueueMigration.ts` (mounted in
  `routes/_chat.tsx`) — moves entries the stash still holds with `queuedFor`
  (#270 F, pre-#806) to the server once, ids derived from the entry, a
  refused one becoming a plain stash entry (`promptStashStore.unqueueEntry`);
  `ComposerPrimaryActions.tsx` — `runningSendMode` keeps the send button
  beside Stop while running, labelled "Queue message" / "Send at next step"
  (#1318: steer mode queues the message with `sendAt: "tool-boundary"`, the
  intent `steer`, and the drain sends it at the running turn's next finished
  tool call — `docs/internals/turn-queue.md`; `queuedTurnTiming` labels the
  row "at next step" on the web and the phone, `queuedTurnsHeader` words
  the list's header) (upstream
  shows its own "Queue message" there since #11673, so the fork's prop only
  changes the steer label); `ChatView.tsx` `onSend` — upstream's client-side
  queue (#11673, `queuedMessageStore.ts`: a mid-turn send parked in memory
  until the next tool boundary, drawn as a dashed bubble at the end of the
  timeline, returned to the composer by Stop) is gated off on a server thread
  (`!isServerThread` at its enqueue), where this setting decides: `queue`
  dispatches `thread.turn.queue`, `steer` sends into the running turn at
  once — one row, never two; the store, its timeline rows and the Stop drain
  stay compiled and idle, and `docs/user/composer.md`'s "Send while the
  agent is working" section is rewritten to the fork's rule at every sync;
  `SettingsPanels.tsx` + `settingsSearch.ts` — the "Sending while a turn
  runs" row. Client-runtime: `operations/commands.ts` + `state/threadCommands.ts`
  — `queueTurn` / `updateQueuedTurn` / `removeQueuedTurn` / `moveQueuedTurn`.
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
- `apps/mobile/src/connection/platform.ts` — the wakeups layer merges
  `requestedConnectionWakeups` from
  `apps/mobile/src/features/infinitus/connectionWakeups.ts` (#1277): a
  fork feature can ask for the `application-active-reconnect` wakeup the
  foreground sends, so the thread-card bridge brings the Mac's socket up in
  the background window a push-to-start grants. One `Stream.merge` line.
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
  GNOME extension's shipped name). Comments, "T3 Connect" and the
  `t3code/<version>` UA token stay (#601 slice A).
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
  the two live together; re-apply the fork's hunk with `pnpm patch` /
  `pnpm patch-commit` when upstream bumps expo-widgets or rewrites its patch
  (the lockfile's `patch_hash` follows). The thread-card bridge is its one
  consumer.
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
  to the iOS associated domains and an `autoVerify` intent filter for
  `https://infinitus.run/pair` on Android (the site serves the AASA
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
  Accounts, the Infinitus fleet per paired Mac).
- `apps/mobile/src/features/settings/components/settings-sheet-targets.ts` —
  `SettingsAccounts` in the settings target union.
- `apps/mobile/src/features/settings/SettingsRouteScreen.tsx` — the
  `SettingsInfinitusSection` (Accounts row, Mac alerts / thread card (with
  its test card, #1047) / reset alarms toggles, sending mode, the alerting
  Mac) after General.
- `apps/mobile/src/App.tsx` — `appLinking` rewrites an incoming universal
  link `https://infinitus.run/pair#token=…&for=phone&to=<origin>` into the
  `environment-new?pairingUrl=<origin>/pair#…` route (`getInitialURL` /
  `subscribe`, `features/connection/universalPairLink.logic.ts`, #724): the
  Mac's origin travels in the fragment the site never sees, `to` is taken as
  a bare http(s) origin only, and the sheet fills Host and code like a
  scanned QR (#746) — the same rewrite runs on the in-app scanner's payload
  and on the route's `pairingUrl`. Mounts `InfinitusAlarmsBridge`
  (local reset / swap alarms), `InfinitusAlertPushBridge` (the `alert`
  token, so the Mac's pushes reach the phone as banners; it withdraws the
  kind with `activities-token --forget <deviceId>/<kind>` through
  `pushForget.ts` / `pushForget.logic.ts` when its switch goes off, #702),
  `InfinitusThreadCardBridge` (the lock-screen thread card's tokens, #1047:
  the push-to-start token as `agent-activity-start` and each running
  `AgentActivity` card's own token as `agent-activity`, re-read on every
  foreground and after a local start; both withdrawn the same way when the
  switch goes off) and `InfinitusNotificationPresenter` (the app's one
  foreground notification handler: Infinitus notifications show as banners
  in-app, T3's keep the no-handler default), and `InfinitusHoldsBridge` (#1278 finding 7: one
  `subscribeInfinitusHolds` subscription per Infinitus Mac for the app's
  lifetime, so the outbox drain's registry read of the holds atom sees a
  delivered list instead of mounting the stream itself and reading null on
  the first queued message).
- `apps/mobile/src/persistence/mobile-preferences.ts` — the
  `infinitusLiveActivityMac` (the Mac the alerts come from) /
  `infinitusAlarmsEnabled` / `infinitusPushAlertsEnabled` /
  `infinitusThreadCardEnabled` (#1047, absent reads on) /
  `infinitusPinAtCreation` (#742) / `infinitusComposerSendMode` (#807,
  `"queue" | "steer"`) keys (interface and sanitizer).
- `apps/mobile/src/features/threads/ThreadDetailScreen.tsx` — the optional
  `infinitusReconnectingNotice` slot above the hold banner (#832: "Waiting
  for the network. Reconnect attempt n of 5." while the session's
  `statusReason` reads `reconnecting:<n>/<max>` on a running session;
  `apps/mobile/src/features/infinitus/InfinitusReconnectingNotice.tsx` +
  `reconnecting.logic.ts`, the web helper's copy; `ThreadRouteScreen.tsx`
  builds it from the thread shell's session, and
  `thread-list-v2-items.tsx` labels such a working row "Reconnecting n/max"
  in amber instead of "Working"), the optional
  `infinitusHoldBanner` slot (a `ReactNode` in the composer stack after the
  feedback notices, #742) and the `infinitusQueuedTurns` slot right after it
  (#806: the thread's server-side queue as a card — one row per queued
  message with earlier/later, edit, send now, remove;
  `apps/mobile/src/features/infinitus/InfinitusQueuedTurns.tsx`,
  `useQueuedTurnActions.ts`, `queuedTurns.logic.ts` — the phone's copy of
  the web's `composerSendQueue.logic.ts`, kept local so neither app edits
  the other's file; edit puts the row's context records back with fresh ids
  through `restoredQueuedTurn` + `insertComposerDraftContext`, #971, the
  text alone when the draft's record cap refuses); `apps/mobile/src/features/threads/ThreadRouteScreen.tsx`
  builds `InfinitusHoldBanner` from the thread's detail for it (never for a
  queued creation), `InfinitusQueuedTurns` from the thread shell's
  `queuedTurns`, `InfinitusBestOfCard` (#269 B, read-only: the group's live
  siblings from the shells by `groupId`, `features/infinitus/bestOf.logic.ts`
  carrying the web `bestOf.logic.ts` sibling and status helpers kept local;
  no "Keep this one", which removes worktrees) for the `infinitusBestOfCard`
  slot first in the composer stack, `useTurnFooters(selectedThreadDetail)`
  (#952, `features/infinitus/useTurnFooters.ts`, the web hook kept local)
  for `infinitusTurnFooters`, which `ThreadDetailScreen.tsx` hands
  `ThreadFeed.tsx`'s `turnFooters` so a completed turn's terminal assistant
  message shows `turnFooterLabel` — "Done in 49s · 12:59 PM · 1 shell still
  running", the time in the feed's own `formatMessageTime` — in place of its
  time, and prepends the thread menu — `useThreadHeaderMenu`
  (`features/infinitus/useThreadHeaderMenu.ts` + `threadHeaderMenu.logic.ts`,
  #941: ONE menu button folding the PR's choices, "Ask a side question" and
  "Thread usage", so the compact iOS header keeps upstream's three git
  buttons instead of collapsing everything into "…"; the PR's icon and "#N"
  on the button while the thread has one, else the plain more circle) — to
  the iOS header's git items with its `version` in `optionsVersion`. The
  PR part is `usePullRequestHeaderItem`'s `menu` (#269 F: the PR's phase
  from the linked snapshot as an inert first line, Open pull request / View
  checks / Mark ready for review over `pullRequests.runAction`, and on an
  `infinitus` server "Babysit" / "Stop babysitting (r/10)" over
  `thread.meta.update {babysit}` while the PR is open or the thread is
  already babysat — the web toggle's gate, #269 A, the status line reading
  "Babysitting r/10" while on); on Android the hook's `androidAction` is a
  header button before the git controls opening the same choices as an
  anchored menu; `apps/mobile/src/features/infinitus/prHeader.logic.ts`,
  `pullRequestActions.ts`).
- `apps/mobile/src/features/threads/ThreadFeed.tsx` — the optional
  `infinitusMessageMenu` prop (#269 item 13 / #270 item 5: revert to a
  message the user sent), threaded into `renderFeedEntry` and its deps: a
  committed user message the callback names gets its bubble wrapped in a
  `ControlPillMenu` on long-press — the bubble becomes a `Pressable`, since the
  menu injects its press handlers into its child and a plain `View` drops
  them; a pending message and a message with no checkpoint render as before.
  `ThreadDetailScreen.tsx` passes the prop through beside the turn footers;
  `ThreadRouteScreen.tsx` builds it with `useRevertMessageMenu`
  (`features/infinitus/useRevertMessageMenu.ts` + `revertMessage.logic.ts`,
  the web's `buildRevertTurnCountByUserMessageId` kept local: the checkpoint
  before the turn a message started, from `detail.checkpoints` by
  `assistantMessageId`, whatever the status, so both surfaces name the same
  turn). The web menu's four modes, on an `infinitus` server, each behind
  the web's confirm: "Edit from here" (`thread.checkpoint.revert`, files and
  chat) and "Rewind chat only" (the same with `restoreFiles: false`, #270 E1)
  — both only where the thread's provider snapshot does not say
  `supportsConversationRollback: false`, the web's gate — hand the message
  back to the thread's composer draft: the attachments are downloaded FIRST
  (`restoreAttachments.ts` `downloadDraftAttachments`, the loop the queue's
  "Edit" in `useQueuedTurnActions.ts` also runs, since the server prunes a
  reverted message's uploads, #847), then the revert, then text
  (`revertedMessageEditableText`: the effort prefix and trailing review
  comments off, the phone's cut of the web's `recallableComposerPrompt`),
  files and context records under fresh ids (`restoredRevertedMessage`, the
  queue's #971 path; the text alone over the draft's record cap) land in the
  draft. "Restore files only" (`keepChat`, #269 E) leaves the chat; on a
  Claude Agent or Codex thread "Fork a new thread from here"
  (`infinitus.forkThread` at that `turnCount`, #270 E2) opens the new thread.
  A running or starting session gets the web's "Interrupt the current turn"
  alert.
- `apps/mobile/src/features/threads/thread-list-v2-items.tsx` — an idle
  active row whose current linked PR is open, out of draft, with green (or
  no) checks and no verdict reads "Ready for review" in place of its time
  (`useThreadReadyForReview`, #269 F); settled rows keep their stamp. A
  babysat idle row reads "Babysitting r/10" ahead of that (`babysitLabel`,
  #269 A).
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
- `apps/mobile/src/features/threads/NewTaskDraftScreen.tsx` — mounts
  `InfinitusPinAtCreationControl` after the Plan/Build pill in the composer's
  control row (#742); `apps/mobile/src/state/use-thread-outbox-drain.ts` —
  `usePinAtCreation` runs once a queued creation is delivered, right after the
  "delivered" outcome is recorded (its test, `use-thread-outbox-drain.test.ts`,
  mocks `./preferences` so the drain's module graph stays clear of
  expo-secure-store). `threadsByKey` (a Map over the shells, #1278 finding 6) is the pass's
  thread lookup; the live re-check keeps `findThread` over the registry's
  array. The two `resolveThreadOutboxDeliveryAction` calls (the
  pass and the live re-check before a send) are wrapped in
  `queueBehindRunningTurn` (#807): an existing thread's follow-up waits while
  its turn runs or the server holds it, the phone's copy of the desktop
  composer's queue (#270 F); the test mocks `./threadOutboxHolds` too. Since
  #812 that wait becomes a `thread.turn.queue` when the server advertises
  `turnQueue` (`resolveThreadOutboxDelivery`, `queueTurnCommandInput`):
  `sendQueuedMessage` takes `via: "start" | "queue"` and, for a queue, sends
  `threadEnvironment.queueTurn` with the outbox's command id and a fresh
  queue id after the same settings sync and uploads, and
  `completeQueuedMessageDelivery` takes `{ retainInFeed: false }` so no
  "Pending" feed row waits for an echo the timeline only gives at drain.
- `apps/mobile/src/features/home/HomeScreen.tsx` — the thread list's header:
  `InfinitusSignIns` (lapsed AWS / gcloud sign-ins of paired Macs).
- `apps/mobile/src/features/home/HomeHeader.tsx` — the header's
  brand slot (and `components/CompactBrandTitle.tsx`, the iOS one) shows
  `PRODUCT_NAME` where upstream draws the T3 glyph + "Code" (#601).
- `apps/mobile/src/widgets/AgentActivity.tsx` — the lock-screen thread card's
  elapsed timer (#1047 follow-up), the fork's one edit to the widget:
  `AgentActivityRowProps` gains an optional `startedAt` (the turn's, which the
  server sends on a starting or running row and the Mac forwards untouched)
  and `renderCompactRow` draws a `Text` with `timerInterval` +
  `countsDown={false}` for such a row, so SwiftUI counts it up on the phone
  between pushes. Both bounds are derived from `startedAt` — the widget reads
  no clock — and the upper one caps the display a day in. The timer text is
  boxed in a fixed-width trailing `frame` with `multilineTextAlignment`: a
  bare `Text(timerInterval:)` is greedy and swallowed the title and project
  of every working row, so a sync that drops the frame brings that back. It lives here rather
  than in a fork file because the widget body carries the `"widget"` directive
  and is serialized into the widget extension's bundle: it can reference only
  imported view and modifier factories, never a module-scope helper of ours.
  Keep the edit to those two places so every upstream sync meets a small one.
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
- `apps/web/src/lib/infinitusNotifications.logic.ts`,
  `apps/web/src/components/desktop/DesktopBadgeCoordinator.tsx`,
  `apps/web/src/components/desktop/NotificationModeMigration.tsx`,
  `apps/web/src/components/settings/DesktopBadgeSettings.tsx`,
  `apps/desktop/src/electron/ElectronNotification.ts`,
  `apps/desktop/src/ipc/methods/notifications.ts` — thread notifications
  and sounds are upstream's (#11481: `notificationMode` on the client
  settings, `ThreadNotificationCoordinator`, the `Notification` API and two
  bundled sounds; ruling #1032, which retired the fork's #270 B banners over
  the Electron main process and the #270 H per-window completion sound).
  The fork layers a few things. In `ThreadNotificationCoordinator.tsx` (an
  upstream file, one registration point): `held` and `limited` threads
  notify like input does — the holds come from the environment's
  `subscribeInfinitusHolds` stream, and `attentionNotificationTitle` is
  what titles them, since upstream has no word for either. `failed` now
  reads "Thread failed", upstream's word, so the fork carries no second
  vocabulary for one banner. Upstream's two coordinator tests mock
  `../state/environments`, so they also stub `useEnvironment`,
  `../state/infinitus` and `../state/query`: without the capability the
  holds path stays inert and their assertions read upstream's behaviour. Upstream now
  notifies on `failed` itself (by the latest TURN's state; the fork's
  resolver reads the SESSION, so both checks run and catch different
  rows), and it now quiets its own banner while the window has focus,
  showing an in-app toast instead — so the fork's remaining focus rule is
  narrower than it was: `quietForViewer` keeps the thread ON SCREEN
  silent, toast and bell included, where upstream still rings for it.
  Mind the naming when merging this file: both sides bind `attention`
  and mean different things by it — the fork's is the banner title,
  upstream's is the dedupe key the fork calls `input`. Next, #270 B's
  queue rule: a turn that completes while the thread still has
  `queuedTurns` neither posts nor rings
  (`notificationKind`), since the #806 drain sends the next row the moment
  the turn ends; the completion still counts as seen, so removing the queued
  row afterwards rings nothing for it, and an approval or question rings
  queued or not because the drain cannot pass it. The Dock badge
  (`desktopBadgeAttention`, on by default) counts the threads in approval
  or input through the `setBadgeCount` bridge method, the one IPC left
  (`SET_BADGE_COUNT_CHANNEL`), its switch the notifications route's `lead`
  and the `desktop-badge` search item. `NotificationModeMigration`, mounted
  from `__root.tsx`, maps a client's old settings onto `notificationMode`
  once (`legacyNotificationMode`: the four banner toggles — absent counts
  as on, and only on a desktop shell — and the old
  `infinitus:completion-sound:v1` switch), only while the mode still reads
  `off`, then marks `infinitus:notification-mode:migrated:v1`; the four
  toggles stay in `ClientSettingsSchema` as optional inputs and are never
  written again. Fork-thread events only: the account events (a limit,
  every account dead, revived) stay the native app's Notification Center
  items.
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
  its phone Settings rows (#1265). Upstream's T3 Connect text above it is
  untouched.
- **The project file is `infinitus.json`** (#823 layer 1: the upstream name
  never reaches a screen, and this one is on screen every time the scripts
  menu or Settings › Projects names it). `packages/contracts/src/t3ProjectFile.ts`
  is the pivot: `T3_PROJECT_FILE_NAME` is `infinitus.json`,
  `LEGACY_T3_PROJECT_FILE_NAME` keeps upstream's `t3.json`, and
  `T3_PROJECT_FILE_NAMES` is the order every read site walks — the first name
  that answers decides, and a file that answered decides even when it fails to
  decode, so a checkout carrying both never silently falls back to the older
  one. No merge, no conversion: an unconverted repository is read from its
  `t3.json` as before. The four read sites:
  `apps/server/src/project/T3ProjectFileLoader.ts` (the loop, + its test's
  fallback and preferred-wins cases), `apps/web/src/hooks/useT3ProjectFileScripts.ts`
  (both names queried, `loading` until both settle so the status cannot flap),
  `apps/web/src/lib/t3ProjectFileDefaults.ts` and
  `apps/mobile/src/features/threads/new-task-flow-provider.tsx` (both queries
  gated on the same boolean, so the hook count is stable). The copy follows:
  "From infinitus.json" / "Import from infinitus.json"
  (`ProjectScriptsControl.tsx`, `ProjectActionsSettings.tsx`, whose invalid-file
  card names both), the Workspace rows in `ProjectDefaultsSettings.tsx`, the
  `settingsSearch.ts` and `CommandPalette.tsx` search terms (both names) and
  `docs/user/project-settings.md`.
  `T3_PROJECT_FILE_SCHEMA_URL` is `https://infinitus.run/schema/infinitus.json`
  — upstream's `apps/marketing/src/pages/schema/t3.json.ts` is left untouched
  and now publishes a document whose `$id` names ours, which is harmless: it is
  upstream's site, not ours. We serve the schema from `apps/mac/site`, which has
  no build step, so `scripts/build-project-file-schema.ts` writes
  `apps/mac/site/public/schema/infinitus.json` from
  `buildT3ProjectFileJsonSchema()` and `--check` (with the test beside it)
  fails when the checked-in asset drifts from the contract. Regenerate after any
  change to the project file schema, and **the URL only resolves after a hand
  `npx wrangler deploy` from `apps/mac/site`**.
  The repository's own `infinitus.json` carries `iconPath`
  `assets/infinitus/infinitus-web-apple-touch-180.png`, so the project row for
  this checkout draws the Infinitus mark instead of upstream's T3 blueprint
  icon; `ProjectFaviconResolver` reads it ahead of the well-known favicon paths.
- `.github/workflows/ci.yml` — `runs-on` swapped from Blacksmith runners to
  GitHub-hosted ones, timeouts widened, `workflow_dispatch:` added so the
  upstream-sync workflow can start CI on its branch. The sync workflow
  re-applies the runner swap after every merge. It pushes with the
  `UPSTREAM_SYNC_TOKEN` secret when present (a fine-grained PAT: contents,
  workflows, pull requests — write), since the default token cannot push a
  branch that touches `.github/workflows` (#658); without it such a sync
  is done by hand.
- Upstream workflows that deploy or publish (Release, Deploy T3 Connect
  relay, Forward to Cursor hygiene, Mobile EAS Preview/Production, Publish
  AUR, Issue Labels, Desktop macOS Preview, Web Preview, Mobile Showcase
  Screenshots, Thread Transfer Report, Desktop macOS Preview Publish — new
  with the 0310cbf9 sync, `pull_request_target` on close/unlabel) are disabled in the repository's
  Actions settings, not deleted, so merges stay clean.
