# Multi-engine + CLIProxyAPI — implementation plan (#8)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Infinitus renders every enabled account engine as its own popup fleet, with CLIProxyAPI as the first non-cswap engine at full parity.

**Architecture:** `AccountEngine` protocol + `EngineFleet` snapshot in InfinitusCore; `FleetState` (one per fleet, conforms to `FleetModel` + `UsageSource`) and `EngineRegistry` in the mac app; `AppModel` stays a `FleetModel` facade over the primary Claude fleet. `CLIProxyEngine` talks HTTP to the proxy's Management API with a keychain-held key.

**Tech stack:** Swift 5.9 package, SwiftUI/AppKit, XCTest, URLSession, Security.framework (keychain), Homebrew `cliproxyapi`.

**Spec:** `docs/research/multi-engine.md` (+ `cliproxyapi-backend.md` for the API mapping).

## Global constraints
- Engine isolation: never read `~/.cli-proxy-api/*` contents or `~/.claude-swap-backup/*`; proxy = HTTP only, cswap = subprocess only.
- Secrets never in argv, defaults, or logs; the management key lives in the keychain (`com.huuloc.infinitus.cliproxy`).
- Bundle id `com.huuloc.limitless` untouched. Push nothing to any remote.
- Surgical diffs, existing style, `swift test` green at every commit, popup pixel-identical on a cswap-only Mac after phase 1 (compare against `scratchpad/Infinitus-baseline.app`).
- Another Claude session is active in this checkout (builds via make-app.sh, commits AppModel). `git status` before every commit; stage only own files.

---

## Phase 1 — seam extraction (cswap only, behaviour-identical)

### Task 1: Models become Codable with public inits
Files: `Sources/InfinitusCore/Models.swift`, `Tests/InfinitusCoreTests/ModelsTests.swift`
- `AccountList`, `NextRecovery`, `LiveSessions`, `SessionDetail`, `Account`, `Usage`, `UsageWindow`, `Spend` → `Codable` + `public init(...)` with defaults for optionals.
- Test: decode `list.json` → encode → decode again; first account equal field-by-field; `Account(number:email:...)` init compiles with only required args.

### Task 2: AccountEngine protocol, capabilities, EngineFleet, CswapEngine
Files: create `Sources/InfinitusCore/AccountEngine.swift`, `Sources/InfinitusCore/Engines/CswapEngine.swift`; test `Tests/InfinitusCoreTests/AccountEngineTests.swift`
- `Provider`, `EngineCapabilities` (`.all`), `EngineFleet: Codable`, `EngineError`, `AccountEngine` protocol with throwing defaults, `EngineDescriptor` (id, displayName).
- `CswapEngine(cli:)` (`#if !os(iOS)`): `snapshot()` → `[EngineFleet]` from `accountListRaw()`; every action forwards to `CswapCLI`.
- Tests: default impls throw `.unsupported`; a stub engine's fleet round-trips through JSON; `CswapEngine.capabilities == .all`.

### Task 3: FleetState + EngineRegistry in the app
Files: create `Sources/Infinitus/FleetState.swift`, `Sources/Infinitus/EngineRegistry.swift`
- `FleetState: ObservableObject, FleetModel, UsageSource, Identifiable` — owns accounts/active/next/recovery/liveSessions/ticks/dying/pendingSwitch/switchFlashTick/snapshotLoaded/report; `apply(_ fleet: EngineFleet) -> FleetChange` (newlyDead, newlyAlive, previousActive, firstLoad, changed) with the exact diff + `withAnimation` from today's `refreshSnapshot`; prefs forwarded from `unowned let host: AppModel`; actions call `engine` then `host.refreshSnapshot()`.
- `EngineRegistry`: `entries: [(descriptor, engine, fleets)]`, `fleets: [FleetState]` ordered Claude-first; `fleet(for:engineID:provider:) -> FleetState` (creates on first sight).

### Task 4: AppModel rewired as facade
Files: `Sources/Infinitus/AppModel.swift` (init 260-347, startFeeds 407-435, refreshSnapshot 649-843, actions 888-993, FleetModel ext 994-1014), `Sources/Infinitus/UsagePane.swift` (UsageModel stays the cswap fleet's report source)
- `registry` + `primary: FleetState?` (first `.claude`); facade computed props with setters; objectWillChange forwarding with guard.
- `refreshSnapshot`: TaskGroup over engines → `apply` per fleet → app-level hooks (cache `[EngineFleet]`, history, mirror(raw or encoded), waitingResume, notifier, keepAwake, resume, pushes, sync) on `primary`.
- Cache: `snapshotCacheURL` now `[EngineFleet]`; seed registry at init.
- Gate: `swift test` green; `./make-app.sh`; popup + wall + accounts pane identical vs baseline app (mock mode, same theme); commit.

### Task 5: FleetStack in InfinitusUI
Files: create `Sources/InfinitusUI/FleetStack.swift`; modify `Sources/InfinitusUI/FleetModel.swift` (+`fleetLabel: FleetLabel?` default nil, +`capabilities: EngineCapabilities` default `.all`), `Sources/Infinitus/InfinitusApp.swift:584-600`
- `FleetStack<F: FleetModel & UsageSource & Identifiable>(fleets: [F])`: ForEach → optional `FleetHeader` (only when `fleets.count > 1`) + `AccountRows(model: f, usage: f)`.
- Rows gate `pendingSwitch` on `.switch`, relogin on `.addOAuth || .addToken`.
- Gate: single fleet renders identically (capture compare).

## Phase 2 — CLIProxyEngine

### Task 6: ProxyMapping (pure) + fixtures
Files: create `Sources/InfinitusCore/Engines/ProxyMapping.swift`, fixtures `Tests/InfinitusCoreTests/Fixtures/cliproxy/{auth-files,oauth-usage,oauth-profile,usage-queue}.json` (hand-written from upstream shapes now, replaced by redacted live captures in Task 11), test `ProxyMappingTests.swift`
- `ProxyAuthFile: Decodable` (id, authIndex, name, provider, label, status, statusMessage, disabled, unavailable, email, accountType, priority, note, nextRetryAfter, quota.signals).
- `OAuthUsage.parse(Data) -> Usage?` — cswap's `build_usage_result` in Swift (five_hour/seven_day/extra_usage/limits).
- `ProxyMapping.fleets(files:, usage: [String: Usage?], profiles: [String: Profile], strategy:) -> [EngineFleet]` + `ordinals: [Provider: [String]]`; active = highest priority; status derivation.

### Task 7: CLIProxyEngine HTTP client
Files: create `Sources/InfinitusCore/Engines/CLIProxyEngine.swift`, test `CLIProxyEngineTests.swift` (URLProtocol stub)
- `init(baseURL:, managementKey:, session:)`; `snapshot()` (auth-files → fan-out ≤4 → mapping); `setHold`, `switchTo` (priority), `rename` (note), `remove`, `beginOAuthAdd`/`awaitOAuthAdd`, `routingStrategy()`, `drainUsageQueue()`.
- Errors: 401 → `.unauthorized`; 404 on `/auth-files` → `.unauthorized` (no key configured); connection error → `.unreachable`.

### Task 8: Usage ledger + static price table
Files: create `Sources/InfinitusCore/Engines/ProxyUsageLedger.swift`, test `ProxyUsageLedgerTests.swift`
- Append records to JSONL; `report(days:, ordinals:) -> UsageReport` priced by `StaticPriceTable`.

### Task 9: Keychain + Engines pane + registry wiring
Files: create `Sources/Infinitus/Keychain.swift`, modify `Sources/Infinitus/EnginesPane.swift`, `Sources/Infinitus/AppModel.swift` (registry build), `Sources/Infinitus/InfinitusApp.swift` (onboarding "Connect CLIProxyAPI…"), `Sources/Infinitus/AccountsPane.swift` (proxy add/remove via capabilities)
- Defaults keys: `engine_cswap_enabled`, `engine_cliproxy_enabled`, `cliproxy_base_url`.
- Pane: enable toggles, URL, key set/clear, Test connection, strategy line, layer-fight warning.

## Phase 3 — dev proxy + live smoke

### Task 10: Install + configure the proxy
- `brew install cliproxyapi`; write `~/.cli-proxy-api/config.yaml` (port 8317, auth-dir, secret key, fill-first); `brew services start cliproxyapi`; verify `GET /v0/management/auth-files` with the key.

### Task 11: Live smoke + fixtures + docs
- Add account via the app's OAuth flow (user signs in once); capture live responses → redact → replace fixtures; verify hold/switch/rename/remove/cost; record drift vs `81e1b53` in the spec; update `docs/TODO.md`, `CLAUDE.md` hard-won facts if any.
