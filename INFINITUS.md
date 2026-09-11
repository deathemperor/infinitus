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
  Anthropic-compatible proxy's models) the same way.
- `packages/contracts/src/environment.ts` — the `infinitus` capability on
  `ExecutionEnvironmentCapabilities`; `alternateHttpBaseUrls` (optional) on
  `ExecutionEnvironmentDescriptor` (#663).
- `packages/client-runtime/src/rpc/client.ts` — `subscribeInfinitus` in
  `EnvironmentSubscriptionRpcTag`, so the client's `subscribe` accepts it.
- `apps/server/src/ws.ts` — pulls `InfinitusService` beside the other services
  and answers the two Infinitus methods; answers `provider.proxyModels` with
  `fetchProxyModels` over the server's `HttpClient`.
- `packages/client-runtime/src/state/server.ts` — `serverEnvironment.proxyModels`
  command (single-flight per base URL).
- `apps/web/src/components/settings/AddProviderInstanceDialog.tsx` — the Claude
  Config step renders `ProxyProviderFields` ("Route through a proxy"); on save
  `applyProxyDraft` adds the ANTHROPIC_* environment variables (the key marked
  sensitive), a dedicated `homePath` (`~/.claude-proxy/<instanceId>` unless one
  was typed) and the picker model as a custom model.
- `apps/server/src/auth/RpcAuthorization.ts` — a scope for each of them; the
  table is `satisfies Record<WsRpcMethod, …>`, so a new RPC without one is a
  type error.
- `apps/server/src/server.ts` — `InfinitusLayerLive` in
  `RuntimeDependenciesLive`. `InfinitusResumeOnLimitLive` in `ReactorLayerLive`
  (#648).
- `packages/contracts/src/settings.ts` — `infinitusResumeOnLimit` on
  `ServerSettings` (default on) and `ServerSettingsPatch` (#648).
- `packages/contracts/src/ipc.ts` — the fork's optional `DesktopBridge`
  methods: `getInfinitusDesktopPrefs` / `setInfinitusQuitWithApp` (#654) and
  `openInfinitusSignIn` / `closeInfinitusSignIn` /
  `submitInfinitusSignInCode` (#677).
- `apps/desktop/src/ipc/channels.ts`, `apps/desktop/src/ipc/DesktopIpcHandlers.ts`,
  `apps/desktop/src/preload.ts` — the channels, `ipc.handle` lines and
  preload entries for those methods; `apps/desktop/src/main.ts` —
  `InfinitusDesktop.layer` in `desktopApplicationLayer`.
- `apps/server/src/server.test.ts` — a `Layer.mock(InfinitusService)` in the
  harness's stub stack, since the routes layer now needs the service.
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
- `apps/server/src/environment/ServerEnvironment.ts` — fills the `infinitus`
  capability from `resolveInfinitusControlSocketPath`.
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
  `infinitus` artwork for fork versions.
- `scripts/lib/brand-assets.ts` — the `infinitus*` entries in
  `BRAND_ASSET_PATHS`, the `infinitus` `WebAssetBrand` (favicons, apple-touch),
  and `resolveWebAssetBrandForPackageVersion` mapping `-infinitus.` versions to it.
- `apps/desktop/scripts/electron-launcher.mjs` — `APP_PROTOCOL_SCHEMES`
  mirrors the shared constants (a node script cannot import the workspace's
  TypeScript); the dev-only bundle id stays `com.t3tools.*`.
- `apps/web/src/components/settings/SettingsPanels.tsx` (+ `.logic.ts`) —
  `resolveDesktopUpdateTrackRow`: an `infinitus` build shows its own track
  read-only instead of "Stable" with a one-way switch to upstream's releases.
- Upstream tests carrying the renderer origin or the userData directory
  (`DesktopAppIdentity`, `DesktopClerk`, `ElectronProtocol`, `DesktopWindow`,
  `DesktopLinuxUrlHandler`, `DesktopPreReadyPlatform`, `server.test.ts`,
  `build-desktop-artifact.test.ts`, and the web fixtures that stub a desktop
  origin) use the fork's scheme.
- `knip.jsonc` — `scripts/fork-visual-pass.mjs` as a scripts entry (run by
  hand, nothing imports it).
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
  Activity token registration with the Mac) and `InfinitusAlarmsBridge`
  (local reset / swap alarms).
- `apps/mobile/src/persistence/mobile-preferences.ts` — the
  `infinitusLiveActivityEnabled` / `infinitusLiveActivityMac` /
  `infinitusAlarmsEnabled` keys (interface and sanitizer).
- `apps/mobile/src/features/home/HomeScreen.tsx` — the thread list's header:
  the `InfinitusHomeChip` on iOS (whose native header has no slot for it) and
  `InfinitusSignIns` (lapsed AWS / gcloud sign-ins of paired Macs).
- `apps/mobile/src/features/home/HomeHeader.tsx` — the `InfinitusHomeChip`
  (active account + fullest window of the Mac the list follows, plus its
  waiting-session count) before the filter button, in the Android header.
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
  access is on, else the page's own non-loopback origin; #651). Both up →
  an Internet / Same network choice; neither → it points at Settings ›
  Connections › Network access. "Type it instead" reveals host + code for
  the phone's manual form. It is mounted through the prefs panel's `footer`
  slot from `routes/settings.infinitus.devices.tsx`; no route of its own.
- `apps/web/src/state/infinitus.ts` — the web app's instance of the Infinitus
  snapshot and command atoms.
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
  (an upstream file: that one line is the fork's only edit there).
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
  crosses an RPC, the server or the tunnel. Offered only in the Electron
  client for the primary environment; a phone or tunnel client on such a
  build reads "Sign in from the Mac." Closing the OAuth window never
  cancels; the page's Cancel sends `signin-cancel`.
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
  compact title still draws upstream's T3 wordmark glyph (an asset, not a
  string).
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
  prompt from its resume cursor. Once per stop, 2-min cooldown per thread,
  a user turn cancels; off by the `infinitusResumeOnLimit` server setting
  (`apps/web/src/components/settings/infinitus/InfinitusResumeCard.tsx` on
  Settings › Infinitus).
  `Layers/InfinitusCompanion.ts` is the one-app companion (#654 step 1): on a
  Mac whose socket is still quiet 3 s after the server starts it runs `open
-g -b run.infinitus` once (LaunchServices, no path, no retry, one log line;
  withheld from dev/worktree servers exactly like the port publish), and the
  same body answers `infinitus.launch` (operate scope) for the web's "Launch
  Infinitus" button — `{launched}` or `{launched: false, reason}`, never an
  error; the app coming up is the snapshot flipping.
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
- `apps/mobile/src/features/infinitus/`, `apps/mobile/src/widgets/InfinitusWorking.tsx`,
  `apps/mobile/src/widgets/InfinitusRevival.tsx`,
  `apps/mobile/src/features/settings/SettingsInfinitusSection.tsx` — the
  Mac-driven Live Activity: layouts (content = native's activity states),
  token registration, settings.

- `apps/web/src/components/sidebar/SidebarAccountsPill.tsx` (+
  `sidebarAccountsPill.logic.ts`) — the sidebar footer's Infinitus line.

- `scripts/fork-visual-pass.mjs` — the visual pass: one headless Chrome over
  CDP pairs with a running web app, clicks through the first-run wizard, then
  screenshots each route (`shot-<route>.png` + `text-<route>.txt`). Mint a
  token with `node apps/server/src/bin.ts pair` (from the server's worktree),
  then
  `node scripts/fork-visual-pass.mjs --pair-url <url> --out <dir> /accounts /settings/infinitus`
  (`--base-url`, `--cdp-port`, `--profile`, `--settle-ms`, `CHROME_BIN`; the
  token is never printed). No dependencies; node ≥ 22.

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

- `.github/workflows/fork-desktop-release.yml` — "Fork desktop release": the
  manual macOS arm64 DMG build of `main`, published as an `infinitus`-channel
  prerelease (upstream's release.yml stays disabled and untouched).

- `packages/contracts/src/providerProxy.ts`, `apps/server/src/provider/proxyModels.ts`,
  `apps/web/src/components/settings/proxyProvider.ts`,
  `apps/web/src/components/settings/ProxyProviderFields.tsx` — "Route through a
  proxy" for a Claude instance: 9Router / CLIProxyAPI / custom presets, model
  slots picked from the proxy's `GET <baseUrl>/models`, everything stored on
  the ordinary instance (env vars + CLAUDE_CONFIG_DIR), no settings file written.
