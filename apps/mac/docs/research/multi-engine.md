# Multi-engine Infinitus — AccountEngine seam + CLIProxyAPI backend (#8, designed 2026-09-02)

Mission (user 2026-09-02): "support any kind of multi accounts engine".
Issue #8 is the first non-cswap engine; the seam it lands on is the
deliverable. Approved path: full parity for the proxy (incl. add-account
and cost), all engines shown at once (one popup section each), engine
protocol + neutral models (approach A), a persistent dev proxy on this
machine.

Upstream facts below were read from router-for-me/CLIProxyAPI @ `81e1b53`
(`internal/api/server_management.go`, `handlers/management/*.go`,
`sdk/cliproxy/auth/selector.go`) and from cswap's own
`src/claude_swap/oauth.py`. Homebrew ships `cliproxyapi` 7.2.145; shapes
are re-verified against the installed release during phase 3 and any
drift is recorded here.

## 1. Engine protocol (InfinitusCore, portable, no AppKit)

```swift
public enum Provider: String, Codable, Sendable { case claude, codex, gemini, other }

public struct EngineCapabilities: OptionSet, Sendable {
    switch, rotate, reorder, hold, rename, remove,
    addCurrent, addToken, addOAuth, autoSwitch,
    costReport, history, settings, notify
}

public struct EngineFleet: Codable, Sendable {
    public let engineID: String          // "cswap", "cliproxy", "codex"
    public let provider: Provider
    public let accounts: [Account]
    public let activeNumber: Int?
    public let nextCandidate: Int?
    public let nextRecovery: NextRecovery?
    public let liveSessions: LiveSessions?
    /// Verbatim engine bytes when the engine has a native JSON form
    /// (cswap: `list --json`); the mirror exporter forwards them so
    /// the phone keeps decoding `AccountList` untouched.
    public let raw: Data?
}

public protocol AccountEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: EngineCapabilities { get }
    /// One fleet per provider the engine holds (the proxy pools several).
    func snapshot() async throws -> [EngineFleet]
    func switchTo(fleet: Provider, number: Int) async throws
    func rotate(fleet: Provider) async throws
    func reorder(fleet: Provider, _ numbers: [Int]) async throws
    func setHold(fleet: Provider, number: Int, held: Bool) async throws
    func rename(fleet: Provider, number: Int, _ name: String) async throws
    func remove(fleet: Provider, number: Int) async throws
    func addCurrent() async throws
    func addToken(_ token: String) async throws
    /// OAuth add: returns the URL to open; `awaitAdd` polls to completion.
    func beginOAuthAdd(fleet: Provider) async throws -> URL
    func awaitOAuthAdd() async throws
    func usageReport(days: Int) async throws -> UsageReport
}
```

- Every action has a default implementation that throws
  `EngineError.unsupported(capability)`. The UI gates on
  `capabilities`, never on engine identity.
- `Account`, `Usage`, `UsageWindow`, `Spend`, `NextRecovery`,
  `LiveSessions`, `AccountList` gain public memberwise inits and
  `Encodable`. `number` stays the per-fleet ordinal (1-based) the UI
  keys ticks, `pendingSwitch` and drag-reorder on; an adapter that has
  its own identities (the proxy's auth-file names) keeps an
  ordinal→identity map from its last snapshot — no `id` on `Account`
  (amended 2026-09-02 during planning: YAGNI, the map is adapter-local).
- `CswapEngine` wraps `CswapCLI` and declares every capability. It
  yields exactly one fleet (`.claude`) whose `raw` is the `list --json`
  bytes. `CswapCLI` stays public for the cswap-only panes (settings
  spec, notify, upgrade, switch history).
- `EngineError`: `unsupported`, `unreachable(String)`,
  `unauthorized` (proxy 401/404-without-key), `remote(status, body)`.

## 2. Registry + AppModel (Infinitus)

- `FleetState` (new, `@MainActor final class`, conforms to `FleetModel`):
  one per (engine, provider) fleet. Owns `accounts`, `activeNumber`,
  `nextCandidate`, `nextRecovery`, `liveSessions`, `reviveTicks`,
  `deathTicks`, `dying`, `pendingSwitch`, `switchFlashTick`,
  `snapshotLoaded`, and `apply(_ fleet: EngineFleet)` — the alive→dead /
  dead→alive diff and the `withAnimation` swap that live in
  `refreshSnapshot` today, moved verbatim. Shared prefs (`rowTheme`,
  `compactRows`, `burnStyle`, `popupLayout`, `fillScale`, intro fields,
  `isPlayground`, `sortByHeadroom`) are forwarded from a weak `host:
  AppModel` reference. Actions (`switchTo`, `setHold`, `rename`,
  `reorder`, `startRelogin`) call back into `AppModel.perform(engineID:,
  provider:, action)`.
- `EngineRegistry` (Infinitus): ordered `[(engine: any AccountEngine,
  fleets: [FleetState])]`. Enabled set persisted in UserDefaults
  `engines_enabled` (default: cswap when its binary is found; cliproxy
  when the pane has a key; codex never — it stays on its own pane until
  the follow-up). Order: Claude fleets first, cswap before proxy.
- `AppModel` keeps: prefs, supervisor (cswap only), resume service,
  onboarding detection, push triggers, usage history recorder, the
  refresh timer. `refreshSnapshot` becomes: for each enabled engine
  `snapshot()` concurrently (TaskGroup, failures per engine into
  `engineErrors[engineID]`), then `fleetState.apply` per fleet.
  `AppModel` KEEPS conforming to `FleetModel` as a facade over the
  primary Claude fleet (`accounts`, `activeNumber`, ticks, `pendingSwitch`
  … are computed pass-throughs to `primary`, with objectWillChange
  forwarded both ways behind a re-entrancy guard) — so `AccountsPane`,
  `WallLayout`, `MirrorExporter`, `PushTriggers`, `UsageHistoryRecorder`
  and the popup chrome keep compiling unchanged and stay
  behaviour-identical on a cswap-only machine (amended 2026-09-02 during
  planning: the facade removes ~40 consumer edits from phase 1). Each
  `FleetState` also conforms to `UsageSource` so the cash column is
  per-fleet (numbers collide across fleets).
- Launch cache: `snapshotCacheURL` stores `[EngineFleet]` JSON (keyed by
  engineID+provider). Decoding failure = cold start, as today.
- Mirror exporter: sends `primaryClaude.raw` when present (cswap), else
  encodes the fleet as `AccountList` JSON (the models are Encodable now)
  so a proxy-only Mac still mirrors. The phone is untouched.
- Push triggers, all-dead hero, sessions card, resume nudge: operate on
  `primaryClaude` in v1 (they reason about the credential Claude Code
  is using, which only cswap controls). Documented, not generalised.

## 3. CLIProxyEngine (InfinitusCore, URLSession; iOS-capable by construction)

Config: `baseURL` (default `http://127.0.0.1:8317`), `managementKey:
String` injected at init. The app stores the key in the macOS keychain
(`SecItem` generic password, service `com.huuloc.infinitus.cliproxy`,
account = base URL) and never writes it to defaults or logs. Requests
carry `Authorization: Bearer <key>` and a 5s timeout. `config.yaml` and
the auth files are never read (Onboarding.swift contract holds).

Endpoints (all under `/v0/management`):

| Purpose | Call | Notes |
|---|---|---|
| Roster | `GET /auth-files` → `{"files":[entry]}` | entry: `id`, `auth_index`, `name`, `provider`, `label`, `status`, `status_message`, `disabled`, `unavailable`, `email`, `account_type`, `account`, `priority`, `note`, `weight`, `success`, `failed`, `next_retry_after`, `quota{observed_at,signals}`, `model_quotas`. Grouped by `provider`; `claude` → `.claude`, `codex` → `.codex`, `gemini*` → `.gemini`, else `.other`. |
| Gauges (claude only) | `POST /api-call` `{auth_index, method:"GET", url:"https://api.anthropic.com/api/oauth/usage", header:{Authorization:"Bearer $TOKEN$", "anthropic-beta":"oauth-2025-04-20", "User-Agent":"infinitus/1.0"}}` → `{status_code, header, body}` | `body` is the raw usage JSON: `five_hour{utilization,resets_at}`, `seven_day{…}`, `extra_usage{is_enabled,used_credits,monthly_limit,utilization,currency,resets_at}`, `limits[{scope.model.display_name, percent, resets_at}]` — mapped exactly as cswap's `build_usage_result`. Fan-out capped at 4 concurrent; a non-200 leaves `usage` nil and `usageStatus = "error"`; a 429 backs that credential off for `Retry-After` or 5 min. |
| Org / plan | `POST /api-call` → `https://api.anthropic.com/api/oauth/profile` | Cached per credential for 24h (identity does not churn). `organizationName`, `organizationUuid`, `plan` (rate-limit tier display name, as cswap). |
| Hold | `PATCH /auth-files/status` `{name, disabled}` → `{status:"ok", disabled}` | `Account.disabled`. |
| Switch | `PATCH /auth-files/fields` `{name, priority: max(priority)+1}` | Higher integer wins (`selector.go highestPriorityAuths`). `activeNumber` = enabled, non-unavailable credential with the highest priority; ties → first by `auth_index`. |
| Routing caveat | `GET /routing/strategy` → `{strategy}` | Polled with the roster; when `strategy` is `round-robin`/`weighted-round-robin` the fleet header and pane say "priority tiers are ignored by <strategy>". |
| Rename | `PATCH /auth-files/fields` `{name, note}` | `Account.alias` ← `note`; empty string clears. |
| Remove | `DELETE /auth-files?name=` | |
| Add (OAuth) | `GET /anthropic-auth-url` → `{status, url, state}`; poll `GET /get-auth-status?state=` every 2s → `{status: "ok"\|"wait"\|"error", error?}` for up to 5 min | The proxy runs its own callback server; the app only opens `url`. Codex fleets use `/codex-auth-url`. |
| Cost | `GET /usage-queue?count=500` → `[record]` (destructive pop, 60s retention) | record: `timestamp`, `auth_index`, `provider`, `model`, `token_breakdown{total_tokens, input{total_tokens,uncached_tokens,cache_read_tokens,cache_write_tokens}, output{total_tokens,…}}`. Drained every poll into `App Support/Infinitus/engines/cliproxy/usage.jsonl` (one line per record, newest appended). `usageReport(days:)` aggregates the ledger per `auth_index` → `UsageBucket` and prices with `PriceTable` in InfinitusCore (static list-price table, `source: "infinitus-static"`); caveats: estimate, 60s drain window, drain conflicts with CPAMC if both poll. |

Derived fields:
- `usageStatus`: `"ok"` when usage parsed; `"limited"` when any window
  ≥ 100 or `next_retry_after` is in the future; `"error"` on fetch
  failure; `"disabled"` when held; `"unavailable"` when the proxy says so.
- `nextCandidate` / `nextRecovery`: computed with `AutoOrder.order` and
  `RecoveryMath.corrected` on the mapped accounts — identical math to the
  cswap fleet's client-side correction.
- `liveSessions`: nil (proxy clients are arbitrary).
- `plan`: from profile; `icon`: nil.
- Non-Claude fleets: accounts carry identity + `disabled` + `usageStatus`
  only; gauges nil (the rows already render usage-less accounts).

Poll cadence: the app's `refreshInterval`, same as cswap. No push
channel exists upstream; PR candidate 3 in cliproxyapi-backend.md stays
the upgrade path.

## 4. Popup (InfinitusUI)

- `AccountGrid<M: FleetModel, U: UsageSource>` unchanged.
- New `FleetStack`: `ForEach(fleets)`; when `fleets.count > 1` each grid
  is preceded by a `FleetHeader` (provider glyph, engine display name,
  optional routing caveat) at caption size, themed like the popup header.
  With exactly one fleet nothing is inserted, so today's popup is
  pixel-identical.
- Footer engine badge: cswap's supervisor state when cswap is enabled;
  otherwise the proxy's `reachable` / `unauthorized` / `unreachable`
  (mapped onto `EngineBadge.running` / `.refused` / `.stopped`).
- The all-dead hero fires when every Claude fleet is dead.
- The status-item title reads `primaryClaude` (unchanged).

## 5. Engines pane

- One row per known engine with an enable toggle and its live state.
- CLIProxyAPI section: base URL field, masked key field (keychain-backed,
  "Set…" / "Clear"), "Test connection" (GET `/auth-files`; reports
  reachable / 401 / 404-no-key / N credentials), routing strategy line,
  the existing detection line.
- Layer-fight warning (orange caption) when cswap and the proxy are both
  enabled: "cswap swaps the credential under Claude Code; the proxy
  rotates behind its own endpoint — run one for the same accounts."
  Not blocked.
- The onboarding engine-missing card gains "Connect CLIProxyAPI…" when
  the proxy is detected and cswap is not installed.

## 6. Dev proxy on this machine (persistent)

- `brew install cliproxyapi`; `~/.cli-proxy-api/config.yaml` written by
  hand with `port: 8317`, `auth-dir: ~/.cli-proxy-api`,
  `remote-management.secret-key: <generated, 32 hex>`, `allow-remote:
  false`, `routing.strategy: fill-first`. `brew services start
  cliproxyapi`. The key is also entered into the app's keychain slot via
  the pane.
- The 2026-06 credential file (`claude-loc.truongh@gmail.com.json`) is
  expected to be expired; the proxy reports it as such and the popup
  must render that honestly. A fresh account is added through the app's
  OAuth flow — the user completes the browser sign-in once.

## 7. Testing

InfinitusCoreTests (`swift test`):
- `EngineCapabilitiesTests`: defaults throw `unsupported`; cswap declares
  all; proxy declares `[hold, switch, rename, remove, addOAuth,
  costReport]`.
- `ProxyMappingTests` on fixtures `Fixtures/cliproxy/auth-files.json`,
  `oauth-usage.json`, `oauth-profile.json`, `usage-queue.json` (lifted
  from the live dev proxy in phase 3, tokens/emails redacted): grouping by
  provider, ordinal assignment, active-by-priority incl. ties, hold →
  disabled, note → alias, usage mapping (5h/7d/scoped/spend, missing
  `limits`, `extra_usage` nulls), status derivation, `next_retry_after`.
- `CLIProxyEngineTests` over a `URLProtocol` stub: bearer header present,
  key never in URL, 404-without-key → `unauthorized`, `$TOKEN$` header
  literal sent verbatim, fan-out concurrency ≤ 4, 429 backoff, OAuth
  polling state machine (wait→ok, wait→error, timeout).
- `UsageLedgerTests`: append/aggregate per `auth_index` and day; pricing
  with the static table.
- `FleetStateTests` (macOS target, XCTest with `@MainActor`): the
  alive→dead / dead→alive diff produces the same ticks as the pre-refactor
  `refreshSnapshot` on `Fixtures/list.json` mutations.
- Models: `Account` encode→decode round-trip; `id` default.

Live smoke (phase 3, against the dev proxy): roster + gauges render,
hold toggles, switch raises priority and the active dot moves, add-account
completes the OAuth round-trip, remove works, the cost pane shows a
non-zero bucket after one proxied request, both-engines warning shows,
single-engine popup is visually unchanged (window capture vs. today's).

## 8. Phasing

1. **Seam extraction** — models gain inits/Encodable/`id`; `AccountEngine`
   + `EngineCapabilities` + `EngineFleet`; `CswapEngine`; `FleetState`;
   `EngineRegistry`; AppModel/consumers rewired; cache format; tests.
   Gate: `swift test` green, popup pixel-identical on this Mac (capture).
2. **CLIProxyEngine** — `ProxyMapping`, HTTP client, keychain, pane,
   `FleetStack` + header, layer warning, usage ledger. Fixture tests.
3. **Dev proxy + live smoke** — brew install, config, service, OAuth add,
   fixtures lifted and redacted, drift vs `81e1b53` recorded, TODO.md.

Follow-ups (own issues, not v1): Codex onto `AccountEngine` (its pane
folds into the popup); mirror snapshot carrying `[EngineFleet]` for the
phone; Linux tray (cswap-only until then); upstream PR for a server-side
quota endpoint (cliproxyapi-backend.md candidate 1); push triggers /
resume generalised beyond the primary Claude fleet.

## 9. Verified live 2026-09-02 — drift vs the `81e1b53` reading

Dev proxy: Homebrew `cliproxyapi` 7.2.145 (upstream latest 7.2.147),
config at `/opt/homebrew/etc/cliproxyapi.conf` (the formula's
DefaultConfigPath — not `~/.cli-proxy-api/config.yaml`; the original
is kept as `cliproxyapi.conf.orig`), `brew services` unit, secret key
in `~/.cli-proxy-api/infinitus-dev-management-key` (mode 600) and in
the keychain (`com.huuloc.infinitus.cliproxy` / `http://127.0.0.1:8317`,
ACL: the signed debug binary + Infinitus.app). Routing `fill-first`.

- Management routes answer **401** without/with a wrong key once a key
  is configured (the 404 in §3 is the no-key-configured case). Both map
  to `EngineError.unauthorized`.
- `GET /auth-files` entry keys seen live: account, account_type,
  auth_index, created_at, disabled, email, failed, id, label, modtime,
  name, path, provider, quota, recent_requests, runtime_only, size,
  source, status, status_message, success, type, unavailable,
  updated_at — `priority`/`note`/`weight` appear only when set.
- `POST /api-call` relays Anthropic verbatim: the June credential
  answered **401 "OAuth access token has expired"**, and after a few
  probes **429** (the usage endpoint's budget, per cswap's poll_policy).
  Engine rule: 401 marks the credential expired — sticky until a 200 —
  and renders `relogin_required` with the browser re-login action; a
  429/network failure or a credential in its 5-minute backoff renders
  `usage_unavailable` (SentinelNotes falls back to "usage unavailable"),
  never a healthy-looking row.
- Request JSON is serialized without slash escaping (the proxy accepts
  both; tests match on the URL).
- Two fleets render as designed: `Claude · cswap` above `Claude ·
  CLIProxyAPI`, verified in the Playground via `playctl fleets 2`
  (a relabeled copy of the demo fleet). A single fleet is unchanged
  (capture-compared against the pre-#8 bundle).
- `oauth/profile`: cswap only reads uuid/email from it; `plan` is
  derived the way the proxy's own management page does
  (Max/Pro/Team/Free), coarser than cswap's local "Max 20x".
- Unsigned dev builds trip a keychain ACL prompt on every rebuild;
  `Keychain.read` skips UI (`kSecUseAuthenticationUISkip`) so launch
  never blocks, and the dev loop signs the debug binary with the Apple
  Development identity (stable designated requirement) —
  `codesign --force --sign "<Apple Development…>" --identifier
  com.huuloc.infinitus.dev .build/…/Infinitus`.
- Still open: a fresh Claude sign-in through the pane's "Add account"
  (needs a person in the browser); live fixtures are hand-written from
  the upstream shapes above, not lifted from a redacted capture.

- **Live PATCH round-trip verified 2026-09-02** (`CLIProxyLiveTests.testLiveHoldAndNoteRoundTrip`,
  reversible): `PATCH auth-files/status {name, disabled}` and
  `PATCH auth-files/fields {name, note}` read back exactly as the stubs
  assume. `switchTo` (priority) and `remove` are still stub-only —
  they would leave a permanent mark on the dev proxy.
- **Accounts pane routes through the seam**: remove goes via
  `FleetState.remove`, and the in-app login flow is shown only when the
  primary fleet is cswap (with cswap off, the pane lists the proxy's rows
  and points to the CLIProxyAPI tab for adding).
- **OAuth add needs `is_webui=true`** (live 2026-09-02): the proxy starts
  the port-54545 callback forwarder (→ its own `/anthropic/callback`)
  only under that flag; without it the browser redirect is refused.
  The in-app chooser (system sheet / private window) then just has to
  reach `localhost:54545`, which it does.
- **Usage poll budget is per account** (user 2026-09-02, 429s): the proxy
  engine caches usage per credential for `usageTTL` (5 min), fetches once
  per email when two credentials share one, and `AppModel.refreshSnapshot`
  offers every engine the usage the others fetched (`offerSharedUsage`,
  by email) so the same account in two fleets is polled once.

