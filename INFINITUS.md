# Infinitus fork — rules on top of AGENTS.md

This `main` is a fork of [T3 Code](https://github.com/pingdotgg/t3code) that
drives the Infinitus engine. AGENTS.md (upstream's guide) applies in full;
this file adds the fork's own rules. Plan and history: issue #555.

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
  `nightly` from `main`.
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
  `WsRpcGroup`.
- `packages/contracts/src/environment.ts` — the `infinitus` capability on
  `ExecutionEnvironmentCapabilities`.
- `packages/client-runtime/src/rpc/client.ts` — `subscribeInfinitus` in
  `EnvironmentSubscriptionRpcTag`, so the client's `subscribe` accepts it.
- `apps/server/src/ws.ts` — pulls `InfinitusService` beside the other services
  and answers the two Infinitus methods.
- `apps/server/src/auth/RpcAuthorization.ts` — a scope for each of them; the
  table is `satisfies Record<WsRpcMethod, …>`, so a new RPC without one is a
  type error.
- `apps/server/src/server.ts` — `InfinitusLayerLive` in
  `RuntimeDependenciesLive`.
- `apps/server/src/server.test.ts` — a `Layer.mock(InfinitusService)` in the
  harness's stub stack, since the routes layer now needs the service.
- `apps/server/src/environment/ServerEnvironment.ts` — fills the `infinitus`
  capability from `resolveInfinitusControlSocketPath`.
- `apps/mobile/app.config.ts` — the `infinitus` app variant (bundle id
  `run.infinitus.mobile`, the Infinitus Apple team, the native phone's icon;
  `appleTeamId` per variant), selected with `APP_VARIANT=infinitus`.
- `apps/mobile/src/Stack.tsx` — the `SettingsAccounts` route (Settings ›
  Accounts, the Infinitus fleet per paired Mac).
- `apps/mobile/src/features/settings/components/settings-sheet-targets.ts` —
  `SettingsAccounts` in the settings target union.
- `apps/mobile/src/features/settings/SettingsRouteScreen.tsx` — the
  `SettingsInfinitusSection` (Accounts row, Live Activity toggle, pusher Mac)
  after General.
- `apps/mobile/src/App.tsx` — mounts `InfinitusLiveActivityBridge` (Live
  Activity token registration with the Mac).
- `apps/mobile/src/persistence/mobile-preferences.ts` — the
  `infinitusLiveActivityEnabled` / `infinitusLiveActivityMac` keys (interface
  and sanitizer).
- `apps/mobile/src/features/home/HomeHeader.tsx` — the `InfinitusHomeChip`
  (active account + fullest window of the Mac the list follows) before the
  filter button.
- `apps/web/src/components/settings/settingsSearch.ts` — the five Infinitus
  `SettingsPath`s and their labels, the `infinitusOnly` search flag with the
  `hasInfinitusEnvironment` availability it reads, and
  `isSettingsSectionActive` so a nested page's nav item is the only one lit.
- `apps/web/src/components/settings/SettingsSidebarNav.tsx` — an icon per
  Infinitus path and the capability filter that hides all five where no
  connected server reaches an Infinitus app.
- `apps/web/src/components/settings/useAvailableSettingsSearchItems.ts` —
  fills `hasInfinitusEnvironment` from the environments' capabilities.
- `apps/web/src/components/settings/settingsSearch.test.ts` — the availability
  records it builds gained that field.
- `apps/web/src/routes/settings.infinitus*.tsx` (five new files in upstream's
  routes directory) and `apps/web/src/routeTree.gen.ts` — regenerated with
  `@tanstack/router-generator`, never edited by hand.
- `README.md` — the fork notice at the top.
- `.github/workflows/ci.yml` — `runs-on` swapped from Blacksmith runners to
  GitHub-hosted ones, timeouts widened, `workflow_dispatch:` added so the
  upstream-sync workflow can start CI on its branch. The sync workflow
  re-applies the runner swap after every merge.
- Upstream workflows that deploy or publish (Release, Deploy T3 Connect
  relay, Forward to Cursor hygiene, Mobile EAS Preview/Production, Publish
  AUR, Issue Labels, Desktop macOS Preview, Web Preview, Mobile Showcase
  Screenshots, Thread Transfer Report) are disabled in the repository's
  Actions settings, not deleted, so merges stay clean.

## Fork-only files

- `apps/web/src/components/settings/infinitus/` — the Infinitus settings panes
  (preferences, Engines, Profiles) and their pure logic.
- `apps/web/src/state/infinitus.ts` — the web app's instance of the Infinitus
  snapshot and command atoms.

- `apps/mobile/assets/infinitus-ios-1024.png` — the Infinitus phone icon
  (copied from the native phone's asset catalog).
- `apps/mobile/src/state/infinitus.ts`, `apps/mobile/src/features/accounts/` —
  the Infinitus atoms and the Accounts screen (row model imported from
  `@t3tools/client-runtime/state/infinitusAccounts`).
- `apps/mobile/src/features/infinitus/`, `apps/mobile/src/widgets/InfinitusWorking.tsx`,
  `apps/mobile/src/widgets/InfinitusRevival.tsx`,
  `apps/mobile/src/features/settings/SettingsInfinitusSection.tsx` — the
  Mac-driven Live Activity: layouts (content = native's activity states),
  token registration, settings.

- `.github/workflows/native-nightly-dispatch.yml` — cron dispatcher for the
  `native` branch's nightly jobs (schedules run only from the default
  branch).
