# Infinitus fork — rules on top of AGENTS.md

This `main` is a fork of [T3 Code](https://github.com/pingdotgg/t3code) that
drives the Infinitus engine. AGENTS.md (upstream's guide) applies in full;
this file adds the fork's own rules. Plan and history: issue #555.
Unification (#823, user ruling 2026-09-11): the product is one name,
Infinitus — no user-facing "fork", "native" or "T3 Code" anywhere (layer 1);
the Swift app moves into `main` as `apps/mac` (layer 2) and one version
`0.5.0-alpha.N` ships everything from one release (layer 3). "Fork" and
"native" below are contributor shorthand for this TypeScript tree and the
Swift app while those layers land; each layer rewrites the paragraphs it
makes wrong, in its own PR.

## Non-negotiables

- **Never an upstream PR.** Upstream is merged in, not contributed to. Do not
  open pull requests, issues or discussions on `pingdotgg/t3code` from this
  work.
- **One API.** The fork talks to Infinitus only over its control socket
  (`ControlProtocol`: one JSON line each way; `infinitusctl manifest` is the
  runtime command table — its reply shapes are prose, so reply schemas are
  hand-written in `packages/contracts` and validated at the boundary) and
  the mirror HTTP routes — the same wire the phone and the
  Linux tray use (inventory: issue #553). Anything missing becomes a new
  route on the `native` branch, never a second protocol or a read of the
  native app's files.
- **Upstream merges daily, our history never rebased.** `git fetch upstream
&& git merge upstream/main` on a branch, PR to `main`. Our code lives in
  new files, new routes, new settings sections; edits to upstream files stay
  at registration points so merges stay small. The list of upstream files we
  edit on purpose is in "Registration points" below — keep it current.
- **`native` is the Swift app.** Today's native Infinitus (menu bar,
  engines, team, tunnels, mirror API, control socket, PTY host, Linux tray)
  lives on the `native` branch with its own CLAUDE.md, CI and releases.
  Never merge `main` into a native branch or `native` into `main` (unrelated
  histories).
- **Fork releases are GitHub prereleases with their own tag scheme.**
  Installed native apps poll `releases/latest` and the `nightly` tag; those
  stay native forever. Never publish a fork release as latest, never tag
  `nightly` from `main`. The fork's desktop releases are prereleases tagged
  `v<version>-infinitus.<date>.<run>` and served on the `infinitus` updater
  channel (manifest `infinitus-mac.yml`), built by "Fork desktop release".
  On that channel an available update downloads itself
  (`DesktopUpdates.autoDownloadOnForkChannel`); upstream keeps the download
  behind a click, and a click that raced a relaunch started over.
- **PR-only main** (ruleset "main via pull requests"): required checks are
  T3's CI jobs Check, Test, Test Server 1–3. `gh pr create --base main`,
  `gh pr merge --squash --auto`. Every commit carries
  `Co-Authored-By: Claude Code <noreply@anthropic.com>`.
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
- `packages/contracts/src/environment.ts` — the `infinitus` capability on
  `ExecutionEnvironmentCapabilities`; `alternateHttpBaseUrls` (optional) on
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
  was typed) and the picker model as a custom model.
- `packages/contracts/src/keybindings.ts` + `packages/shared/src/keybindings.ts`
  — `captures.toggle` (`mod+alt+c`) and `captures.add` (`mod+alt+shift+c`),
  both `!terminalFocus`, in `STATIC_KEYBINDING_COMMANDS` and
  `DEFAULT_KEYBINDINGS` (#433); `accounts.open` the same way;
  `thread.nextAttention` (`mod+shift+l`, `!terminalFocus`) in
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
  published `t3.json` schema); the two exact-env assertions in
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
  `searchSlashCommandItems`, and `pickComposerMenuItem` has a
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
  (#648). `InfinitusPairingLive` (provided `AuthLayerLive`) beside them, and
  `infinitusPairingHttpApiLayer` in the `HttpApiBuilder.layer` provides
  (#710). `InfinitusSessionHoldLayers` in `ReactorLayerLive` (#616): the hold,
  and the `TurnStartGate` it implements; `InfinitusSessionInterruptLive` just
  before it (#743), a consumer of that gate. `CaptureStore.layer` (#433) in the
  state-dir file services' `Layer.mergeAll` beside `Keybindings.layer`.
- `apps/server/src/orchestration/Layers/ProviderCommandReactor.ts` — the turn
  start's session start + send run through `TurnStartGate.start` (#616);
  `serverRuntimeStartup.ts` — the post-update continuation's forked send does
  the same. Their test harnesses (`ProviderCommandReactor.test.ts`,
  `serverRuntimeStartup.reconcile.test.ts`, `AgentSessionImporter.test.ts`)
  provide the passthrough gate, with a `turnStartGate` override in the first two.
- Chat-only rewind (#270 E1): `packages/contracts/src/orchestration.ts` —
  `thread.chat.rewind {threadId, turnCount}` (client-dispatchable, beside
  `thread.checkpoint.revert`) and the `thread.chat-rewind-requested` event
  (same payload as the revert request); `apps/server/src/orchestration/decider.ts`
  — its case; `Layers/CheckpointReactor.ts` — `handleChatRewindRequested`: the
  revert's guards and provider rollback, no checkpoint restore, workspace
  refresh or ref deletion, completing through the existing
  `thread.revert.complete` → `thread.reverted` so every projection prunes the
  later turns as for a revert (files and git checkpoint refs stay; the span
  carries `filesRestored: false`); `packages/client-runtime` `commands.ts` /
  `threadCommands.ts` — `rewindThreadChat` / `rewindChat`; `threadReducer.ts`
  — the event is a no-op; `apps/web` `ChatView.tsx` `onRevertToTurnCount(turnCount, mode)`
  with the chat-only confirm ("Files stay as they are"), `MessagesTimeline.tsx`
  — the user-row revert button is a menu: "Revert files and chat" /
  "Rewind chat only" (`TimelineRevertMode`). Test in `CheckpointReactor.test.ts`.
- Server-side message queue (#806, the server half of #270 F):
  `packages/contracts/src/baseSchemas.ts` — `QueueId`;
  `packages/contracts/src/orchestration.ts` — `OrchestrationQueuedTurn`,
  `queuedTurns?` on `OrchestrationThread` and `OrchestrationThreadShell`
  (optional; absent when empty so pre-queue payloads still decode), the
  commands `thread.turn.queue` (client variant carries uploads like
  `thread.turn.start`'s), `.queue.update`, `.queue.remove`, `.queue.move`,
  `queuedFrom?` on both turn-start commands, and the events
  `thread.turn-queued` / `-queue-updated` / `-queue-removed` (`reason:
user | sent`) / `-queue-moved`; `packages/shared/src/orderKeys.ts` — the
  fractional key helpers moved out of `client-runtime` `threadSort.ts` (which
  re-exports them as `pinOrderKeyBetween` / `generateSpreadPinOrderKeys`) so
  the decider validates and defaults a key; `apps/server/src/orchestration/decider.ts`
  — the four cases (queue is idempotent by re-emission, update/move refuse a
  missing row, remove re-emits) and the turn start's `queuedFrom` removal in
  the same batch (a row already gone changes nothing); `projector.ts`,
  `Schemas.ts`, `packages/client-runtime` `threadReducer.ts` — the events on
  the in-memory thread; `Layers/ProjectionPipeline.ts` — the rows in
  `projection_thread_queued_turns` (migration `051`, `persistence/ProjectionThreadQueuedTurns.ts`),
  dropped with the thread; `Layers/ProjectionSnapshotQuery.ts` — the rows on
  every thread read (snapshot, command read model, shells, detail);
  `Normalizer.ts` — the queue commands' uploads stored like a sent
  message's; `apps/server/src/server.ts` — `InfinitusTurnQueueLive` in
  `ReactorLayerLive` above the interrupt and hold layers it consumes;
  `Services/InfinitusSessionInterrupt.ts` — `paused` stream (like the
  hold's `held`). Fork-only: `apps/server/src/infinitus/Layers/InfinitusTurnQueue.ts`
  (+ `infinitusTurnQueue.logic.ts`, test) — the drain: sends a thread's
  first row as `thread.turn.start {queuedFrom}` when the thread is idle
  (`queueDrainVerdict`: no turn running, starting or pending, not held,
  not paused, not archived, no send of its own in flight; `error` sessions
  never, see #832), one send per thread at a time; wakes on session-set,
  the queue events, unarchive, a failed start, a hold or pause letting the
  thread go, and once at boot after the hold and interrupt layers have
  published their first lists (5 s cap). A send the decider rejects leaves
  the row; a provider failure after the send has already consumed it.
- Fork from a turn (#270 E2): `packages/contracts/src/infinitus.ts` —
  `InfinitusThreadForkInput/Result`, `InfinitusThreadForkRefused`; `rpc.ts` —
  `infinitus.forkThread` (`AuthOrchestrationOperateScope` in
  `RpcAuthorization.ts`); `apps/server/src/ws.ts` — the handler;
  `apps/server/src/provider/Layers/ClaudeAdapter.ts` — the resume cursor
  carries `anchors` (`{turnId, at}`: each completed turn's last assistant uuid keyed
  by the orchestration turn id, so a session restart cannot renumber them;
  ≤ 200, trimmed on rollback) and `fork: true`; a forked thread's first start
  passes `forkSession` + `resumeSessionAt` to the SDK and starts its own
  anchors; `packages/client-runtime/src/state/infinitus.ts` — `forkThread`;
  `apps/web` `ChatView.tsx` — `supportsThreadFork` (Claude driver only),
  mode `fork` on `onRevertToTurnCount` (no confirm; navigates to the new
  thread), `MessagesTimeline.tsx` — the third menu item. Fork-only:
  `apps/server/src/infinitus/ThreadFork.ts` (+ test): `forkThreadAtTurn` —
  binding first (insert-ignore: `resume` = the source session, the turn's
  anchor as `resumeSessionAt`, `fork: true`), then `thread.create
{historyImport: true}` on the source's branch and worktree, then
  `thread.history.import` of a provenance marker ("Forked from **title** at
  turn N") plus the source's user/assistant text up to that turn
  (`forkSeedMessages`: by turn id, unattributed rows by time). The source
  thread is never mutated. Codex has no fork point yet (issue filed).
- `packages/contracts/src/settings.ts` — `infinitusResumeOnLimit` on
  `ServerSettings` (default on) and `ServerSettingsPatch` (#648); the
  `PromptSnippet` schema with its caps and `projectPromptSnippets`
  (`Record(ProjectId, NullOr(Array(PromptSnippet)))`, default `{}`) on both
  (#270 G). `packages/shared/src/serverSettings.ts` —
  `applyServerSettingsPatch` merges `projectPromptSnippets` per project key
  like `projectScriptOverrides`, so one project's save leaves the others.
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
  with `queuedFrom`; edit = fetch the attachments back through the asset
  URL, `.queue.remove`, text and files into the composer; move =
  `.queue.move` with `queuedTurnMoveKey`; remove); `ComposerSendQueue.tsx`
  renders them; `composerSendQueue.logic.ts` (+ test) — `orderedQueuedTurns`,
  `queuedTurnSnippet`, `queuedTurnEditableText`, `queuedTurnMoveKey`, and
  the legacy-stash helpers; `hooks/useLegacyQueueMigration.ts` (mounted in
  `routes/_chat.tsx`) — moves entries the stash still holds with `queuedFor`
  (#270 F, pre-#806) to the server once, ids derived from the entry, a
  refused one becoming a plain stash entry (`promptStashStore.unqueueEntry`);
  `ComposerPrimaryActions.tsx` — `runningSendMode` keeps the send button
  beside Stop while running, labelled "Queue message" / "Send now";
  `SettingsPanels.tsx` + `settingsSearch.ts` — the "Sending while a turn
  runs" row. Client-runtime: `operations/commands.ts` + `state/threadCommands.ts`
  — `queueTurn` / `updateQueuedTurn` / `removeQueuedTurn` / `moveQueuedTurn`.
- `packages/contracts/src/ipc.ts` — the fork's optional `DesktopBridge`
  methods: `getInfinitusDesktopPrefs` / `setInfinitusQuitWithApp` (#654),
  `openInfinitusSignIn` / `closeInfinitusSignIn` /
  `submitInfinitusSignInCode` (#677), and `setInfinitusCaptureGestureEnabled`
  / `onCaptureGestureEvent` with the `DesktopCaptureGestureEvent` schema
  beside `DesktopSnapShotEvent` (#433 slice 2), and `consumePendingDeepLink`
  / `onDeepLinkPending` with the `DesktopDeepLink` schema after it (#270 D).
  `packages/contracts/src/infinitus.ts`
  — `captureGestureEnabled` on `InfinitusDesktopPrefs`;
  `packages/contracts/src/captures.ts` — `MAX_CAPTURE_TEXT_LENGTH`, the cap
  the desktop's selected-text helper cuts at.
- `apps/desktop/src/ipc/channels.ts`, `apps/desktop/src/ipc/DesktopIpcHandlers.ts`,
  `apps/desktop/src/preload.ts` — the channels, `ipc.handle` lines and
  preload entries for those methods; `apps/desktop/src/main.ts` —
  `InfinitusDesktop.layer` in `desktopApplicationLayer`.
  `apps/desktop/src/app/DesktopPreReadyPlatform.ts` — `deepLinkIntake.attach`
  at the end of the pre-ready setup, and `DesktopEarlyElectronStartup.ts`
  exports `isDevelopmentEnvironment` for its scheme (#270 D).
- `apps/web/src/routes/__root.tsx` — `DeepLinkCoordinator` mounted beside
  `DesktopAppActivationCoordinator` (#270 D).
- `apps/server/src/server.test.ts` — a `Layer.mock(InfinitusService)` in the
  harness's stub stack, since the routes layer now needs the service; a
  `Layer.mock(InfinitusPairing)` and a `Layer.mock(CaptureStore)` beside it.
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
- `packages/shared/package.json` — the `./productName`, `./homeDir` and
  `./desktopIdentity` exports.
- `apps/desktop/src/app/DesktopEnvironment.ts` — `userDataDirName` comes from
  `@t3tools/shared/desktopIdentity` (`infinitus-desktop` / `infinitus-desktop-dev`), plus the
  `adoptsLegacyUserDataDir` flag that gates upstream's legacy-directory rule.
- `apps/desktop/src/**` — the same rule and guard test, allowlisting the
  installed app's real `T3 Code (Alpha)`/`(Dev)` directory names and the KDE
  component name; `resolveDesktopAppBranding` titles a fork release plain
  `PRODUCT_NAME` (no stage suffix) and keeps upstream's `(Dev)`/`(Nightly)`/
  `(Alpha)` otherwise.
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
- `apps/desktop/gnome-extension/metadata.json` — the bundled extension is
  named "Infinitus SnapShots" (uuid `snap-shot@t3.codes` unchanged), matching
  the setup copy that tells the user to find it; `KdeSnapShot.ts`'s desktop
  entry `Name=` follows `PRODUCT_NAME` the same way (#601).
- `scripts/lib/brand-assets.ts` — the `infinitus*` entries in
  `BRAND_ASSET_PATHS`, the `infinitus` `WebAssetBrand` (favicons, apple-touch),
  and `resolveWebAssetBrandForPackageVersion` mapping `-infinitus.` versions to it.
- `apps/desktop/scripts/electron-launcher.mjs` — `APP_PROTOCOL_SCHEMES`
  mirrors the shared constants (a node script cannot import the workspace's
  TypeScript); the dev-only bundle id stays `com.t3tools.*`. The dev bundle
  and its helpers are named "Infinitus (Dev)" and the macOS usage prompts say
  Infinitus (#823 layer 1); `apps/desktop/package.json`'s `productName` is
  "Infinitus (Dev)" too (packaged builds get theirs from
  `scripts/build-desktop-artifact.ts`).
- `apps/web/src/components/settings/SettingsPanels.tsx` (+ `.logic.ts`) —
  `resolveDesktopUpdateTrackRow`: an `infinitus` build shows its own track
  read-only instead of "Stable" with a one-way switch to upstream's releases.
- Upstream tests carrying the renderer origin or the userData directory
  (`DesktopAppIdentity`, `DesktopClerk`, `ElectronProtocol`, `DesktopWindow`,
  `DesktopLinuxUrlHandler`, `DesktopPreReadyPlatform`, `server.test.ts`,
  `build-desktop-artifact.test.ts`, and the web fixtures that stub a desktop
  origin) use the fork's scheme.
- `knip.jsonc` — `scripts/fork-visual-pass.mjs`, `fork-visual-fixture.mjs` and
  `fork-visual-check.ts` as scripts entries (run by hand and by the
  fork-visual-pass workflow; nothing imports them).
- `apps/mobile/app.config.ts` — the `infinitus` app variant (bundle id
  `run.infinitus.mobile`, the Infinitus Apple team, the native phone's icon;
  `appleTeamId` per variant), selected with `APP_VARIANT=infinitus`; its
  `universalLinkHost` (`infinitus.run`, #724) adds `applinks:infinitus.run`
  to the iOS associated domains and an `autoVerify` intent filter for
  `https://infinitus.run/pair` on Android (the site serves the AASA
  `applinks` for `Q783W6B4FA.run.infinitus.mobile` and `assetlinks.json`).
- `apps/mobile/src/Stack.tsx` — the `SettingsAccounts` route (Settings ›
  Accounts, the Infinitus fleet per paired Mac).
- `apps/mobile/src/features/settings/components/settings-sheet-targets.ts` —
  `SettingsAccounts` in the settings target union.
- `apps/mobile/src/features/settings/SettingsRouteScreen.tsx` — the
  `SettingsInfinitusSection` (Accounts row, Live Activity / Mac alerts /
  reset alarms toggles, pusher Mac) after General.
- `apps/mobile/src/App.tsx` — `appLinking` rewrites an incoming universal
  link `https://infinitus.run/pair#token=…&for=phone&to=<origin>` into the
  `environment-new?pairingUrl=<origin>/pair#…` route (`getInitialURL` /
  `subscribe`, `features/connection/universalPairLink.logic.ts`, #724): the
  Mac's origin travels in the fragment the site never sees, `to` is taken as
  a bare http(s) origin only, and the sheet fills Host and code like a
  scanned QR (#746) — the same rewrite runs on the in-app scanner's payload
  and on the route's `pairingUrl`. Mounts `InfinitusLiveActivityBridge` (Live
  Activity token registration with the Mac), `InfinitusAlarmsBridge`
  (local reset / swap alarms), `InfinitusAlertPushBridge` (the `alert`
  token, so the Mac's pushes reach the phone as banners; both bridges
  withdraw their kinds with `activities-token --forget <deviceId>/<kind>`
  through `pushForget.ts` / `pushForget.logic.ts` when their switch goes off,
  #702) and
  `InfinitusNotificationPresenter` (the app's one foreground notification
  handler: Infinitus notifications show as banners in-app, T3's keep the
  no-handler default).
- `apps/mobile/src/persistence/mobile-preferences.ts` — the
  `infinitusLiveActivityEnabled` / `infinitusLiveActivityMac` /
  `infinitusAlarmsEnabled` / `infinitusPushAlertsEnabled` /
  `infinitusPinAtCreation` (#742) keys (interface and sanitizer).
- `apps/mobile/src/features/threads/ThreadDetailScreen.tsx` — the optional
  `infinitusHoldBanner` slot (a `ReactNode` in the composer stack after the
  feedback notices, #742); `apps/mobile/src/features/threads/ThreadRouteScreen.tsx`
  builds `InfinitusHoldBanner` from the thread's detail for it (never for a
  queued creation), and prepends `usePullRequestHeaderItem`'s menu to the
  iOS header's git items with its `version` in `optionsVersion` (#269 F: the
  PR's phase from the linked snapshot, Open pull request / View checks / Mark
  ready for review over `pullRequests.runAction`;
  `apps/mobile/src/features/infinitus/prHeader.logic.ts`, `pullRequestActions.ts`).
- `apps/mobile/src/features/threads/thread-list-v2-items.tsx` — an idle
  active row whose current linked PR is open, out of draft, with green (or
  no) checks and no verdict reads "Ready for review" in place of its time
  (`useThreadReadyForReview`, #269 F); settled rows keep their stamp.
- `apps/mobile/src/features/threads/NewTaskDraftScreen.tsx` — mounts
  `InfinitusPinAtCreationControl` after the Plan/Build pill in the composer's
  control row (#742); `apps/mobile/src/state/use-thread-outbox-drain.ts` —
  `usePinAtCreation` runs once a queued creation is delivered, right after the
  "delivered" outcome is recorded (its test, `use-thread-outbox-drain.test.ts`,
  mocks `./preferences` so the drain's module graph stays clear of
  expo-secure-store). The two `resolveThreadOutboxDeliveryAction` calls (the
  pass and the live re-check before a send) are wrapped in
  `queueBehindRunningTurn` (#807): an existing thread's follow-up waits while
  its turn runs or the server holds it, the phone's copy of the desktop
  composer's queue (#270 F); the test mocks `./threadOutboxHolds` too.
- `apps/mobile/src/features/home/HomeScreen.tsx` — the thread list's header:
  the `InfinitusHomeChip` on iOS (whose native header has no slot for it) and
  `InfinitusSignIns` (lapsed AWS / gcloud sign-ins of paired Macs).
- `apps/mobile/src/features/home/HomeHeader.tsx` — the `InfinitusHomeChip`
  (active account + fullest window of the Mac the list follows, plus its
  waiting-session count) before the filter button, in the Android header; its
  brand slot (and `components/CompactBrandTitle.tsx`, the iOS one) shows
  `PRODUCT_NAME` where upstream draws the T3 glyph + "Code" (#601).
- `apps/mobile/src/features/review/shikiReviewHighlighter.ts`,
  `apps/mobile/src/features/diffs/nativeReviewDiffHighlighter.ts` — an
  explicit `tokenizeTimeLimit` (5 s) on both `codeToTokensBase` calls: shiki's
  500 ms default is spent by a cold JavaScript regex engine compiling its
  patterns, which fused the first line into one token on loaded CI (#610).
- `apps/web/src/components/settings/settingsSearch.ts` — the ten Infinitus
  `SettingsPath`s and their labels (Themes and Animations since #747 step 1,
  Sessions since #743, Lock and Team since #747 step 3), the `infinitusOnly` search flag with the
  `hasInfinitusEnvironment` availability it reads, and
  `isSettingsSectionActive` so a nested page's nav item is the only one lit.
- `apps/web/src/lib/infinitusCompletionSound.ts` (+ `.logic.ts`,
  `components/desktop/InfinitusCompletionSoundCoordinator.tsx`,
  `components/settings/InfinitusCompletionSoundRow.tsx`,
  `assets/infinitus-completion-chime.wav`) — the completion sound (#270 H):
  a turn finishing on any thread while the window is hidden or unfocused
  rings the picked sound (Chime, or the SnapShot Whoosh / Click), off by
  default. The preference is per window in localStorage
  (`infinitus:completion-sound:v1`), not a client setting: a sound belongs
  to the machine that plays it. `turnsJustCompleted` rings only for threads
  the window already knew (a bootstrap seeds, never rings). Registration
  points: the coordinator mounted from `__root.tsx` beside
  `SnapShotCoordinator`, the row from `SnapShotSettings.tsx` after the
  capture sound, and the `completion-sound` search item in
  `settingsSearch.ts`.
- `apps/web/src/lib/desktopNotifications.logic.ts`,
  `apps/web/src/components/desktop/DesktopNotificationCoordinator.tsx`,
  `apps/web/src/components/settings/DesktopNotificationSettings.tsx`,
  `apps/desktop/src/electron/ElectronNotification.ts`,
  `apps/desktop/src/ipc/methods/notifications.ts` — the desktop's OS
  notifications and Dock badge (#270 B). The renderer decides: one banner
  per thread this window already knew that moves into approval, input,
  held or failed, or (off by default) reaches a completed turn it had not
  seen completed — the completion sound's rule; the thread on screen while
  the window is focused stays quiet. The badge counts the threads in
  approval or input. The main process only shows (`Electron.Notification`,
  a no-op where unsupported) and, on a click, reveals the window on the
  thread over `NOTIFICATION_ACTIVATED_CHANNEL` (`DesktopWindow.
dispatchNotificationActivated`). Fork-thread events only: the account
  events (a limit, every account dead, revived) stay the native app's
  Notification Center items. Six client-setting booleans
  (`desktopNotifyOn*`, `desktopBadgeAttention`) in
  `packages/contracts/src/settings.ts`; the `DesktopBridge` methods
  `postNotification` / `setBadgeCount` / `onNotificationActivated` and the
  `DesktopNotificationRequest` / `DesktopNotificationActivated` schemas in
  `packages/contracts/src/ipc.ts`, all optional. Registration points: the
  coordinator mounted from `__root.tsx` after the completion sound (primary
  environment authenticated), the settings section as the notifications
  pane's `lead`, the `desktop-notify-*` / `desktop-badge` search items, the
  three channels in `apps/desktop/src/ipc/channels.ts`, the two handlers in
  `DesktopIpcHandlers.ts`, `ElectronNotification.layer` in `main.ts`, and
  the preload's `isNotificationActivated` guard.
- `apps/web/src/components/settings/SettingsSidebarNav.tsx` — an icon per
  Infinitus path and the capability filter that hides all ten where no
  connected server reaches an Infinitus app.
- `apps/web/src/components/settings/useAvailableSettingsSearchItems.ts` —
  fills `hasInfinitusEnvironment` from the environments' capabilities.
- `apps/web/src/components/settings/settingsSearch.test.ts` — the availability
  records it builds gained that field.
- `apps/web/src/routes/pair.tsx` — one early return: a link with the phone
  marker (`isPhonePairingLink`, #724) renders `InfinitusPhoneLinkSurface`
  instead of the pairing form, so the browser does not spend a phone's token.
- `apps/web/src/routes/settings.infinitus*.tsx` (ten new files in upstream's
  routes directory; Themes and Animations are `InfinitusPrefsPanel` pages over
  the catalog's `themes` / `animations` sections, #747 step 1, and Sessions
  over its `sessions` section (#743: `priority_mode` with the `interrupt`
  choice, `priority_low_pct`, `priority_abundant_pct`, copy in `PREF_COPY`) —
  the Menu bar page keeps `display` + `about`; a section the build lacks
  renders "no … settings yet"; Lock is `InfinitusLockPanel` and Team
  `InfinitusTeamPanel`, #747 step 3) and
  `apps/web/src/routeTree.gen.ts` — regenerated with
  `@tanstack/router-generator`, never edited by hand.
- `apps/web/src/routeTree.gen.ts` — regenerated (with the installed
  `@tanstack/router-generator`, never hand-edited) whenever a fork route is
  added; the upstream sync re-generates it.
- `apps/web/src/components/sidebar/SidebarChrome.tsx` — the Accounts utility
  item and its `infinitus` capability gate, the footer's
  `SidebarInfinitusSessions` group and `SidebarAccountsPill`, and `/accounts`
  in the `currentFooterPage` selector (so the Back button appears on the page).
- `packages/contracts/src/keybindings.ts` — `accounts.open` in
  `STATIC_KEYBINDING_COMMANDS`.
- `apps/web/src/components/CommandPalette.tsx` — the "Open accounts" action and
  the `keydown` listener that turns `accounts.open` into a navigation, both
  behind the `infinitus` capability.
- `README.md` — the fork notice at the top.
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
  Screenshots, Thread Transfer Report) are disabled in the repository's
  Actions settings, not deleted, so merges stay clean.

## Fork-only files

- `apps/web/src/components/settings/infinitus/` — the Infinitus settings panes
  (preferences, Engines, Profiles) and their pure logic, and the Devices
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
  (an account switch, every account exhausted, a session waiting for an
  answer) as the app's toasts; nothing from the first snapshot, deduped by
  the server's event id. Every toast has one Open action
  (`toastAction`): the waiting session's own window (`show session <pid>`,
  #612) while the manifest's `show` takes a session, otherwise a page of
  this app — /accounts for a limit or a switch, /activity for a waiting
  session; `show` is never sent without a session since the pop-out and
  session windows retired (#670). Mounted once from `apps/web/src/routes/__root.tsx`
  (an upstream file: that line and `CaptureGestureCoordinator`'s are the
  fork's only edits there).
- `apps/web/src/components/settings/infinitus/InfinitusLockPanel.tsx` (+
  `lock.logic.ts`, route `settings.infinitus.lock.tsx`) — Settings › Infinitus
  › Lock (#747 step 3): the Mac's biometric lock over `infinitus.command`'s
  `lock-status` / `lock on|off [--yes]|now|relock <arg>` / `unlock` (native
  #788), each answering `{enabled, locked, relock}`. The switch turns the
  lock on (the Mac's own prompt runs there; the row says "Confirm on the
  Mac" while it waits) or off; a `lock off` refused inside a team ("this Mac
  is in …; lock off --yes …") becomes a Keep on / Turn off confirm whose
  Turn off sends `--yes`. Re-lock is a select over the four native labels
  (`RELOCK_CHOICES` maps "5 min" ↔ `5m` and so on); the status row offers
  Lock now or Unlock (the unlock prompt runs on the Mac too). Every error is
  the app's text verbatim; the pane holds no secret. Gated on the manifest
  carrying all three verbs, else "no lock commands (needs ≥ 5bc33fa5c0)".
- `apps/web/src/components/settings/infinitus/InfinitusTeamPanel.tsx` (+
  `team.logic.ts`, route `settings.infinitus.team.tsx`) — Settings › Infinitus
  › Team (#747 step 3): `team-status` over `infinitus.command` (null = no
  team) drawn as the team row (name, role, masked remote, last fetch /
  publish, Fetch now → `team-fetch`, Publish now → `team-publish` then a
  read), the Members roster, and for a leader the Requests with Approve /
  Decline (`team-approve` / `team-decline <kid>`). With no team, Join: this
  Mac's roster name as the manifest's `<your name>` positional (so the
  `infinitus.secret` args key is literally `"your name"`), the team code or
  invite link on `secret` — a `type="password"` `autoComplete="off"` field
  held in memory only, cleared on submit and gone with the page; the Mac's
  error verbatim and the code never interpolated. The server's four secret
  refusals get a plain sentence each (`infinitusSecretFailure`). Create a
  team (no team only): team name, your name and the empty private repo's URL
  as the manifest's `name` / `--remote` / `--as` (args keys `name`, `remote`,
  `as`); a write token, when the remote needs one, rides `secret` over
  `infinitus.secret`, and with the token field empty the same verb goes over
  `infinitus.command` (an ssh remote, a credential-less one) — no empty
  secret is ever sent. Hostnames (leaders only): the Cloudflare zone and
  label member hostnames are minted under as `--zone` / `--label` (args keys
  `zone`, `label`) with the API token on `secret`, answered `{zone, label,
configured}` and drawn as the configured row with Forget token, which is
  `team-hostname --clear` over `infinitus.command` (no stdin) and answers
  `{zone: null, label: null, configured: false}`; the Mac has no read for the
  ledger, so the form shows until a save answers. Gated on `team-status`;
  Join also on `team-join`, Create on `team-create`, Hostnames on
  `team-hostname`, each with `stdin: "secret"`.
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
- `apps/web/src/components/deepLinks/` — the desktop's deep links landing
  (#270 D): `DeepLinkCoordinator` pulls the shell's latest link once the
  primary environment is connected and on every `onDeepLinkPending` ping;
  `thread` navigates to `/$environmentId/$threadId`, `new` resolves the
  project (`deepLink.logic` `resolveDeepLinkProject`: id, then title, then
  workspace-root basename, case-insensitive) and opens the composer through
  `useNewThreadHandler` with the prompt set on the draft — never sent; an
  unknown project toasts. `join` (`infinitus://join/<code>`, the native
  app's team join link, the whole link text being the code) offers the
  code to `pendingTeamJoin.ts` (in memory only, taken once) and opens
  Settings › Infinitus › Team, whose Join field picks it up
  (`InfinitusTeamPanel.tsx`); the request leaves only on the user's tap,
  over `infinitus.secret`. Only the link's kind is ever logged.
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
- `apps/web/src/routes/machine.tsx`, `apps/web/src/components/machine/` — the
  `/machine` page (#659): the pop-out's Machine pane in the fork, read-only —
  the sample summary (load, swap, processes, WindowServer, temp entries,
  Claude sessions' RSS), warnings, hooks grouped by owner, runaways, residue
  and the sessions table. Reads `machine` through
  `infinitusEnvironment.machine`, a query atom re-read every minute only
  while the page is mounted (native samples at most once per 55 s) and
  dropped a minute after it leaves; a `{sampling: true}` first reply is
  re-read once after 5 s. Its read model is
  `packages/client-runtime/src/state/infinitusMachine.ts` (exported as
  `@t3tools/client-runtime/state/infinitusMachine`): only the rendered
  fields are declared (Swift enums such as `source` travel in their
  `{"case": {"_0": …}}` shape and are ignored), `heavy`/`risky`/`stuck`
  ported verbatim from `HookInventory`/`MachineReport`. Unlike native's
  owner-name order, hook owners sort by what needs a look — stuck, then
  live instances, then expected spawns an hour — with the top 12 shown and
  the rest behind "Show all". `machine-kill`, `machine-reclaim` and
  `machine-hook` are not exposed. Sidebar "Machine" beside Activity.
- `apps/web/src/routes/utilization.tsx`, `apps/web/src/components/utilization/`
  — the `/utilization` page (#747): the native Utilization pane in the fork.
  Today the forecast section only: every account's projection at its own
  measured pace (windows, pct, pace, when each fills or "Resets before it
  fills", which window binds first) plus the fleet strip Accounts shows,
  read off the `forecast` reply the snapshot already carries — no extra
  verb, no extra poll. `buildForecast` in
  `packages/client-runtime/src/state/infinitusAccounts.ts` decodes the
  lines leniently (the contract leaves them opaque; an odd line or window
  is dropped alone). The history chart and the run-rate table follow the
  `utilization --days` verb native is adding. Sidebar "Utilization" beside
  Machine.
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
  nothing lapsed); row/section/sign-in models come from
  `packages/client-runtime/src/state/infinitusAccounts.ts`, whose
  `infinitusPageState` gates Accounts, Stats, Activity and Machine alike (#693):
  a server whose config arrived with `false` or without the field
  (`infinitusCapabilityOf`) gets the missing-adapter copy; a config that has not
  arrived waits like a missing snapshot, and Accounts folds every environment's
  answer together with `infinitusCapabilityAcross`. Add account and
  re-login (#671): a fleet whose capabilities carry `addOAuth` gets "Add
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
- `apps/web/src/routes/settings.infinitus.{index,notifications,devices,engines,profiles}.tsx`
  — the five Settings › Infinitus routes, thin shells over the panes above.
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
- `apps/mobile` — rule: screen copy, alerts, brand text, a11y labels, the
  Live Activity title, the auth device label and the `infinitus` variant's
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
  reaches no log or span. Two HTTP routes for a CLI with no WebSocket, both
  behind the operate scope: `GET /api/infinitus/holds` (the WS holds stream's
  list — held for headroom, stopped on a limit — plus `kind: "paused"` rows
  from `InfinitusSessionInterrupt.paused`, the turns paused for headroom,
  #743) and `POST /api/infinitus/release-thread` (`{threadId}` →
  `{released, reason?}`, the WS `infinitus.releaseThread` word for word).
  Registration points: `InfinitusLayerLive` provides `AuthLayerLive` to the
  port layer (which is why that block sits below `AuthLayerLive` in
  `server.ts`), `infinitusHttpApiLayer` in `makeRoutesLayer`. Queue-behind-a-
  turn is #806, not this; `thread show`, `send`, `new`, `interrupt` and
  `--wait` use routes that already existed.
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
  `Layers/InfinitusResumeOnLimit.ts` (+ `infinitusResumeOnLimit.logic.ts`) is
  resume-on-limit for the threads this server runs (#648), the fork's
  counterpart to native's terminal nudge: the Claude adapter's parked-turn
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
  usage limit" with no button; the resumed row or a new turn closes it. Once
  per stop, 2-min cooldown per thread,
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
  (`ipc/methods/infinitus.ts`), the events `onCaptureGestureEvent`
  (`preload.ts` guard). Both `osascript` scripts are spike-verified on the
  developer's Mac (the tests mock `spawn`).
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
- `assets/infinitus/` — the desktop and web artwork for fork builds: the
  native Mac app's 1024 icon master (`make-icon.swift` on `native`), the
  phone's full-bleed mark for Linux/apple-touch, and the `.ico`/favicon sizes
  derived from them with ImageMagick. Regenerate by hand when the mark changes.
- `apps/mobile/src/state/infinitus.ts`, `apps/mobile/src/features/accounts/` —
  the Infinitus atoms and the Accounts screen (row model imported from
  `@t3tools/client-runtime/state/infinitusAccounts`), which also carries each
  Mac's Sessions card (`features/infinitus/InfinitusSessions.tsx` +
  `sessions.logic.ts`, rows from
  `@t3tools/client-runtime/state/infinitusSessions`; `session-mode` per row).
  Its row menu's "Move to a thread" (#648, rows with a session id) is the
  web flow on the phone: the cwd becomes a project when it is not one
  (`projectEnvironment.create` + a `waitForProject` in `state/entities.ts`),
  `agentSessions.import` (`apps/mobile/src/state/agentSessions.ts`) runs
  with the row's id, then the Thread screen opens; the row keeps a "close
  the terminal session" line, nothing reaches the Infinitus socket. No bulk
  "Move idle" on the phone.
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
- `apps/mobile/src/state/threadOutboxQueue.logic.ts` (+ `threadOutboxHolds.ts`)
  — the phone outbox's queue rule (#807, #270 F): `queueBehindRunningTurn`
  turns an existing thread's `send` into `wait` while the thread's session is
  `starting` / `running` or the server's hold list names it (any kind: held,
  paused, limited), so a follow-up typed during a turn lands after it instead
  of steering; creations and every other action pass through. `mode` is
  `"queue"` at both call sites — the phone has no copy of the desktop's
  `composerSendMode` yet, `"steer"` is the upstream path kept for it.
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
  headroom" with **Resume now**.
- `apps/mobile/src/features/infinitus/InfinitusPinAtCreationControl.tsx` (+
  `pinAtCreation.ts`, `pinAtCreation.logic.ts`) — "Pin on create" for the
  phone (#742, the web's #753): a "Pin" pill in the new-task composer, shown
  only for a project whose server pins threads, backed by the
  `infinitusPinAtCreation` preference (off by default); the outbox drain reads
  it as each creation is delivered and pins through `usePinThread`, silently
  on failure (the held banner still offers Pin).
- `apps/mobile/src/features/infinitus/`, `apps/mobile/src/widgets/InfinitusWorking.tsx`,
  `apps/mobile/src/widgets/InfinitusRevival.tsx`,
  `apps/mobile/src/features/settings/SettingsInfinitusSection.tsx` — the
  Mac-driven Live Activity: layouts (content = native's activity states),
  token registration, settings. `testCard.logic.ts` (#845) backs the
  section's "Show a test card" row (iOS, under the Live Activity switch):
  one press starts `InfinitusWorking` locally with a fabricated state, no
  APNs in the loop, so a blank card blames the widget and a refusal
  (ActivityKit's message in an alert) blames the phone's settings; with
  working cards live the same row reads "End the working card(s)" and ends
  them all — the Mac cannot end a card it never got an update token for.

- `apps/web/src/components/sidebar/SidebarAccountsPill.tsx` (+
  `sidebarAccountsPill.logic.ts`) — the sidebar footer's Infinitus line.
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
  `fleets`, `sessions`, `forecast`, `prefs`, `profiles`, `stats`, `events`,
  `aws-logins`, `client-activity`, `lock-status` and `team-status` with canned
  data. The manifest and the pref catalog are `infinitusctl` captures (every
  value reset to its default); the accounts (`ada-fixture`…), the session,
  the team ("Lighthouse"), the profiles (`nightly-review`) and the stats are
  made up. Every write and every unknown verb is refused with `ok: false`;
  only verb names are logged. `--socket <short /tmp path>`.
- `scripts/fork-visual-routes.ts` (+ `.test.ts`) — the route table the pass
  asserts: every fork page with the one text marker only its populated render
  shows (a pref row label, the fixture's team or profile name, "Re-lock",
  "Session lengths"…) and the empty-state phrases that must not appear
  (`ALWAYS_ABSENT`: "not answering", "T3 Code" (#823: the upstream name never
  reaches a screen), "Still connecting", "This Infinitus build has no", "could
  not be read"; per route "No projection yet", "Reading the team"…). The test pins the route list, checks no marker is a substring of a
  nav label or card title (those print on a dead page too), and mirrors the
  harness's `text-<route>.txt` naming. `scripts/fork-visual-check.ts` applies
  it: `--routes` prints the routes for the harness's argument list, `--out
  <dir>` reads the captures and exits 1 on the first miss.

- `apps/web/src/components/sidebar/SidebarInfinitusSessions.tsx` (+
  `sidebarInfinitusSessions.logic.ts`) — the footer's collapsible Sessions
  group: the Claude Code sessions the Mac tracks, the ones needing a person
  first. Per row, behind manifest checks: `show session <pid>` on click,
  `nudge <pid>` and the `session-mode` radio in its menu (#612). Its row model
  is `packages/client-runtime/src/state/infinitusSessions.ts` (exported as
  `@t3tools/client-runtime/state/infinitusSessions`; account, age from
  `startedAt`, `needs` chips) so mobile draws the same rows. "Move to a
  thread" in the row menu (rows with a session id) and "Move idle" beside the
  header (#648) turn a tracked terminal session into a T3 thread: the cwd
  becomes a project when it is not one (`projectEnvironment.create` +
  `waitForProject`), `agentSessionsImport` runs with the row's id in
  `providerSessionIds`, the thread opens and the row shows a link plus "close
  the terminal session". Nothing is sent to the Infinitus socket; the
  terminal session is never killed or typed into. The pure parts
  (`canMoveSession`, `idleMoveableRows` — idle only, never busy, waiting,
  shell or unknown — `sessionMoveBatches` per cwd, `movedThreadId`) live in
  the row-model module; mobile's Sessions card uses them (above).

- `packages/contracts/src/agentSessions.ts`,
  `apps/server/src/project/AgentSessionScanner.ts`,
  `apps/server/src/project/AgentSessionImporter.ts` — fork extension of
  upstream's session import (#648): `AgentSessionImportInput.providerSessionIds`
  (optional) filters the scanner to those transcript names before any budget
  is spent (filtered-out files are neither imported nor counted as skipped),
  and `AgentSessionImportResult.threads` (present only with a filter) lists
  `{providerSessionId, threadId}` for each requested session that now has a
  thread, imported now or earlier. Without the field the RPC behaves exactly
  as upstream.

- `.github/workflows/native-nightly-dispatch.yml` — cron dispatcher for the
  `native` branch's nightly jobs (schedules run only from the default
  branch).

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

- `.github/workflows/fork-desktop-release.yml` — "Fork desktop release": the
  manual macOS arm64 DMG build of `main`, published as an `infinitus`-channel
  prerelease (upstream's release.yml stays disabled and untouched). It nests
  the native menu bar app as a login item (#777): `apps/desktop/native-helper.json`
  (`{"tag", "version", "asset", "sha256"}`, `v0.4.5-alpha.1` first, bumped
  by PR; the `native_helper_tag` dispatch input tries a tag before pinning
  it) names the native release whose `Infinitus-Menu-Bar-<version>.zip` (the
  nested build: CFBundleName "Infinitus Menu Bar", no `infinitus://` URL
  type; the standalone `Infinitus-<version>.zip` beside it is the cask's)
  the run downloads, checks (bundle id
  `run.infinitus`; on signed builds Developer ID from team `Q783W6B4FA`,
  hardened runtime, `stapler validate`) and hands to the build script as
  `T3CODE_DESKTOP_NATIVE_HELPER` / `--native-helper`. The script `ditto`s it
  into the stage (`NATIVE_HELPER_STAGE_DIR`), electron-builder's `extraFiles`
  places it at `Contents/Library/LoginItems/Infinitus Menu Bar.app` (the one
  path `SMAppService.loginItem` accepts) before the outer bundle is signed,
  and `signIgnore` keeps `scripts/sign-macos.ts` off it, so the helper keeps
  the native release's signature, entitlements and stapled ticket while the
  outer seal records it as nested code; the one built-in notarization covers
  both. "Verify nested helper" proves the nested seal survived packaging and
  that Electron's `allow-jit` entitlement never reached it. No pin and no
  input: nothing is nested, as for local and upstream builds. The helper is
  never rebuilt in this workflow (macOS 26 SDK, Swift toolchain and a second
  sign/notarize path for an artifact the native branch already publishes).

- `packages/contracts/src/providerProxy.ts`, `apps/server/src/provider/proxyModels.ts`,
  `apps/web/src/components/settings/proxyProvider.ts`,
  `apps/web/src/components/settings/ProxyProviderFields.tsx` — "Route through a
  proxy" for a Claude instance: 9Router / CLIProxyAPI / custom presets, model
  slots picked from the proxy's `GET <baseUrl>/models`, everything stored on
  the ordinary instance (env vars + CLAUDE_CONFIG_DIR), no settings file written.
