# Infinitus fork — rules on top of AGENTS.md

This `main` is a fork of [T3 Code](https://github.com/pingdotgg/t3code) that
drives the Infinitus engine. AGENTS.md (upstream's guide) applies in full;
this file adds the fork's own rules. Plan and history: issue #555.
Unification (#823, user ruling 2026-09-11): the product is one name,
Infinitus — no user-facing "fork", "native" or "T3 Code" anywhere; the
Swift app lives in `main` as `apps/mac`; one version `0.5.0-alpha.N`
ships everything from one release. "Fork" and "native" below are
contributor shorthand for this TypeScript tree and the Swift app.

## Non-negotiables

- **Never an upstream PR.** Upstream is merged in, not contributed to. Do not
  open pull requests, issues or discussions on `pingdotgg/t3code` from this
  work.
- **One API.** The fork talks to Infinitus only over its control socket
  (`ControlProtocol`: one JSON line each way; `infinitusctl manifest` is the
  runtime command table — its reply shapes are prose, so reply schemas are
  hand-written in `packages/contracts` and validated at the boundary);
  the phone reaches the Mac through the desktop (inventory: issue #553;
  the Mac's mirror HTTP server left with #1041). Anything missing becomes a new
  route on the `native` branch, never a second protocol or a read of the
  native app's files.
- **Upstream merges daily, our history never rebased.** `git fetch upstream
&& git merge upstream/main` on a branch, PR to `main`. Our code lives in
  new files, new routes, new settings sections; edits to upstream files stay
  at registration points so merges stay small. The list of upstream files we
  edit on purpose is in "Registration points" below — keep it current.
  Expected on every sync (#823 layer 3): upstream's tests assume a plain
  `x.y.z` is a `latest` build titled "(Alpha)"; here every non-nightly
  version is an `infinitus` build, so their fixture expectations in
  `scripts/build-desktop-artifact.test.ts` (0.0.17 icons and brand, DMG
  background; the publish config follows the version's prerelease id and
  matches upstream's expectation), `apps/desktop/src/settings/DesktopAppSettings.test.ts`
  (default channel), `apps/desktop/src/app/DesktopEnvironment.test.ts`,
  `DesktopAppIdentity.test.ts` and `DesktopPreReadyPlatform.test.ts` (plain
  title, no stage suffix) and `apps/desktop/src/updates/DesktopUpdates.test.ts`
  (upstream-channel tests start on a nightly feed via the harness `settings`
  option; the harness's `resourcesPath` option and the feed-swap test are
  the fork's, #1042; `DesktopShellEnvironment.test.ts`'s harness takes an
  `existingPaths` fake filesystem for the known-CLI-dirs fallback, #1078), and
  `apps/desktop/src/updates/releaseNotes.test.ts` (the channel argument: the
  notes are filtered by `resolveDefaultDesktopUpdateChannel`, which never
  answers `latest` here)
  are re-flipped to `infinitus` after each merge, never the rule.
  An upstream migration whose number collides with the fork's own
  (`051`–`057` and `059`, #806 onward) is renumbered after them in the merge
  (`Migrations.ts` and the file; upstream's `051_ProjectionThreadMessageContext`
  is the fork's `058`, its `052_ProjectionThreadTitleState` the fork's
  `061`), so an existing fork database never skips it. Upstream commits
  `.pnpm-store/v11/index.db` (#11265) and rewrites it on every install; the
  fork ignores the file and drops it from the merge (`git rm --cached`), so
  each sync meets it as a modify/delete conflict resolved the same way.
- **`apps/mac` is the Swift app** (#823 layer 2, 2026-09-12). Today's
  native Infinitus (menu bar, engines, tunnels, mirror API, control
  socket, Linux tray) lives in `apps/mac` with its own CLAUDE.md
  (read it when working there), its own CHANGELOG/VERSION, path-filtered
  CI jobs (`mac-*` in ci.yml) and its own workflow
  (`mac-linux-sanitize.yml`; releases are `infinitus-release.yml` and the
  nightly `infinitus-nightly.yml`, below).
  It came in as a subtree
  (`git subtree add`) from the frozen `native` branch, history included
  (the merge's second parent). Its dev loop is unchanged: `cd apps/mac && ./make-app.sh`,
  `swift test`, `/bin/sh tools/e2e.sh`. infinitus.run is `apps/mac/site`,
  deployed by hand with wrangler from that directory.
- **One release (#823 layer 3).** A `v<version>` tag on `main` runs `.github/workflows/infinitus-release.yml` (upstream's `release.yml` stays disabled, hence the name; its CONTENT is still upstream's, taken whole at every sync, but the sync's runner swap rewrites it like every other workflow — a merge that takes upstream's file wholesale and skips the swap silently reintroduces Blacksmith runners): the `mac` job builds, signs, notarizes and staples both Swift bundles on `macos-26`; `desktop` nests that run's `Infinitus-Menu-Bar-<v>.zip` and builds the DMG with `--build-version "$VERSION"`; `linux` builds the tray; `publish` creates the one GitHub release — DMG, zip, blockmaps, the updater manifest, both menu bar zips, the Linux binaries — titled `Infinitus <version>`, notes from the `## <version>` section of `apps/mac/CHANGELOG.md` (no section, no release; a PR writes its note as a fragment in `apps/mac/changelog.d/` — `Surface: sentence` per line — and the cut runs `node scripts/fold-changelog.mjs <version>` to fold the fragments and `## Unreleased` into that section. The script unlinks every fragment it folds, so those deletions belong in the cut commit itself: the tag must point at a tree whose `changelog.d/` holds only its README, which the `notes` job checks before anything is built), `--prerelease` iff the version carries a prerelease tag. The tag must equal `v$(cat VERSION)`. `workflow_dispatch` is the dry run (artifacts, nothing published). The site's installer reads `releases/latest` and the `nightly` tag (the menu bar app's own poll left with its About pane, #1237): `latest` becomes the one-app release with the first plain version; `nightly` is `infinitus-nightly.yml`'s rolling build of the whole product (#1042): the same build jobs, called (`workflow_call`) every night at 17:17 UTC with `<VERSION>-infinitus-nightly.<yyyymmdd>.<run>` written over `VERSION` in the job, published by the caller — one release created once and only edited in place (tag re-pointed, assets clobbered, older nights' versioned assets removed, title edited), never deleted and recreated: the desktop updater takes the first entry of `releases.atom`, an edited `nightly` keeps its place below the newest versioned tag, a recreated one would not (#924). A dispatch of the nightly workflow is a dry run unless its `publish` input is set from `main`. GitHub delivers the cron slots hours late here: wait ≥ 4 h past the slot before calling a night missed, and never hand-dispatch with `publish` while a slot may still deliver (#1258). The `infinitus` track name lives only in the desktop's settings and UI. Feed mechanics and history: `docs/internals/release-and-updates.md`.
- **One version (#823 layer 3).** The root `VERSION` file (one line,
  `0.5.0-alpha.N`) is the only place the product version is written:
  `apps/mac/make-app.sh` reads it for `CFBundleShortVersionString`,
  `infinitus-release.yml` passes it as `--build-version`, and
  `apps/mobile/app.config.ts` carries it as `extra.productVersion` for the
  phone's Settings (the store's `version` stays a dotted-integer marketing
  version, and cannot go down).
  `apps/desktop/package.json`'s version is upstream's and never edited. The
  `infinitus` track is internal and follows from the version, not a flag:
  every version that is not an upstream nightly (first prerelease id
  `nightly`) brands as `infinitus`; one carrying the nightly suffix
  `-infinitus-nightly.<date>.<run>` (#1042; the line's id stays first,
  `0.5.0-alpha.7-infinitus-nightly.20260913.42`) defaults to the
  `infinitus-nightly` track with the same brand and a plain title, every
  other one to `infinitus` (`resolveDesktopUpdateChannel`,
  `resolveDefaultDesktopUpdateChannel`,
  `resolveWebAssetBrandForPackageVersion`; all read the first prerelease
  id, never the `-nightly.` substring the suffix carries too). Upstream's `latest` track is
  never a default here; a persisted `latest` resolves to `infinitus`. The
  feed a build follows is a separate thing, above.
- **PR-only main** (ruleset "main via pull requests"): required checks are
  T3's CI jobs Check, Test, Test Server 1–3. `gh pr create --base main`,
  `gh pr merge --squash --auto`. Every commit carries a
  `Co-Authored-By: Claude … <noreply@anthropic.com>` trailer naming the
  model that did the work (the harness supplies the exact name). A session
  working for the fork's owner (deathemperor) opens the PR and arms the
  merge without asking — standing consent, user ruling 2026-09-15; for
  anyone else AGENTS.md's rule stands: no PR unless asked.
- **Worktrees share one clone's `refs/remotes/origin`.** Several sessions
  work in worktrees of the same clone, so `git fetch && git merge origin/main`
  can merge a tip another session fetched moments earlier and land a branch
  that silently misses commits already on main (#1092 missed #1091 this way,
  with a clean-looking stat). After every merge of main and before arming
  auto-merge: `git fetch origin main && git merge-base --is-ancestor
origin/main HEAD || echo STALE`. A PR whose checks are green but whose
  mergeability sits at UNKNOWN for a quarter hour is GitHub's, not ours:
  `gh pr close` then `gh pr reopen` recomputes it and re-fires the PR event
  (auto-merge drops on reopen; arm it again). Never push empty commits for
  either. The stash stack is shared the same way, so **`git stash` is
  off-limits in this repo** (ruling 2026-09-14): two sessions' push/pop pairs
  interleaved and each popped the other's work — one baseline run swapped a
  #1213 edit for another lane's uncommitted feature, recovered only because
  the tree was diffed to a patch before anything else touched it. Commit to
  the branch, or use a scratch worktree, for a baseline.
- **Never install anything on the developer's Mac** (toolchains, brew,
  Xcode components, Docker). `vp i` inside the worktree is fine.
- Secrets travel over stdin, never argv; shown masked only.
- Todos and research notes go to GitHub issues, never to files in the tree.

## Registration points (upstream files we edit on purpose)

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
- `packages/contracts/src/environment.ts` — the `infinitus` and `turnQueue`
  (#812) capabilities on `ExecutionEnvironmentCapabilities`; `alternateHttpBaseUrls` (optional) on
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
- Server-side message queue (#806, the server half of #270 F): `packages/contracts/src/baseSchemas.ts` (`QueueId`), `packages/contracts/src/orchestration.ts` (`OrchestrationQueuedTurn`, `queuedTurns?`, `thread.turn.queue` / `.queue.update` / `.queue.remove` / `.queue.move`, `queuedFrom?`, `thread.turn-queued` / `-queue-updated` / `-queue-removed` / `-queue-moved`), `packages/shared/src/orderKeys.ts`, `apps/server/src/orchestration/decider.ts`, `projector.ts`, `Schemas.ts`, `packages/client-runtime` `threadReducer.ts`, `Layers/ProjectionPipeline.ts` (`projection_thread_queued_turns`, migrations `051`, `059`; `persistence/ProjectionThreadQueuedTurns.ts`), `Layers/ProjectionSnapshotQuery.ts`, `Normalizer.ts`, `apps/server/src/server.ts` (`InfinitusTurnQueueLive`), `Services/InfinitusSessionInterrupt.ts` (`paused`); fork-only `apps/server/src/infinitus/Layers/InfinitusTurnQueue.ts` (+ `infinitusTurnQueue.logic.ts`, `queueDrainVerdict`). Rules and traps: `docs/internals/turn-queue.md`.
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
  beside Stop while running, labelled "Queue message" / "Send now";
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
- `packages/shared/src/cliRelease.ts` — `CLI_RELEASE_REPOSITORY` is
  `deathemperor/infinitus`, and `cliReleaseChannelOf` reads this repo's
  nightly suffix (`-infinitus-nightly.<date>.<run>`, #1042) as the nightly
  train wherever the line's own prerelease id left it (#1192). That one
  constant is where every runtime installer gets its download URLs and its
  "what is newest" lookup, so upstream's value means an Infinitus desktop
  asks `pingdotgg/t3code` for a `v0.5.0-alpha.N` archive that cannot exist,
  and `t3 update` on an Infinitus CLI resolves upstream's newest build and
  installs T3 Code over it. Re-flipped after every sync, like the runner
  swap. Two fixtures pin the value and are re-flipped with it:
  `packages/shared/src/cliRelease.test.ts` (the download base URL and the
  release-index page URL) and `packages/ssh/src/tunnel.test.ts` (the remote
  runner script's `T3_RELEASE_BASE_URL`) — the second lives in another
  package and is easy to miss, which is how it went red on #1193.
  **The archives themselves are not built yet** — until the release
  workflow attaches upstream's five CLI archives and `SHA256SUMS` to our
  tags, an SSH remote and `t3 update` fail with "no archive for this
  version" instead of fetching upstream's; that is the point. Desktop-managed
  backend updates never came this way (`selfUpdate` short-circuits on
  `desktopManaged`).
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
  no clock — and the upper one caps the display a day in. It lives here rather
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

## Fork-only files

- `apps/server/src/infinitus/Layers/InfinitusSlack.ts` (+ `infinitusSlack.logic.ts`, `Services/InfinitusSlackClient.ts` — the `SlackClient` seam, tests) — the Slack bridge's reactor (#574, PR 2 of 4); state in `<stateDir>/infinitus-slack/threads.json`. Rules and traps: `docs/internals/slack-bridge.md`.
- `apps/web/src/components/settings/infinitus/` — the Infinitus settings panes
  (preferences, Engines) and their pure logic — Engines carries the proxy
  engines' form (`InfinitusEngineSecrets` + `engines.logic`, #1177): base
  URL and management key / dashboard password per engine, read over `proxy`
  / `9router`, written over `infinitus.secret` as `proxy-key` /
  `9router-password` with the url as `--url` (there is no url-only write:
  the url is stored with the secret; "Forget" sends an empty secret), which
  relaunch the app; gated on the manifest marking both verbs as taking
  their secret on stdin, else "no engine secret commands (needs ≥
  4eaccb341c)"; Test connection sends `test-connection <engine> [--url]`
  (native #1216, read effect) at the typed url without saving and shows
  "Reachable in N ms" or the engine's own sentence, gated on the manifest
  listing the verb; the Mac's Routing section (#1235): a Routing strategy
  select over `proxy-routing` and a Session affinity switch over
  `proxy-affinity`, each gated on its own verb, the switch drawn only while
  the `proxy` reply carries `sessionAffinity` (a proxy without the route
  gets the YAML note instead), the notes worded as `RoutingNotes` in
  `EnginesPane.swift`, the proxy re-read after every write since its
  settings are not in the snapshot; each engine's own `dashboardURL` as a
  link (CLIProxyAPI's `/management.html`, 9Router's `/dashboard`); and
  the status list's `binaryPath` / `daemon` / `error` from `status.engines`
  (`InfinitusEngineState`, optional keys) — and the Devices
  pane's "Pair a phone" card (`InfinitusPairPhoneCard` + `pairPhone.logic`):
  a QR of upstream's one-time pairing link whose host is the Mac's Cloudflare
  tunnel (`status.forkTunnel`, #572) while it is up, else the server's LAN
  address (the desktop's `serverExposureState.endpointUrl` while Network
  access is on, else the first of the server's own `lanHttpBaseUrls`, else
  the page's own non-loopback origin; #651). Both up → an Internet / Same
  Wi‑Fi choice; neither → it points at Settings › Connections › Network
  access. "Type it instead" reveals host + code for the phone's manual form.
  The link is the site's universal link (#724): `https://infinitus.run/pair`
  with `token`, `for=phone` and `to=<the Mac's origin>` all in the fragment,
  which the site's server never sees — one shape for tunnel and LAN. A phone
  with the app opens it in the app (`applinks:infinitus.run`, #782), which
  rebuilds `<origin>/pair#token=…` and fills the sheet; the site's `/pair`
  page forwards an app-less phone or a desktop browser to `<origin>/pair`,
  where `InfinitusPhoneLinkSurface` ("this link is for the Infinitus phone
  app") from `routes/pair.tsx` replaces `PairingRouteSurface`, so a browser
  never spends the one-time token. Order of landing: the site's AASA
  `applinks` + forwarder first, then this card, then a phone build with the
  entitlement. It is mounted through the prefs panel's `footer`
  slot from `routes/settings.infinitus.devices.tsx`; no route of its own.
  Before it in that slot, the "Phone alerts" card (`InfinitusApnsCard` +
  `apns.logic`, #1178): the `apns` read (`{keyPresent, teamId, keyId,
registrations}`, never a token; each registration decoded alone) drawn as
  "In the Keychain." / "Not set up." and a list of the registered phones by
  name · kind · environment, and the `.p8` as a file input — read in the
  browser, refused without the `-----BEGIN PRIVATE KEY-----` header (the
  Mac's own check, so a misclicked file is never sent), handed once to
  `infinitus.secret` as `apns-key` and kept nowhere; "Forget key" is the
  empty secret. The input stays off while the `apns_key_id` pref above is
  blank (read off the snapshot's prefs: the Mac stores the key under it and
  refuses until it is set); gated on the manifest marking `apns-key` as
  stdin secret. The page's Team ID, Key ID, "This Mac's name" and iCloud
  rows are the `devices` catalog section with copy in `PREF_COPY`; the
  Mac's pair token has no consumer left and is not on the page.
  Above it, through the panel's `lead` slot (drawn whatever the native app's
  state — the requests come from this server), the "Pairing requests" card
  (`InfinitusPairingRequestsCard` + `pairingRequests.logic`, #710): the
  server's pending approve-on-Mac asks from `subscribeInfinitusPairing`
  (device name, os · address, the match code large, a countdown), each with
  Approve / Deny through `infinitus.pairingDecide`; `decided: false` reads
  "already expired". The stream carries no secret and no credential, so the
  card never sees one. The stream and the decision need the administrative
  scopes only the desktop app's own session holds; a QR / `t3 pair` client
  is refused, and the card then says "Only the desktop app on this Mac can
  approve devices" instead of the empty state (`pairingAccess.logic` +
  `usePairingRequests`, shared with the toast hook, #730).
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
  (an account switch, every account exhausted) as the app's toasts; nothing
  from the first snapshot, deduped by the server's event id. Every toast has
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
- `apps/web/src/components/captures/` and `apps/web/src/state/captures.ts` —
  the composer's Captures popover (#433, PR B): `ComposerCapturesBadge` (the
  shoulder tab beside the stash badge, open count), `ComposerCapturesMenu`
  (the list in the composer's anchored layer: Enter adds — a multi-line
  paste is one capture — per item Send to composer / Copy / done / remove,
  "Clear done"; Escape or a pointer outside closes, a Send that landed
  closes, a busy composer toasts), `captures.logic` (ordering, selection and
  paste normalisation, failure copy), `capturesUiStore` (the open state
  the badge, the shortcuts and the palette share), `useCaptures`
  (`useActiveProjectRef` — the routed thread's or draft's project;
  `useCapturesShortcuts` — `captures.toggle` opens/closes, `captures.add`
  captures the app's own selection, else opens with the input focused).
  `state/captures.ts` is the web instance of the client-runtime atoms.
  `CaptureGestureCoordinator` (+ `captureGesture.logic`, #433 slice 2) is
  the desktop gesture's landing: mounted once from `__root.tsx` beside
  `SnapShotCoordinator`, it adds a `captured` event's text to the routed
  thread's project, else the last project a gesture reached, else holds it
  until a thread with a project is open, and toasts `empty` / `failed`
  (the Accessibility fix by name). `useAddCapture` is shared with the
  shortcuts.
- `apps/web/src/components/prompts/` — per-project prompt snippets (#270 G):
  `promptSnippets.logic` (the project's list from server settings, draft
  trimming against the schema caps, name-derived ids, upsert/remove under
  the 50-per-project cap, the settings patch — an empty list stores `null` —
  and the one-line preview), `promptsUiStore` (the popover's open state),
  `ComposerPromptsBadge` (the shoulder tab after Captures, saved count),
  `ComposerPromptsMenu` (one row per snippet in the composer's anchored
  layer; a click puts the body at the end of the composer via
  `insertComposerTextAtEnd` and closes; "Edit prompts…" opens Settings ›
  Projects for the project; Escape or a pointer outside closes),
  `useProjectPromptSnippets` (the routed project's list plus its settings
  group key), and `ProjectPromptSnippetsSection` (Settings › Projects ›
  Prompts: add / edit / remove, read from the representative checkout and
  saved to every checkout of the group through
  `serverEnvironment.updateSettings`, like the panel's overrides). Snippet text
  is user prose: toasts and labels show the name, never the body. The `/`
  menu offers them too (`promptSnippetSlashItems`: filtered by name, a
  leading `/` or `prompt:` ignored, listed after the commands and skills;
  picking one replaces the `/query` with the body where it was typed, via
  `applyPromptReplacement`). The phone lists the same snippets from its
  server config's settings (see `apps/mobile/src/features/threads/promptSnippetItems.ts`).
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
  Only the link's kind is ever logged; the native app's `join` / `pair`
  links are not claimed (Team left with #1041).
- `packages/contracts/src/captures.ts`, `apps/server/src/captures/CaptureStore.ts`,
  `packages/client-runtime/src/state/captures.ts` (exported as
  `@t3tools/client-runtime/state/captures`) — captures (#433): one list per
  project of `CaptureItem {id, text, createdAt, doneAt}` (≤ 200 items, ≤ 8 KiB
  each; `add` / `edit` / `setDone` / `remove` / `clearDone`, a command naming
  a gone id is a no-op), kept by the server as
  `<stateDir>/captures/<percent-encoded projectId>.json` — never in the
  workspace — written atomically under one lock and streamed whole after every
  change (`subscribeCaptures`, `orchestration:read`; `captures.apply`,
  `orchestration:operate`). A file the server cannot decode fails the
  project's reads and writes with `CaptureStoreError` (the issue, never the
  contents) rather than being overwritten. The client-runtime atoms are the
  `list` subscription family keyed `{environmentId, input: {projectId}}` and
  the `apply` command; the web popover (PR B) and the phone read the same
  stream.
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
- `apps/web/src/routes/stats.tsx`, `apps/web/src/components/stats/` — the
  `/stats` page (#659): the pop-out's Stats pane in the fork — period picker
  (localStorage `infinitus.statsPeriod`), the tile groups (Throughput,
  Messages & sessions, Autonomy, Friction, Limits, Cost — value, delta vs
  the previous period, sparkline), session lengths, and the effort tables
  (activities, models, engines, effort). Sidebar "Stats" beside Accounts.
  Its read model is `packages/client-runtime/src/state/infinitusStats.ts`
  (exported as `@t3tools/client-runtime/state/infinitusStats`): the `stats
--period p` reply decoded defensively and folded like native
  `StatsPresentation`. The read goes through `infinitusEnvironment.stats`, a
  query atom re-read every 5 min and dropped a minute after the page leaves,
  so nothing is requested unmounted; the page subscribes to the snapshot with
  `needs: ["stats"]` (`InfinitusSubscribeInput`, `subscribeInfinitus`'s
  payload), which the server ref-counts into the `client-activity` lease's
  `stats` scope only while a page holds it (#587 step 2, minimal form; #625
  had dropped the scope for good reason). Estimates, never billing truth.
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
- `apps/web/src/routes/utilization.tsx`, `apps/web/src/components/utilization/`
  — the `/utilization` page (#747): the native Utilization pane in the fork.
  Forecast: every account's projection at its own measured pace (windows,
  pct, pace, when each fills or "Resets before it fills", which window
  binds first) plus the fleet strip Accounts shows, read off the `forecast`
  reply the snapshot already carries — no extra verb, no extra poll.
  `buildForecast` in `packages/client-runtime/src/state/infinitusAccounts.ts`
  decodes the lines leniently (the contract leaves them opaque; an odd line
  or window is dropped alone). History (every account's percentage of one
  window — 5h, 7d, a model — over 24 hours / 7 / 30 days, one SVG line per
  account), Five-hour windows (the windows the Mac reconstructs off its own
  history, newest first: each one's PEAK percentage — a window starts on the
  first request after the last expired, so its headroom idles rather than
  leaking, and the percentage it ended on says nothing — plus the poll count
  behind it, the still-ticking one, the range's replay sentence: switches,
  the ones onto a cold 5h clock, minutes stalled at the limit), Weekly waste
  (the headroom that expired at each 7d or per-model rollover, with a caveat
  on a row the Mac stopped watching hours before the reset; 5h windows are
  left out, since they recycle ~34× a week) and Run rate (tokens,
  API-equivalent $ and turns over the last
  hour / day / week, unpriced models, the live output rate) read the Mac's
  `utilization --days n` through `infinitusEnvironment.utilization`, a
  query atom re-read every 5 min while the page is mounted and dropped a
  minute after it leaves; `InfinitusUtilization` in
  `packages/contracts/src/infinitus.ts` pins the samples, the rates and the
  three telemetry row shapes, and leaves the dry-run plan opaque (its Swift
  `Action` is an enum with payloads whose Codable form the fork would have to
  guess at, and it proposes steps only the Mac can run); each telemetry row
  decodes on its own like `buildForecast`'s lines, so a Mac build that words
  one differently drops that row, not the section. The fold is
  `packages/client-runtime/src/state/infinitusUtilization.ts`. A build
  without the verb keeps the forecast and says what is missing; one whose
  reply carries no telemetry keeps the chart and the run rate, and the two
  sections are simply absent. Sidebar "Utilization" beside Activity.
- Live token rate (#1127): `packages/contracts/src/infinitus.ts` (`InfinitusLiveTokenRate`), `rpc.ts` (`infinitus.liveTokenRate`, `AuthOrchestrationReadScope` in `RpcAuthorization.ts`), `apps/server/src/persistence/ProjectionTurnUsage.ts` (`listCompletedSince`), `apps/server/src/infinitus/liveTokenRate.logic.ts` (+ test; `EMPTY_LIVE_TOKEN_RATE`), `ws.ts`; client `infinitus.ts` (`liveTokenRate`), `infinitusUtilization.ts` (`liveRateText`), `LiveRateLine` on the Utilization page. Rules and traps: `docs/internals/live-token-rate.md`.
- `apps/web/src/components/usage/UsageAccounts.tsx` — the "By account" table
  on upstream's `/usage` (#779): Claude spend split by the account that was
  active when each record was written. The server joins at scan time:
  `InfinitusUsageAttributionLive` (`apps/server/src/infinitus/Layers/`) reads
  the app's `history <fleet>` verb once per scan — swapd's own append-only
  switch log, whole, through the control client directly (the `command`
  path would poll after it) — for the Claude fleet whose engine has the
  `history` capability; `infinitusUsageAttribution.logic.ts` turns it into
  `accountAt(ms)` (join on email, never slot: compaction renumbers slots) and
  `UsageAggregator`'s optional `attribute` hook sums a per-account sibling
  of the buckets. A record in a swap's own second or before the first logged
  swap is "Unattributed", other providers "Other providers", so the table
  reconciles with the page total. `UsageSummary.accounts` is optional, the
  contract version unchanged; no Infinitus, no verb, or a refused reply means
  no `accounts` and the section stays hidden. Primary environment only.
  Emails travel in the summary as they do in `fleets`; never in logs, spans
  or fixtures.
- `apps/web/src/routes/accounts.tsx`, `apps/web/src/components/accounts/` — the
  Accounts page (fleet sections, account rows and their actions, the forecast
  strip, the unavailable state, and the Sign-ins section for lapsed AWS/gcloud
  credentials — `SignInsSection.tsx` with `signIns.logic.ts` — absent when
  nothing lapsed; one row per tool and profile, no session names and no
  `--pid` scope since the Mac's session sweep, #1041 — the phone's own
  `apps/mobile/src/features/infinitus/signIns.logic.ts` folds and words its
  rows the same way, and `InfinitusAwsLogin` carries neither `pid` nor
  `sessionLabel` any more, so an older app still sending them has them
  dropped at the boundary); row/section/sign-in
  models come from
  `packages/client-runtime/src/state/infinitusAccounts.ts`, whose
  `infinitusPageState` gates Accounts, Stats and Activity alike (#693):
  a server whose config arrived with `false` or without the field
  (`infinitusCapabilityOf`) gets the missing-adapter copy; a config that has not
  arrived waits like a missing snapshot, and Accounts folds every environment's
  answer together with `infinitusCapabilityAcross`. Add account and
  re-login (#671): a fleet whose capabilities carry `addOAuth` or
  `addCurrent` (swapd's CLI paste-code flow — it declares no `addOAuth`,
  #1213) gets "Add
  account" in its header and "Sign in again" on a `relogin_required` row, both
  native's `add <fleet>` (the sign-in opens on the Mac), then the page polls
  `wait-add --timeout 5` until the app says the flow ended
  (`addAccount.logic.ts`); hidden on a build whose manifest lacks `add`.
  On a build whose manifest lists `signin-begin` (#677) the sign-in runs
  inside the desktop app instead: the page sends `signin-begin <fleet>
[--relogin <email>]` over `infinitus.command`, the desktop shell shows the
  OAuth page in a child `BrowserWindow` per flow (fresh in-memory
  `signin-<flowId>` partition, sandboxed, no preload —
  `apps/desktop/src/infinitus/InfinitusSignIn.ts`), the page polls
  `signin-status` every 2 s (`signIn.logic.ts`) and, for paste-code flows,
  takes the code from the success page — the shell hands it to the app over
  the control socket as `secret` (`submitInfinitusSignInCode`), so it never
  crosses an RPC, the server or the tunnel. On every other client (a
  browser, the tunnel, the desktop looking at a remote environment) the page
  is a link this device opens in a new tab and the code goes over
  `infinitus.secret` as `signin-code {flowId}` (#747 step 2): the field is
  `type="password"`, `autoComplete="off"`, cleared on submit and gone with
  the form; the CLI's own `error` is shown; the submitted value is never
  interpolated into any message. Closing the OAuth window never cancels;
  the page's Cancel sends `signin-cancel`.
  Ahead of both, the sign-in the desktop shell runs itself (#1213): the
  engine is the OAuth client, so the shell spawns `swapd add-oauth` (below)
  and the engine's own loopback listener catches the redirect — no code to
  paste, no Mac build to wait for, and a fleet whose `addOAuth` capability
  the app never advertised can still be signed into. Its two gates are the
  only ones (`fleetSignInGate`): the engine binary is where this client is
  (`shellOAuthSignIn`: the desktop bridge carries both methods and this is
  the primary environment) and the fleet's engine is the one whose sign-in
  is that flow (`fleetRunsShellOAuth`, `swapd`; the proxy engine declares
  `addOAuth` too and is not one). Not the `addOAuth` capability — gating on
  it once reproduced the very bug — and not the app's `signInRunning`, which
  is its word about a flow of its own. For the same reason the row model's
  `reloginNeeded` is the lapsed status alone; who may run a sign-in is the
  page's to decide. `FleetSection` renders it
  through the in-app branch — a shell flow has no `url` and no code field,
  so the same markup reads "Sign in in the window." with a working Cancel —
  and `signIn.logic.ts`'s `SignInKind` says which half a flow belongs to, so
  start, cancel and end stay apart. Unlike #677, closing the window cancels:
  a loopback redirect leaves nothing to paste. A cancelled run answers
  `{ok: false}` with no `error`, and the page drops the flow rather than
  showing a failure the user caused.
- `apps/web/src/routes/settings.infinitus.{index,notifications,devices,engines}.tsx`
  — the four Settings › Infinitus routes, thin shells over the panes above.
  Profiles (#165, the Mac's "named way to start a session") left with the
  #1041 sessions sweep, its `profiles` contract with it, and the fixture's
  canned reply with the Mac's own verb (#1091).
- `apps/web/src/test/animationFrame.ts` — the `requestAnimationFrame` polyfill
  registered in `apps/web/vite.config.ts` test setup (an upstream test needs it
  under the fork's runner).
- `packages/contracts/src/productName.ts` — `PRODUCT_NAME`, the one constant
  every user-facing string routes through (#601 phase 2); contracts holds it
  because shared depends on contracts, and `packages/shared/src/productName.ts`
  re-exports it so `@t3tools/shared/productName` imports keep working.
- `apps/server` — rule: any string the user reads (CLI help and command
  descriptions, log lines, errors, HTTP/HTML pages, pairing and service copy,
  MCP tool descriptions, the git author name, the prompts and runtime
  instructions the assistant echoes) says `${PRODUCT_NAME}`, never a literal
  "T3 Code"; identifiers stay (`t3` binary and package, `T3CODE_*` env vars,
  the `t3-code` MCP server id, the `t3code/<version>` UA token, upstream URLs,
  "T3 Connect").
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
- `apps/server/src/infinitus/Layers/InfinitusSessionHold.ts` (+
  `infinitusSessionHold.logic.ts`, `Services/InfinitusSessionHold.ts`) —
  session priority mode (#616): the gate that holds a background thread's
  start (the user's send, an async answer, resume-on-limit, the post-update
  continuation) while the fleet its driver spends on publishes `headroom.state`
  `low`/`critical`, and runs it when the fleet reads `abundant`, the thread is
  pinned, `release(threadId)` ("Run now"), or a real poll carries no verdict
  for the fleet any more (mode turned off; an unreachable app keeps the hold).
  Pinned threads and a thread mid-turn are never held; a fleet that publishes
  no `headroom` (mode off, an older build) never holds. Held starts live in memory, oldest first, released
  2 s apart; one `infinitus.thread.held` / `infinitus.thread.released` work-log
  row per hold, which the web derives the held state from. "Run now" is the
  `infinitus.releaseThread` RPC (operate scope, `{threadId}` → `{released,
reason?}`, never an error) answered by `ws.ts` from the same service, falling
  through to `InfinitusSessionInterrupt.resume` when nothing is held (#743). The
  snapshot subscription is held only while a start is. The web reads the held
  state from those rows (`packages/client-runtime/src/state/infinitusThreadHold.ts`)
  and draws `apps/web/src/components/chat/useInfinitusHoldBanner.tsx` (+
  `infinitusHoldBanner.logic.ts`) in the composer banner stack, one mount in
  `ChatView.tsx` beside the snoozed/settled banners: "Waiting for headroom",
  the row's line, "Run now" and "Pin". The same state and banner cover a turn
  interrupt mode paused (#743): `threadHold` also reads the
  `infinitus.thread.paused` / `infinitus.thread.resumed` rows and answers
  `kind: "held" | "paused"`; the banner then reads "Paused for headroom" with
  "Resume now" (the same RPC, which falls through to the interrupt layer).
  The sidebar row reads "Held" (#741)
  from the `subscribeInfinitusHolds` stream (read scope; the service's `held`:
  the in-memory list, then again on every change — lost with a restart like
  the holds themselves), one shared stream per environment through
  `infinitusEnvironment.holds` and `sidebar/useInfinitusHeldSummary.ts`;
  held outranks working in `resolveSidebarThreadStatus` since the start never
  ran; a `kind: "limited"` entry (#270 I) reads "Limit" the same way, below
  held. `chat/PinAtCreationToggle.tsx` is
  "Pin on create" under a draft's composer (per-browser, off by default);
  ChatView pins the thread right after the send that creates it. Archived or deleted while held:
  forgotten. A restart forgets held starts; the message is still in the thread.
- `apps/server/src/infinitus/Layers/InfinitusSessionInterrupt.ts` (+
  `infinitusSessionInterrupt.logic.ts`, `Services/InfinitusSessionInterrupt.ts`)
  — session priority mode, interrupt (#743): pauses the background turns
  already running on a fleet whose `headroom.state` reads `critical` (what
  native publishes in interrupt mode where hold mode publishes `low`; the
  fork reads only the verdict) and continues them when the fleet reads
  `abundant`, the thread is pinned, `resume(threadId)` ("Resume now"), or a
  real poll carries no verdict any more; an unreachable app keeps the pause.
  Running turns are tracked from the driver's `turn.started`/`turn.completed`/
  `turn.aborted`/`session.exited` runtime events; the snapshot subscription
  (what makes the server poll, #346) is held only while a turn runs and the
  `priority_mode` pref reads `interrupt` (or a fleet already reads critical),
  or while a turn is paused — the one place the fork reads that pref, and only
  to know whether watching can lead anywhere. A pause is upstream's own
  `thread.turn.interrupt` command for the turn the session still names, so
  the transcript shows the interruption, plus an `infinitus.thread.paused`
  work-log row ("Paused for headroom on claude, 5h window 92 %"); a resume
  appends `infinitus.thread.resumed` and sends `CONTINUATION_PROMPT` through
  `TurnStartGate` like every other start (a fleet still low holds it) —
  except "Resume now", which runs like the hold's "Run now". Pinned threads
  are never paused; paused turns continue oldest first, 2 s apart; a thread
  the user sends into, archives or deletes while paused is forgotten.
- `apps/server/src/infinitus/Layers/InfinitusSecret.ts` (+
  `Services/InfinitusSecret.ts`) — the fork's one secret-carrying path (#747,
  the only exception to "secrets never over the fork RPC"): `infinitus.secret`
  (`access:write`; `{command, args, secret}` → `{result?}`) puts `secret` on
  the control request line's `secret` field — where stdin material always
  travels — for a verb whose manifest entry says `stdin: "secret"` (native
  #766), and refuses everything else before the socket: no manifest read yet,
  another verb (`"payload"`, none, unknown), an `args` key the verb's manifest
  `args`/`options` do not name or a positional it names missing, a sixth
  attempt by one auth session at one verb inside a minute. `args` is keyed by
  those names (identifiers, ≤128 chars, no control characters), the layer
  orders them. The value is `Schema.RedactedFromValue` on the wire, a
  `Redacted` from decode to the socket call (prints `<redacted>`), lives in
  that one request, is kept nowhere; the span carries the verb only. The
  reply passes through opaque; that it never echoes the secret is each verb's
  contract. A successful call refreshes the snapshot, detached, like a write.
  `infinitus.command` stays secret-free. The panes' rules (password input,
  autocomplete off, cleared on submit/unmount, never interpolated into a
  message, sensitive read replies like `team-code`/`pair-status` rendered
  and never logged) bind their PRs (#747).
- `apps/server/src/infinitus/Layers/InfinitusServerPort.ts` (the credential
  step), `apps/server/src/infinitus/Layers/InfinitusHttp.ts`, the `infinitus`
  group in `packages/contracts/src/environmentHttp.ts` — the server half of
  `infinitusctl`'s desktop verbs (#822). Right after `prefs set
fork_server_port`, on an app whose manifest lists `desktop-credential` with
  `stdin: "secret"`, the port publisher revokes any session with subject
  `infinitusctl`, mints one (`EnvironmentAuth.issueSession`: scopes
  `orchestration:read orchestration:operate access:read`, label
  "infinitusctl on <Mac>", 90 days, no refresh) and hands the token to the app
  on the request line's `secret` field with `{origin, expiresAt}` as options —
  one "infinitusctl on <Mac>" row in Settings › Devices, replaced on every
  publish, revocable there (the next CLI request gets 401 until the next
  publish). A refused write revokes the new session again. Withheld exactly
  where the port is (dev runner, isolated socket, worktree `.t3`); the token
  reaches no log or span. The publish repeats on a 60 s heartbeat (#1137):
  the keeper reads the app's own catalog and republishes port and credential
  only when `fork_server_port` names a port that is not ours, so a server
  that published over this one and died is corrected within a minute instead
  of leaving the tunnel on a closed port until someone relaunches the app. A
  read and not a blind write, because every publish re-mints the
  `infinitusctl` session and doing that on a timer would rotate the CLI's
  token every minute; an absent pref and a value that is not a port both read
  as no drift for the same reason. The heartbeat is the only part here that
  needs no watcher — `observed` starts no poll, so the app-came-back edge
  never fires on a server nobody is looking at, which is how the stale
  publish survived. The edge and the heartbeat share one permit: a publish
  revokes, issues and hands over, so interleaved they could leave the app
  holding a token the other call revoked and a matching port the heartbeat
  would never repair. The drift line names the foreign port, so two live
  publishers fighting over the pref read as the same port coming back every
  minute. Residual: a stale publisher that used the same port
  leaves a credential this server cannot tell from its own. HTTP routes for a CLI with no WebSocket, the
  first two behind the operate scope: `GET /api/infinitus/holds` (the WS holds stream's
  list — held for headroom, stopped on a limit — plus `kind: "paused"` rows
  from `InfinitusSessionInterrupt.paused`, the turns paused for headroom,
  #743), `POST /api/infinitus/release-thread` (`{threadId}` →
  `{released, reason?}`, the WS `infinitus.releaseThread` word for word) and,
  behind the read scope, `GET /api/infinitus/thread-defaults?projectId=`
  (#1315: `{defaultModelSelection}` resolved as the composer resolves it,
  `resolveProjectSettings` — the project's override in
  `projectSettingsOverrides` (what Settings › General writes at a project
  scope; the row's `defaultModelSelection` is the retired path, read until
  the fold), then the environment default; no other HTTP route carries
  the settings, the composer reads them over the WS config). `thread new`
  creates on `--model <instanceId>/<model>` or a bare `<model>` on the
  instance of the default that applies, else the route's answer, else the
  project row (all a desktop without the route leaves it),
  `DesktopRows.modelSelection`.
  Registration points: `InfinitusLayerLive` provides `AuthLayerLive` to the
  port layer (which is why that block sits below `AuthLayerLive` in
  `server.ts`), `infinitusHttpApiLayer` in `makeRoutesLayer`. Queue-behind-a-
  turn is #806, not this; `thread show`, `send`, `interrupt` and
  `--wait` use routes that already existed, and `new` too but for the
  thread-defaults read above.
- `apps/server/src/infinitus/` — the server's Infinitus adapter: the control
  client (one connection per request, one JSON line each way), the
  `InfinitusService` poller behind `subscribeInfinitus` / `infinitus.command`,
  and the fork-port publisher (`prefs set fork_server_port` at startup —
  withheld, with one log line, from a dev-runner server or one whose home is
  a worktree-local `.t3`, so a dev run never takes the installed desktop's
  tunnel, #640). A command's spans carry the verb (#676): `Infinitus.command`
  annotates `infinitus.command`, `infinitus.args` (joined, cut at 200
  chars), `infinitus.options` (key NAMES only, never a value) and
  `infinitus.effect` from the manifest; `InfinitusControlClient.request`
  and the `ws.rpc.infinitus.command` span carry the verb alone. The poller
  reads `events --after <last id>` when the manifest lists the option
  (#346): `known: true` replies are all new, `known: false` (the app
  restarted) re-seeds the cursor and publishes only rows newer than the last
  one seen; builds without the option get the full-list read as before.
- `apps/server/src/infinitus/Layers/InfinitusSlackSocket.ts` (+ `infinitusSlackSocket.logic.ts` — `parseSocketFrame`, `reconnectDelaySeconds`; test) — the Socket Mode client, `SlackClientLive` (#574, PR 4). Rules and traps: `docs/internals/slack-bridge.md`.
- `apps/web/src/components/settings/infinitus/InfinitusSlackCard.tsx` (+ `slack.logic.ts` — `parseAllowedUserIds`, `slackStatusLine`; test) — Settings › Infinitus › Slack (#574, PR 3), mounted from `settings.infinitus.index.tsx`'s footer, search item `infinitus-slack`. Rules and traps: `docs/internals/slack-bridge.md`.
  `Layers/InfinitusResumeOnLimit.ts` (+ `infinitusResumeOnLimit.logic.ts`) is
  resume-on-limit for the threads this server runs (#648), and since the
  sessions sweep (#1041) the only one left — the Mac's terminal nudge went
  with the sessions it typed into: the Claude adapter's parked-turn
  warning (`rate_limit_info.status: "rejected"`) or a limit-failed
  `turn.completed` records a stop; while any thread is stopped the layer
  subscribes to the snapshot and waits for an active Claude account that
  reads `ok` from a probe taken after the stop (native's ResumeGate); then
  the parked turn is interrupted, a `infinitus.turn.resumed` work-log row
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
- `apps/server/src/infinitus/Layers/InfinitusSignInLapse.ts` (+
  `infinitusSignInLapse.logic.ts`, tests) — lapsed AWS / gcloud sign-ins for
  the threads this server runs (#1076), the fork's counterpart to the Mac's
  transcript scan (retired with the terminal-session features, #1041). Every
  tool result the Claude driver relays (`item.updated`, the raw `tool_result`
  block under `payload.data.result`) is read for the CLIs' expired-credentials
  signatures — the Mac's marker and line-start tables (`AwsLogin.swift`,
  `GcloudLogin.swift`) ported verbatim: a marker anywhere plus one opening a
  line at column 0, so the same words quoted from a file or a grep hit never
  match; only the last 16 KiB is scanned. The profile is the error's own
  `--profile` when it prints one, else the Bash command's `--profile` /
  `AWS_PROFILE` (`--account` / `CLOUDSDK_CORE_ACCOUNT` for gcloud), else
  `default`; gcloud's Application Default Credentials are the
  `application-default` account. A hit leaves one `infinitus.signin.needed`
  work-log row ("AWS sign-in needed on <profile>") and, on an app whose
  manifest lists the verb, starts the Mac's `aws-login <profile>` /
  `gcloud-login <account>` flow through `InfinitusService.command` (no `--pid`:
  a thread has no session pid; the Mac runs its default flow, and that path's
  post-write poll re-reads `aws-logins`, so the login reaches the Sign-ins
  lists at once instead of at the next cycle) — unless that same reply
  already shows a login for the credential in flight (`hasLoginInFlight`: any
  `state.phase` short of `done`/`failed`), which is a browser tab waiting on
  a person and must not be taken over. Once per thread per profile
  per hour (a thread reaching two expired AWS profiles in one hour needs both
  logins); one sequential worker off the event stream, so the turn is never
  waited on; an unreachable Mac or a refused verb is logged and the row
  stays. The result text and the command reach no log, span or payload —
  only the thread id, the provider and the profile.
- `apps/server/src/infinitus/Layers/InfinitusAgentActivity.ts` (+ `infinitusAgentActivity.logic.ts`, tests) — the phone's lock-screen thread card, the server half (#1047 part 3): folds every live thread's `projectThreadAwareness` into the aggregate card and hands it to the Mac's `push` verb as `thread.activity`; `InfinitusAgentActivityLive` in `server.ts`. Rules and traps: `docs/internals/phone-thread-card.md`.
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
- `apps/desktop/src/captures/` — the capture gesture (#433 slice 2, macOS
  only): with `captureGestureEnabled` on (the card's second row, drawn only
  on a Mac shell; turning it on asks for the Accessibility grant, the one
  SnapShot's context uses), a double tap of Shift in any app captures that
  app's selected text. `MacDoubleTapShiftProcess.ts` is the SnapShot
  modifier-pair poller's sibling (`osascript` sampling
  `CGEventSourceFlagsState` at 30 Hz, `ready` / `trigger` on stderr) reading
  two sub-350 ms presses with no character typed between them
  (`CGEventSourceCounterForEventType` for key-downs; both Shifts held is
  SnapShot's pair and never fires). `MacSelectedText.ts` is one `osascript`
  read of the frontmost app's focused element's `AXSelectedText` (3 s
  deadline, text cut to `MAX_CAPTURE_TEXT_LENGTH` in the helper; `failed`
  names `accessibility` / `no-focus` / `unsupported` / `timeout` / `helper`).
  `InfinitusCaptureGesture.ts` is the service (`setEnabled` writes the knob,
  then starts or stops the poller; one read at a time; a launch with the
  knob on checks the grant silently) and the renderer dispatch on
  `desktop:infinitus-capture-gesture-event`: an open window is not revealed,
  with none open one is (`revealOrCreateMain`) so the text is not lost.
  `shell.beep()` confirms a read that got text, since the user is in another
  app. The text never reaches a log or a span, only its length. Merged into
  `InfinitusDesktop.layer`; the switch is `setInfinitusCaptureGestureEnabled`
  (`ipc/methods/infinitus.ts`). The reads are pulled, never pushed (slice 3):
  the service queues each one (`makeCaptureGestureOutbox`) and pings
  `desktop:infinitus-capture-gesture-pending` unless the page is still
  loading, and the renderer drains `consumePendingCaptureGestures` on mount
  and on every ping — a push at `did-finish-load` beat the coordinator's
  mount and the text was lost after the beep. Both `osascript` scripts are
  spike-verified on the developer's Mac (the tests mock `spawn`).
- `apps/desktop/src/infinitus/InfinitusOAuthSignIn.ts` (+
  `InfinitusSwapdProcess.ts`, `infinitusSwapd.logic.ts`, test) — the sign-in
  the shell runs itself (#1213). **This is the one place the fork runs an
  engine's binary instead of talking to the Mac over the control socket**,
  and it bends "One API" on purpose: the OAuth client has to be whoever
  holds the PKCE verifier, and for a loopback redirect that is the engine.
  Signed off by the developer (2026-09-14), who put the consumer in the
  desktop app rather than `apps/mac`. `infinitusSwapd.logic.ts` is the pure
  half: `resolveSwapdBinary` (the `INFINITUS_SWAPD_CLI` override answers
  whole — a path only if it exists, empty meaning "no engine here" — then
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `~/.local/bin`,
  then the menu-bar helper nested in the packaged bundle, #777) and
  `parseAddOauthLine`, which reads the two-line protocol
  `swapd --json --provider <p> add-oauth` streams: the URL line the loopback
  listener flushes when it binds, then the `{slot, email, created}` envelope
  the stored account prints, or the engine's own `{error:{code,message}}`.
  `InfinitusSwapdProcess.ts` is the spawn boundary (one `SwapdAddOAuthRun`
  with a `result` promise and a `stop`). `InfinitusOAuthSignIn.ts` is the
  service: `begin` resolves the binary, spawns the run, opens the URL in a
  child window with `signInWindowOptions` (#677's, so the two sign-ins look
  alike) and races the announcement against a run that died before it, so a
  failure before the listener bound can never hang the page; closing the
  window, or `cancel`, kills the run. One promise for the whole flow. The
  account is stored inactive (`slots::claim(activate = false)`), so a
  sign-in never switches the live login. Merged into
  `InfinitusDesktop.layer`; the methods are `beginInfinitusOAuthSignIn` /
  `cancelInfinitusOAuthSignIn` (`ipc/methods/infinitus.ts`, `channels.ts`,
  `DesktopIpcHandlers.ts`, `preload.ts`), their contracts
  `InfinitusOAuthSignInInput` / `-Result` in `packages/contracts/src/infinitus.ts`
  and the two optional `DesktopBridge` methods in `ipc.ts`. No token, no
  code and no email reaches a log or a span.
- `apps/desktop/src/infinitus/InfinitusKeepAwake.ts` — sleep held off while a
  turn runs (#1075), the desktop's replacement for the Mac app's retired
  `keep_awake` (#1041 d5). The renderer decides from the thread shells it
  already holds (`apps/web/src/lib/desktopKeepAwake.logic.ts`
  `keepAwakeWanted`: the `desktopKeepAwake` client setting on, default on,
  and any thread on the primary environment with its session `starting` or
  `running`; remote environments never count) and sends the verdict over the
  optional bridge method `setKeepAwake`; the shell holds one
  `powerSaveBlocker('prevent-app-suspension')` while asked, idempotent, and
  releases it when its scope closes with the app. Registration points:
  `DesktopKeepAwakeCoordinator` mounted from `__root.tsx` after the badge
  coordinator (it sends once on mount, so a reload cannot leave the blocker
  held), `DesktopKeepAwakeSettings` closing the Behavior section of Settings › General
  with its dirty label and reset entry, the `desktop-keep-awake` search item,
  `SET_KEEP_AWAKE_CHANNEL`, `setKeepAwake` in `ipc/methods/infinitus.ts`, the
  handler and preload lines, the layer in `InfinitusDesktop.layer`. No socket
  traffic, no Mac involvement.
- `apps/desktop/src/infinitus/InfinitusHistoryGesture.ts` — the mouse's
  back and forward buttons on a Mac whose driver sends them as the system's
  page-swipe gesture (#1250; Logi Options+ maps them to `OSX_GESTURE_BACK` /
  `_FORWARD`, not Chromium buttons 3/4, so #841's `mouseup` listener never
  fires — Chrome turns that gesture into history itself, Electron drops it
  unless a window listens). darwin only: `swipe` is attached to every
  `BrowserWindow` on `browser-window-created` (and to a main window already
  open), the direction forwarded from the main window only over
  `INFINITUS_HISTORY_GESTURE_CHANNEL` (`onHistoryGesture` in the preload,
  `left` / `right` checked there); `AppSidebarLayout`'s history effect runs
  `swipeHistoryIntent` (`lib/backNavigation.ts`: right = back on a backable
  page, left = forward anywhere, Safari's rule) through the same
  `applyHistoryIntent` as the mouse buttons. One log line per gesture,
  direction only. Not covered: a driver that delivers the gesture as a
  scroll-phase swipe, which Electron never surfaces — the fallback then is
  the driver's keystroke mapping.
- `apps/desktop/src/shell/InfinitusPosixCliDirs.ts` (+ test) — the POSIX
  sibling of upstream's `knownWindowsCliDirs` (#1078): `~/.claude/local`,
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.nvm/versions/node/*/bin` newest first, `~/.volta/bin`, `~/.bun/bin`,
  existing ones only, joined to PATH after the login-shell probe's own
  entries and only when that probe answered nothing or a PATH without
  `claude` (`resolvePosixCliDirFallback`, pure over `exists` /
  `listDirectory`); one info line names the dirs added and the one holding
  `claude`. darwin only; a probe that answers in time still wins.
- `apps/desktop/src/infinitus/InfinitusDeepLinks.ts` — deep links (#270 D):
  `<scheme>://thread/<environmentId>/<threadId>` and
  `<scheme>://new?project=<id|title|folder>&prompt=<text>` on the renderer's
  own scheme (`infinitus` / `infinitus-dev`); only those two hosts are
  claimed, `app` stays the renderer origin and the Clerk callback, `join` /
  `pair` are the native app's. `deepLinkIntake` is attached before Electron
  is ready (a cold launch's `open-url` lands before `ready`; Windows and
  Linux carry the URL in argv and `second-instance`) and holds the latest
  URL until the service drains it; the service keeps the latest parsed link
  (`consume` clears it), opens or reveals the main window once the backend
  is ready (`createMainIfBackendReady`, the "activate without windows" gate)
  and pings `desktop:infinitus-deep-link-pending` when the page is loaded —
  a loading page pulls on mount. The prompt is cut at
  `MAX_DEEP_LINK_PROMPT_LENGTH` and never logged, only its length. Merged
  into `InfinitusDesktop.layer`; `consumeInfinitusDeepLink` in
  `ipc/methods/infinitus.ts`. On a Mac, LaunchServices sends `infinitus://`
  to one app: the native `Infinitus.app` also claims the scheme for
  `join` / `pair`, so whichever registered last gets every link (#270).

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
- `packages/client-runtime/src/connection/roaming.ts`,
  `apps/server/src/infinitus/Layers/InfinitusDescriptor.ts`,
  `apps/mobile/src/features/connection/roamingHosts.ts` — pair on the LAN,
  roam to the tunnel (#663). The server's descriptor names its other base
  URLs (`alternateHttpBaseUrls`: the Cloudflare tunnel from
  `status.forkTunnel` while it is up; a never-polled snapshot is refreshed
  once for it). The phone keeps them on the bearer profile from the pairing
  on and re-learns them on every connect, so a tunnel turned on after the
  pairing is picked up by the next LAN connect; each is stored in the
  profile's normalized shape (`normalizeHttpBaseUrl`), so a pairing made
  over the tunnel itself has no alternate. The server's list replaces
  the phone's on every connect — it is the authority on its own doors, and a
  quick-tunnel hostname it no longer holds can be handed to anyone, so the
  bearer token never follows a stale one (a host the profile no longer
  names is not tried, last-good or not). A connect tries the host that
  worked last, then the paired one, then the alternates (3 s descriptor
  wait on every host but the last); a host where
  the Mac is not — nothing answers (network, timeout), or something else
  does (`remote-unavailable`, a 404 or another environment's id) — is
  walked past, one that refuses the credential ends the walk. The bearer
  session is not host-bound, so no re-pair. The environment row says
  "Connected via <host>" while roamed, else "Also via <host> when you are
  away".
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
- `apps/mobile/modules/infinitus-loopback-catch/` (fork-owned local Expo
  module, iOS) — the phone answers the sign-in redirect itself, so nothing is
  pasted anywhere. gcloud's and AWS's CLIs run DESKTOP OAuth clients: the only
  redirect URIs their providers accept are `http://localhost:<port>` and
  `http://127.0.0.1:<port>`, and the CLI reuses the same one at the token
  exchange, so the redirect can never be pointed at the Mac's tunnel, and the
  phone cannot redeem the code itself (the PKCE verifier and the client secret
  live in the Mac's CLI process). What can move is the listener.
  `InfinitusLoopbackCatch.listen(port)` binds that port on BOTH of this
  phone's loopback addresses (gcloud's URI spells `localhost`, which resolves
  to ::1 first) and nothing beyond them — a port on the Wi‑Fi would let anyone
  there hand the Mac an authorization code of their own; `awaitRedirect()`
  resolves with the first request carrying a query (a favicon fetch never
  does), rebuilt verbatim — the browser's own `Host` kept whenever it spells
  this loopback on this port, since the Mac validates the name — after
  answering it a "you can close this page"; `stop()` gives the port back.
  `apps/mobile/src/features/infinitus/loopbackCatch.ts` binds it
  (`requireOptionalNativeModule`, so Android and a build without the module
  keep today's behaviour). The flow is in `InfinitusSignIns.tsx`: a row whose
  `state.callbackPort` says the Mac started a relay login (the contract already
  carries it, so no `redirect_uri` is parsed here) listens, opens the auth URL
  in an `expo-web-browser` sheet — `Linking.openURL` would background the app
  and Google blocks embedded webviews, so a `react-native-webview` is not an
  option — and hands the caught URL to the Mac as
  `infinitus.secret {command: "aws-login-callback", args: {profile}}`, the
  fork's one secret-carrying path: the URL holds the authorization code and
  never travels as an argument. The Mac side needed no change —
  `AwsLoginRunner.relay()` validates the URL and GETs it against the CLI's own
  listener. With a catcher `startSignInCommand` drops `--local`, so a login
  started from the phone is relayable too. `apps/mobile/.swiftlint.yml` lists
  the module's `ios/` directory.
- `apps/mobile/src/state/threadOutboxQueue.logic.ts` (+ `threadOutboxHolds.ts`)
  — the phone outbox's queue rule (#807, #270 F): `queueBehindRunningTurn`
  turns an existing thread's `send` into `wait` while the thread's session is
  `starting` / `running` or the server's hold list names it (any kind: held,
  paused, limited), so a follow-up typed during a turn lands after it instead
  of steering; creations and every other action pass through. `mode` at
  both call sites is `outboxQueueMode` of this phone's preferences
  (`infinitusComposerSendMode`, the desktop's "Sending while a turn runs",
  a `PickerRow` in `SettingsInfinitusSection.tsx` — `ControlPillMenu` on
  iOS, `AndroidAnchoredMenu` with the row as its function child on Android
  so the row's own press opens it): `"queue"` by default and
  while the store loads, `"steer"` sends into the running turn as upstream
  does — but a thread the server's hold list names waits in either mode.
  `resolveThreadOutboxDelivery` (#812) turns that `wait` into `"queue"` when
  the server's capabilities carry `turnQueue` (fork capability in
  `packages/contracts/src/environment.ts`, set true in
  `apps/server/src/environment/ServerEnvironment.ts`); `queueTurnCommandInput`
  is the `thread.turn.queue` an outbox message becomes.
  `readHeldThreads` reads the environment's `infinitusEnvironment.holds` atom
  from the registry (the web sidebar's idiom), null without the `infinitus`
  capability and before the list's first delivery, so the first pass after
  the app opens may send into a hold. The drain re-runs on every thread
  shell change, so a queued row leaves when the turn ends.
- `apps/mobile/src/features/infinitus/lanDiscovery.logic.ts` (+ `lanDiscovery.ts`,
  `InfinitusNearbyServers.tsx`) — "Find Macs on this network" on the
  add-connection form (#651): a sweep of the phone's private /24 for
  `/.well-known/t3/environment` on the desktop server's port (3773), no
  Bonjour (that needs a native module the Expo build lacks); a tap fills
  Host, the code is still typed. `ConnectionsNewRouteScreen.tsx` only mounts
  it above the Host field, and (#669) refuses to submit a host without a
  code: `missingPairingInput` in `pairing.ts` names the missing field
  ("Enter a pairing code.") in the banner, since a bare host built into a
  pairing URL would otherwise read as "Pairing URL is invalid."
  Follow-up (#661): a found row's Host is the server's own first
  `lanHttpBaseUrls` address (#757) when it reports one, rows are one per
  environment id (a Mac on two interfaces answers twice), and after "Use"
  the Add button waits for a pairing code with a hint under the code field
  (`pickedHostNeedsCode`); approve-on-Mac keeps its own button.
  After a sweep a line under the button says what it did (#787,
  `sweepSummary`): subnet, port, the phone's own address (expo-network's
  last `en*` IPv4 — a `169.254.x` or `100.x` there means the Wi‑Fi address
  was not the one picked, and nothing is swept), how many probes answered,
  timed out or failed, and the first failure's words; counts and addresses
  only.
  The session's first sweep gets one automatic retry (#787 hardening): iOS's
  Local Network prompt settles after the first probes go out, and those are
  misses for good, so `shouldRetrySweep` (first sweep since the app opened,
  probed something, not stopped, no server heard) has the page wait
  `SWEEP_RETRY_DELAY_MS` (2 s) with "looking once more…" and sweep again;
  the line then ends "Second sweep, 2 s after the first found nothing."
  (`SweepReport.retried`). A sweep that found a Mac, probed nothing or was
  stopped is not retried, nor is any later sweep.
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

- `scripts/fork-visual-pass.mjs` — the visual pass: one headless Chrome over
  CDP pairs with a running web app, clicks through the first-run wizard, then
  screenshots each route (`shot-<route>.png` + `text-<route>.txt`). Mint a
  token with `node apps/server/src/bin.ts pair` (from the server's worktree),
  then
  `node scripts/fork-visual-pass.mjs --pair-url <url> --out <dir> /accounts /settings/infinitus`
  (`--base-url`, `--cdp-port`, `--profile`, `--settle-ms`, `CHROME_BIN`; the
  token is never printed). No dependencies; node ≥ 22.
- `scripts/fork-visual-fixture.mjs` (+ `fork-visual-fixture.data.json`) — the
  Infinitus control socket the visual pass runs against in CI: a Node net
  server speaking the one-line protocol that answers `manifest`, `status`,
  `fleets`, `forecast`, `prefs`, `stats`, `events`, `aws-logins`,
  `client-activity` and `lock-status` with canned data. The manifest and
  the pref catalog are `infinitusctl` captures (every value reset to its
  default), trimmed with the Mac: the session-profile and past-session
  verbs and the three retired push prefs went with #1091, the Team and
  checkpoint blocks with #1139. The accounts
  (`ada-fixture`…) and the stats are made up. Every write and every unknown verb is refused with `ok: false`;
  only verb names are logged. `--socket <short /tmp path>`.
  `fork-visual-fixture.guard.test.ts` keeps the capture honest against
  `apps/mac/Sources/InfinitusCore/{ControlProtocol,PrefCatalog}.swift`
  (#1139, the `PREF_COPY` guard's sibling from #1122): a verb it claims or
  a pref key it carries after the Mac dropped one hands every capability
  gate in the web a `true` no real build gives, and the pages render in CI
  what a user cannot see. Commands are checked one way — the fixture
  answers only what the pass exercises, so a Mac verb it omits is fine —
  and it may answer no verb it does not claim; prefs and sections must
  match the catalog exactly.
- `scripts/fork-visual-routes.ts` (+ `.test.ts`) — the route table the pass
  asserts: every fork page with the one text marker only its populated render
  shows (a pref row's label or its value, "Thread priority", "Re-lock",
  "Session lengths"…) and the empty-state phrases that must not appear
  (`ALWAYS_ABSENT`: "not answering", "T3 Code" (#823: the upstream name never
  reaches a screen), "Fork " (a Mac pref key with no web copy humanises to
  "Fork …"), "Still connecting", "This Infinitus build has no", "could
  not be read"; per route "No projection yet", "no engine reports
  accounts"…). The test pins the route list, checks no marker is a substring
  of a nav label or card title (those print on a dead page too), and mirrors the
  harness's `text-<route>.txt` naming. `scripts/fork-visual-check.ts` applies
  it: `--routes` prints the routes for the harness's argument list, `--out
  <dir>` reads the captures and exits 1 on the first miss.

- `.github/workflows/fork-visual-pass.yml` — "Fork visual pass", on every PR
  to `main` and by hand: builds the web app, starts `fork-visual-fixture.mjs`
  on `/tmp/inf-vp.sock`, runs the server from source (`bin.ts start
--no-browser`, `--base-dir` under the runner's temp dir,
  `INFINITUS_CONTROL_SOCKET` at the fixture — the override also withholds the
  companion's `open` and the port publish), mints a pairing URL with `bin.ts
pair` (token masked, server log never uploaded), screenshots every route in
  `fork-visual-routes.ts` with the runner's Chrome through
  `fork-visual-pass.mjs`, then `fork-visual-check.ts` fails the job on a
  missing marker or an empty state. The PNGs and text captures upload as the
  `fork-visual-pass` artifact, on failure too. Runner fact (#825 hung 17 min
  at the start step with nothing logged; #831 starts in 3 s): a step that
  backgrounds a server must detach it — `setsid nohup … > log 2>&1
< /dev/null &` — and probe with `curl --max-time`, or the step holds the job
  to its timeout.

- `.github/workflows/infinitus-nightly.yml` — the nightly (#1042, "One
  release" above): a `version` job dates the root `VERSION`, `build` is
  `infinitus-release.yml` through `workflow_call` with that version
  (`secrets: inherit`, so the Mac job signs and notarizes as for a release),
  `publish` — `main` only, on the schedule or a dispatch with `publish` —
  force-moves the `nightly` tag, clobbers the assets, removes older nights'
  versioned assets and edits the title.
- `.github/workflows/infinitus-release.yml` — the one release (see
  "One release" above). Its `desktop` job nests the menu bar app as a login
  item (#777): the `mac` job of the same run uploads `Infinitus-Menu-Bar-<version>.zip`
  (the nested build: CFBundleName "Infinitus Menu Bar", no `infinitus://` URL
  type; the standalone `Infinitus-<version>.zip` and its Homebrew cask left
  with #1238),
  which `desktop` unpacks, checks (bundle id `run.infinitus`, version equal
  to the release's; on signed builds Developer ID from team `Q783W6B4FA`,
  hardened runtime, `stapler validate`) and hands to the build script as
  `T3CODE_DESKTOP_NATIVE_HELPER` / `--native-helper`. The script `ditto`s it
  into the stage (`NATIVE_HELPER_STAGE_DIR`), electron-builder's `extraFiles`
  places it at `Contents/Library/LoginItems/Infinitus Menu Bar.app` (the one
  path `SMAppService.loginItem` accepts) before the outer bundle is signed,
  and `signIgnore` keeps `scripts/sign-macos.ts` off it, so the helper keeps
  the native release's signature, entitlements and stapled ticket while the
  outer seal records it as nested code; the one built-in notarization covers
  both. "Verify nested helper" proves the nested seal survived packaging and
  that Electron's `allow-jit` entitlement never reached it. Local and
  upstream builds pass no helper and nest nothing. The helper is never
  rebuilt in the desktop job (macOS 26 SDK, Swift toolchain and a second
  sign/notarize path for a bundle the `mac` job already sealed).
  Its `cli` job builds the self-contained CLI archives every runtime
  installer downloads (#1192): `t3-<version>-linux-x64.tar.gz` and
  `-linux-arm64.tar.gz`, which `publish` attaches along with the
  `SHA256SUMS` `pinnedRuntime` verifies against. Linux only — that is where
  SSH remote environments run; a Mac or Windows CLI has no archive and the
  installers 404 plainly instead of reaching upstream (`CLI_RELEASE_REPOSITORY`
  below). Its steps are upstream's `cli_archive` steps from
  `.github/workflows/release-desktop.yml`, **copied rather than called**:
  that workflow downloads a `js-bundle` artifact only upstream's
  `build_bundle` produces, plus a relay tracing config and four required
  clerk/relay inputs the fork has no source for, so calling it would mean
  porting half of upstream's release pipeline. Re-diff the copied steps
  against that file on every sync, like the runner swap. The job is skipped
  for the nightly (`inputs.version` is set only by the nightly's
  `workflow_call`), so a nightly desktop's SSH remotes fail cleanly; a
  dispatch dry run still builds them. Known gap (#1196): the archive's
  `client/` is the plain `t3#build` output, so it carries upstream's
  favicons — the fork's `applyWebBrandAssets` pass runs only in
  `scripts/build-desktop-artifact.ts`, and a remote runtime serves that
  client on its own origin.

- `packages/contracts/src/providerProxy.ts`, `apps/server/src/provider/proxyModels.ts`,
  `apps/web/src/components/settings/proxyProvider.ts`,
  `apps/web/src/components/settings/ProxyProviderFields.tsx` — "Route through a
  proxy" for a Claude instance: 9Router / CLIProxyAPI / custom presets, model
  slots picked from the proxy's `GET <baseUrl>/models`, everything stored on
  the ordinary instance (env vars + CLAUDE_CONFIG_DIR), no settings file written.
