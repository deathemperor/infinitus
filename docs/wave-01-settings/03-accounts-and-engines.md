# 03 — Accounts pane and the three engine panes

**Depends on `01`.** Compile against `01`'s final `SettingsPane`
protocol. Read `00-architecture.md` first.

This is the largest task in the wave: four panes, and the one place where
CLAUDE.md's engine-isolation rule is easiest to break. Read the rule
before writing code:

> **Account policy lives in the engines.** Auto-swap, pick-first and
> ordering come from each engine's own knobs (cswap `autoswitch.*`, the
> proxy's priority); the app only sets those and never runs a second
> policy on top. Missing knob → upstream PR, never a fork.
>
> **Every engine touchpoint is a `cswap … --json` subprocess** or the
> engine's own HTTP API. Never read `~/.claude-swap-backup/*`.

Everything below forwards an ask and reports the engine's answer,
verbatim — including a refusal. `TrayFleet.requestSwitch` is the model
(`TrayFleet.swift:236-267`).

---

# Pane A — Accounts

Mac source: `Sources/Infinitus/AccountsPane.swift:572-849`
(the pane; the first 570 lines are `TokenFlow`, which does not port).
Descriptor: `id: "accounts"`, glyph `` (Contact), tint
`WinDark.rgb(40, 110, 230)` (the Mac's `.blue`).

## Data source

`TrayFleet.cachedFleets() -> [EngineFleet]` already returns every fleet
the active engine holds — Claude for cswap, or Claude/Codex/Gemini/Kiro
for 9Router (`TrayFleet.swift:66-78`). That is the same `[EngineFleet]`
the Mac's `model.fleets` carries.

**One section per fleet**, exactly as the Mac does (user 2026-09-02:
"cswap account management is under Accounts but CLIProxyAPI's is under
CLIProxyAPI, revamp that"). Section title:
`"\(provider.displayName) · \(EngineCatalog.displayName(for: engineID))"`
— reuse `FleetLabel.text` where you can rather than re-joining strings.

`TrayFleet` currently only knows cswap and 9Router. CLIProxyAPI is listed
in `windows/README.md` "Not Yet Implemented" §2. This task adds it — see
Pane C.

## Capabilities gate every control

Never gate on engine identity. `EngineCapabilities`
(`Sources/InfinitusCore/AccountEngine.swift:26-64`) says what each engine
can do:

| engine | capabilities |
|---|---|
| cswap | `.all` (`CswapEngine.swift:16`) |
| CLIProxyAPI | `.switch, .hold, .rename, .remove, .addOAuth, .costReport, .prefer` |
| 9Router | `.switch, .hold, .remove` |

`TrayFleet` returns fleets, not engines, so the pane needs the
capabilities for a fleet's `engineID`. Add to Core (small, pure,
testable — and the Mac can use it too):

```swift
public extension EngineCatalog {
    /// What an engine id can do, without instantiating the engine. The
    /// live objects' `capabilities` stay authoritative; this is for the
    /// hosts that only hold an id (the Windows tray, a mirrored snapshot).
    static func capabilities(for engineID: String) -> EngineCapabilities {
        switch engineID {
        case "cswap": return .all
        case "cliproxy": return [.switch, .hold, .rename, .remove, .addOAuth, .costReport, .prefer]
        case "9router": return [.switch, .hold, .remove]
        default: return []
        }
    }
}
```

Test it against the live engines so the two can never drift:
`XCTAssertEqual(EngineCatalog.capabilities(for: CswapEngine.engineID), CswapEngine(...).capabilities)`
for all three.

## Row layout

Owner-drawn rows inside the pane's host — **not** a `SysListView32`. Two
reasons: the header is unstylable dark (see `00-architecture.md`), and
each row carries five hit targets that a list view would make into a
custom-draw exercise anyway.

```
 #  Name          email                    plan     chips      ★  →  ⏸  ⟲  🗑
────────────────────────────────────────────────────────────────────────────
 1  alpha         alpha@example.com        Max 20x  active     ★  ─  ⏸  ⟲  🗑
 2  bravo         bravo@example.com        Max 5x              ☆  →  ⏸  ⟲  🗑
 3  charlie       charlie@example.com               held  ✕    ☆  →  ▶  ⟲  🗑
 4  delta         delta@example.com                 re-login   ☆  →  ⏸  ⟲  🗑
```

Columns at 96 dpi: number `px(24)`, name `px(140)` (an **editable EDIT**
when `.rename`, else static text), email `px(200)`, plan chip
`px(70)`, status chips `px(110)`, then the action buttons right-aligned
at `px(26)` each.

Controls per row:
- **Name** — an `EDIT` when the fleet has `.rename`. Commit on `EN_KILLFOCUS`
  and on Enter; an empty value **unsets** the alias (`cswap alias N
  --unset`, `CswapCLI.setAlias` already handles the empty case). Show the
  email's local part as the placeholder. The Mac uses a `RenameField`
  with exactly this contract.
- **★ prefer** — only when `.prefer` **and** `account.preferred != nil`.
  `preferred == nil` means this engine build has no such knob, so no star
  at all (`AccountsPane.swift:714-717`). Show the flip optimistically at
  half opacity until the engine confirms, and keep a `pendingPreferred`
  map like `FleetState` does.
- **→ switch** — when `.switch` and not already active. Routes through
  `TrayFleet.requestSwitch(to:provider:report:)` — which already exists,
  already runs off the UI thread, and already carries the provider so a
  Gemini row's #2 is not read as a Claude #2.
- **⏸ / ▶ hold** — when `.hold`. `cswap disable N` / `cswap enable N`
  (`CswapCLI.setRotation`), or the engine's `setHold`.
- **⟲ relogin** — cswap only, and it does **not** open a browser here.
  Show a dialog with the exact commands and a Copy button:
  ```
  Re-login this account
  Infinitus can't host Claude's browser sign-in on Windows (no WebKit).
  In a terminal:
      claude auth login --claudeai --email alpha@example.com
      cswap add
  The second command captures the fresh credential back into slot 1.
  [ Copy commands ]  [ Close ]
  ```
  This is honest and useful; a greyed button with no explanation is not.
- **🗑 remove** — when `.remove`. Confirmation dialog first, wording from
  the Mac (`AccountsPane.swift:612-624`):
  "Remove alpha? cswap forgets its stored credential. The Claude account
  itself is untouched — you can add it back any time." Buttons
  `Remove` (destructive) / `Cancel`. Use `MessageBoxW` with
  `MB_YESNO | MB_ICONWARNING` — a modal for a destructive action is
  correct here, and hand-rolling a dark confirmation window is not worth
  it. (`MessageBoxW` will be light-themed; accept that.)

Status chips, painted (not controls) — the Mac's `statusChip`
(`AccountsPane.swift:801-818`). Active and health are **separate facts**;
both can show:
- `active` → green pill.
- `disabled == true` → grey "held" pill.
- else `usageStatus != "ok"` → orange pill with
  `SentinelNotes.short(for:)` (`DisplayLogic.swift:186-197`) — already
  ported Core, use it rather than `replacingOccurrences(of: "_", with: " ")`.

Reordering: cswap has `.reorder`, and the Mac drags rows. Drag-and-drop
in owner-drawn GDI is a real chunk of work. **Ship ▲/▼ buttons instead**
(two more `px(20)` targets at the left of the row, or a single pair that
acts on the selected row), calling `cswap reorder n1 n2 … --json` with the
new order. Say in the caption: "Use ▲▼ to set the rotation order — Rotate
cycles through them." Drag can be a follow-up issue.

Also on the pane, per fleet, matching the Mac's captions
(`AccountsPane.swift:777-796` — each sentence appears only when the fleet
has the control it describes):
- `.reorder` → "Use ▲▼ to set the rotation order — Rotate cycles through them."
- `.prefer` → "Star an account to have the engine land on it first when it
  switches." / when no account reports `preferred`: "Stars need a cswap
  with the autoswitch.preferred setting (claude-swap PR #312)."
- `.switch`/`.hold` → "→ switches to that account; ⏸ holds it out of
  rotation (it stays listed)."
- `.rename` → "Type in the Name field to rename an account (shown
  everywhere); clear it to go back to the email."

Per-fleet buttons under the rows:
- **Randomize names** when `.rename` — `theme.randomAccountNames(count:)`
  then one `cswap alias` per account. The theme is
  `settings.gamificationStyle`'s `RowTheme`; the Off theme and
  pool-less custom themes draw from every built-in
  (`RowTheme.randomAccountNames`, already handles this).
- **Add account…** — no OAuth here. A dialog with the commands:
  ```
  Add an account
  Sign in with Claude Code, then hand the credential to cswap:
      claude auth login --claudeai
      cswap add
  Or register an existing token (it is read from stdin, never argv):
      cswap add-token -
  9Router connections are added in its dashboard: Providers →
  Connect Claude Code.
  [ Copy commands ]  [ Open 9Router dashboard ]  [ Close ]
  ```
- **Back up accounts… / Restore…** when `.backup` (cswap only). The CLI
  already implements both with every guard
  (`windows/Sources/InfinitusWin/Backup.swift`, `windows/README.md`
  "Backup & restore"). The pane must:
  - use `GetSaveFileNameW` / `GetOpenFileNameW` (comdlg32, no COM);
  - show the plaintext-credential warning **on screen, always**, not only
    in a dialog: "The backup file contains ACCOUNT CREDENTIALS in plain
    text. Anyone who reads it can use those accounts. Keep it out of git
    and delete it when you're done.";
  - offer the `--full` checkbox with the Mac's help: "Off: each account's
    OAuth credential only. On: the whole ~/.claude.json.";
  - restore **additively first**; only if the engine says slots would be
    replaced, ask for confirmation and re-run with `--force --yes`. Never
    default to force.

Empty states:
- no engine → "No swap engine found. Install claude-swap
  (`uv tool install claude-swap`) or point Claude Code at 9Router."
- engine, no accounts → "No accounts yet — `cswap add` registers one."
  (the tray already uses this exact sentence, `TrayFleet.swift:122-123`).

## Refresh

`activate()` calls `TrayFleet.refresh()` then renders `cachedFleets()`.
A 3 s `SetTimer` on the pane (killed in `deactivate()`) re-reads the
cache — same pattern and same justification as `FleetWindow`'s
(`FleetWindow.swift:334-341`): the engine layer coalesces behind a 30 s
TTL, so the tick is nearly free and a visible pane never sits on stale
rows after a switch. After any mutation, `TrayFleet.invalidate()` +
`refresh(force: true)`.

Every engine call goes through `ctx.async`. A `cswap` shell can take 20 s
(`TrayFleet.timeout`); blocking the UI thread for that is not an option.
Disable the row's buttons while its own mutation is in flight, and show
the engine's reply in a status line at the bottom of the pane — verbatim,
including refusals (`SwitchOutcome.message` already does this).

---

# Pane B — cswap engine

Mac source: `Sources/Infinitus/EnginesPane.swift:7-129`
(`ClaudeEnginePane`) + `SettingsPane.swift` (the spec-driven form) +
`ResumeReliabilityPane.swift`.
Descriptor: `id: "cswap"`, glyph `` (Sync), engine section, badge live
when `CswapLocator.locate() != nil`.

## The spec-driven form — do not hand-wire keys

This is the important half. `cswap config list --json` returns
`ConfigList{ settings: [SettingEntry] }`, and each `SettingEntry` carries
`key`, `value`, `isSet`, `kind` (`bool`/`int`/`float`/`choice`/…),
`help`, `default`, `lo`, `hi`, `choices`
(`Sources/InfinitusCore/Models.swift:228-252`). The Mac renders a widget
**from the metadata** and hand-wires nothing — "a new SettingSpec in
Python appears here with no Swift change"
(`Sources/Infinitus/SettingsPane.swift:4-6`).

Today's Windows dialog hardcodes seven keys. Replace that with the same
generic renderer:

- group by key prefix, in the order the CLI emits them; section titles
  via `SettingsFormBody.sectionTitle` ("autoswitch" → "Auto-switch",
  "ui" → "Interface"). **Move `sectionTitle` and `humanLabel`
  (`SettingsPane.swift:114-133`) into Core** so both platforms share them;
  they are pure string functions with no SwiftUI in them.
- `kind == "bool"` → checkbox, commits on click.
- `kind == "choice"` → combo of `choices` with a leading "(default)" =
  unset, commits on `CBN_SELCHANGE`.
- otherwise → EDIT, commits on Enter/kill-focus, placeholder
  `"default: \(defaultValue.editableText)"` plus `"(lo–hi)"` when bounded.
- `help` under every control, wrapped, `WinDark.dim`.
- Validate with `SettingDraft.validate(_:for:)`
  (`Sources/InfinitusCore/SettingsLogic.swift:8-47`) before shelling.
  `.valid(v)` → `cswap config set key v`; `.unset` → `cswap config unset
  key`; `.invalid(why)` → red text under the control, no shell call.
- After a successful set, **reload the whole list** (the Mac does) — the
  engine may normalise a value.
- The loading guard matters: while repopulating, a choice control's
  change notification must not auto-commit. The Mac hit exactly this
  (`SettingsPane.swift:13-17`: "auto-committed a `cswap config set` for
  every choice key each time the pane opened"). Set a `loading` flag
  around the repopulate and ignore notifications while it is set.

`JSONValue.editableText` lives in the Mac app
(`SettingsPane.swift:192-203`). Move it to Core as an extension on
`JSONValue` — it is pure and both platforms need it.

## Rest of the pane

```
Claude — cswap engine
  Engine: found at C:\Users\…\.local\bin\cswap.exe        (or "not found")
  [ Open the install docs ]        (when absent)

Resume nudges — Claude Code side
  ✓ Auto-continue at usage limit           on
  ⚠ Cross-session messages                 not set   [ Set accept ]
     While unset, cswap's nudges are held for review …
  These are Claude Code's settings, not cswap's — they decide whether
  cswap's resume nudges actually reach a stopped session. Changes apply
  to sessions started afterwards.

Automatic resume (this box)
  [ ] Nudge limit-stopped sessions automatically
     Runs infinitus-win serve --auto-resume's pass on a 60 s tick. Off
     unless asked for — a nudge types into your session. Needs the swap
     engine, which is the quota signal it reasons about.
  [ Explain what it would do now ]        → runs `infinitus-win resume --explain`

Engine updates
  cswap 0.26.0    latest on PyPI: 0.26.1
  [x] Check PyPI daily
  [ ] Install updates automatically
  [ Update now ]  [ Check for updates ]
  ▸ upgrade output

  [ Release notes ]  [ Engine — claude-swap ]

<the spec-driven sections>
```

### Resume reliability rows

`ClaudeCodeConfig` is portable Core (`SettingsLogic.swift:56-114`) but
its `standard()` hardcodes POSIX paths. Add a Windows branch:

```swift
public static func standard(home: String = NSHomeDirectory()) -> ClaudeCodeConfig {
    #if os(Windows)
    return ClaudeCodeConfig(
        userSettingsURL: ClaudeSessions.configHome().appendingPathComponent("settings.json"),
        // No managed-settings equivalent on Windows; point at a path
        // that never exists so `effectiveValue` falls through to user.
        managedSettingsURL: URL(fileURLWithPath: "\(home)\\.infinitus-no-managed-settings"))
    #else
    …unchanged…
    #endif
}
```

Use `ClaudeSessions.configHome()` — it already resolves
`%USERPROFILE%\.claude` on Windows and is the path the whole daemon uses.
Reading `~/.claude/settings.json` is explicitly allowed by CLAUDE.md.

The two rows are `ResumeReliabilityModel.rows`
(`ResumeReliabilityPane.swift:21-39`) — keys, titles, explanations and
recommended values verbatim. Green check when the effective value matches;
amber warning plus a one-click `Set <value>` when it does not. The write
goes through `ClaudeCodeConfig.writeUserValue`, which **backs the file up
with a timestamp first** — do not reimplement the write.

Header shows `"nudges ready"` or `"1/2 ready"`.

### Engine updates

`UpdateModel` (`Sources/Infinitus/AboutPane.swift:9-140`) is macOS-app
code but is nearly all portable: `cli.version()`, a `URLSession` GET of
`https://pypi.org/pypi/claude-swap/json`, and `PackageVersion` compare.
Reimplement the ~60 lines of logic in the pane (do **not** import the Mac
app), or better: move the version-compare + "is there an update" decision
into Core as a tiny pure function and test it. The PyPI fetch and the
`cswap upgrade` shell stay in the pane.

`cswap upgrade` runs through `CswapCLI.upgrade()` which merges stdout and
stderr and returns the exit status — **display the transcript, never
interpret it** (`CswapCLI.swift:301-305`). Put it behind a collapsed
"upgrade output" area (a read-only multiline EDIT).

Auto-check cadence: 24 h, same as the Mac. Persist the last-check stamp
and the auto-check/auto-install flags in `settings.json`
(`update_auto_check`, `update_auto_install`, `update_last_check`,
`update_notified_version`, `update_attempted_version` — the Mac's key
names). An auto-install must bounce the engine afterwards, which on
Windows means nothing to restart (the tray does not supervise a cswap
daemon) — so just re-read the version and report.

### Automatic resume

`windows/Sources/InfinitusWin/ResumeSupervisor.swift` exists and
`serve --auto-resume` drives it. The checkbox here writes
`settings.autoResume`; the pane explains that it applies to the **daemon**
and takes effect when the daemon next starts. If the tray started the
daemon (`state.daemon`), offer to restart it. "Explain" shells
`infinitus-win resume --explain` and shows the output verbatim — it is
already designed as the human-readable window into the gate's reasoning
(`windows/README.md` "Automatic resume").

---

# Pane C — CLIProxyAPI engine

Mac source: `EnginesPane.swift:141-241`.
Descriptor: `id: "cliproxy"`, glyph `` (NetworkTower), engine section.

This engine is **not wired on Windows at all** today. Two halves:

### 1. The pane

```
Claude — CLIProxyAPI engine
  [ ] Engine on (rotates behind its own endpoint)     (disabled until a key is saved)
      Save the management key below first.
      Flipping an engine restarts the tray.

Management API
  Base URL:          [http://127.0.0.1:8317          ]
  Management key:    [••••••••  (stored, encrypted)  ]
  [ Test connection ]  [ Save ]  [ Forget key ]
  reachable — 3 credential files, routing fill-first
  The key is the proxy's remote-management.secret-key. It is stored
  encrypted for your Windows account (DPAPI) at
  %APPDATA%\Infinitus\cliproxy.json and sent as a bearer header.
  Infinitus never reads the proxy's config or credential files.

Routing                                    (only when the engine is on)
  Strategy:  [fill-first  v]
  [x] Session affinity (a conversation stays on one credential)
  <RoutingNotes explainer for the selected strategy>

Accounts
  The proxy's credentials are managed in the Accounts tab, next to the
  other engines'.
```

`CLIProxyEngine` is portable Core (`#if canImport(FoundationNetworking)`
at the top; pure `URLSession`). `probe()`, `setRoutingStrategy`,
`setSessionAffinity`, `routingStrategies` all exist. `RoutingNotes`'
explainer strings (`EnginesPane.swift:336-378`) are pure text — **move
them to Core** as `ProxyRoutingNotes.explainer(strategy:)` and
`.affinityWarning(strategy:affinity:)` so both platforms say the same
thing, and test them.

Secret storage: `WinSecret.protect` (DPAPI) into
`%APPDATA%\Infinitus\cliproxy.json`, with the same user-only DACL as
`pair-token` (`WinPairingStore.restrictToUser` — make it reusable, it is
currently `enum WinPairingStore`'s private-ish member in the daemon
target; the tray has its own copy of the pairing code already, so add the
DACL helper to `InfinitusTrayWin` too or promote it).

### 2. Wiring it into `TrayFleet`

`TrayFleet.cachedFleets()` must include CLIProxy's fleets when the engine
is enabled and a key is present, so the Accounts pane and the accounts
panel show them. Follow the 9Router precedent exactly
(`NineRouterFleet.swift`): a `CLIProxyFleet` enum in Core with a 30 s
cache, `isAvailable()`, `fleets()`, `refresh(force:)`, `invalidate()`,
and switch/hold/remove forwarding.

**This may be more than fits in one dispatch.** If so:
- land the pane (config, probe, routing) and the DPAPI store;
- return `DONE_WITH_CONCERNS` naming the fleet wiring as the remainder,
  and file an issue;
- the Accounts pane then simply shows no CLIProxy section, which is
  today's behaviour and not a regression.

Do **not** half-wire it: a fleet that appears but whose switch silently
does nothing is worse than no fleet.

---

# Pane D — 9Router engine

Mac source: `EnginesPane.swift:245-332`.
Descriptor: `id: "9router"`, glyph `` (Rotate / branch), engine section.

Mostly a re-home of what the Legacy pane already does, plus parity bits:

```
Claude — 9Router engine
  [x] Engine on (rotates behind its own endpoint)
      Claude Code is routed via 9Router — env.ANTHROPIC_BASE_URL in
      ~/.claude/settings.json points at it, and the 9Router fleet is the
      one the tray tooltip and the resume nudge follow.
      9Router rotates its connections per request in priority order and
      falls back on quota errors. Infinitus reads the roster and quotas,
      and sets priority / hold; the rotation policy stays 9Router's.

Dashboard API
  Base URL:          [http://127.0.0.1:20128         ]
  Dashboard password:[••••••••                       ]
  [ Test connection ]  [ Save ]  [ Forget password ]
  reachable — 5 connections, 3 Claude
  The password is the one the 9Router dashboard asks for. Leave it empty
  if 9Router's "require login" is off. It is stored on disk at
  %APPDATA%\Infinitus\9router.json, readable only by your Windows
  account. Infinitus never reads 9Router's database or config.

Accounts
  9Router's connections are managed in the Accounts tab. Adding one is
  done in the 9Router dashboard (Providers → Connect Claude Code).
  [ Open 9Router dashboard ]
```

Required changes beyond a move:
- **Apply the user-only DACL to `9router.json`.** It holds a password in
  plaintext today and inherits whatever ACL `%APPDATA%\Infinitus` has.
  Three lines, using the same helper as `pair-token`. Do this even though
  the plaintext format is unchanged — see the security note in
  `00-architecture.md`.
- The routed-via-9Router banner comes from
  `ClaudeCodeRouting.isRouted(ClaudeCodeRouting.anthropicBaseURL(), to:)`,
  which `TrayFleet.engineIndicator()` already calls. Show the **warning**
  variant (amber) when Claude Code is routed at 9Router but the engine is
  off: "Claude Code's env.ANTHROPIC_BASE_URL points at 9Router, but the
  9Router engine is off — Claude Code hits it unmanaged."
  (`EngineToggleNotes`, `EnginesPane.swift:392-402`).
- "Test connection" must go through `ctx.async` (fixing the off-thread
  write described in `01`, if `01` did not already move it).
- The engine toggle writes `settings` and says "Flipping an engine
  restarts the tray" — then actually restart, or (simpler and honest) say
  "takes effect when the tray restarts" and don't. Pick one; the Mac
  relaunches. Report which.

## Tests

Core (`Tests/InfinitusCoreTests/`):
- `EngineCatalog.capabilities(for:)` vs each live engine's own
  `capabilities` — three assertions.
- `SettingsFormLabels` — `sectionTitle("autoswitch") == "Auto-switch"`,
  `sectionTitle("ui") == "Interface"`, `sectionTitle("misc") == "Misc"`;
  `humanLabel("autoswitch.limitScanIntervalSeconds") == "Limit scan interval seconds"`.
- `JSONValue.editableText` for every case.
- `ProxyRoutingNotes` — one assertion per strategy, plus the
  affinity-nil / affinity-false / affinity-true warnings.
- `ClaudeCodeConfig.standard()` on Windows points at
  `ClaudeSessions.configHome()/settings.json`.

Windows (`InfinitusWinUI`):
- `testRowActionsFollowCapabilities` — given a fleet whose engineID is
  `"9router"`, the row model exposes switch/hold/remove and **not**
  rename/prefer/backup. Do this against a pure `AccountRowModel` struct
  the pane builds from `(EngineFleet, EngineCapabilities)`; that struct is
  the testable seam, not the HWNDs.
- `testPreferStarHiddenWhenPreferredIsNil`.
- `testDPAPIRoundTrip` — protect/unprotect a string; and that a corrupt
  blob returns nil rather than crashing.
- `testCLIProxyConfigRoundTrip`.
- `testSettingsFormGroupsByPrefixInEmittedOrder` — feed a fixture
  `ConfigList` and assert the section/entry ordering.

## Acceptance

1. Accounts pane lists every fleet `TrayFleet.cachedFleets()` returns,
   each under its `provider · engine` header.
2. Every action button appears only when the fleet's capabilities allow
   it; a 9Router fleet shows no rename field and no star.
3. Switch, hold, rename, remove, prefer, reorder each reach the engine
   and the pane reports the engine's own answer, including refusals.
4. No engine call blocks the window; the pane stays responsive during a
   20 s `cswap` timeout.
5. Remove asks first and names the account.
6. Backup/restore work end to end, and the plaintext-credential warning
   is on screen the whole time.
7. cswap pane renders **every** key `cswap config list --json` returns,
   not seven — verify by adding a key upstream or by feeding a fixture.
8. An invalid value shows the reason and does not shell out.
9. Opening the cswap pane does **not** write any config (the loading
   guard).
10. Resume-reliability rows read `%USERPROFILE%\.claude\settings.json`,
    and `Set accept` writes it with a timestamped backup beside it.
11. PyPI check reports current vs latest and `Update now` shows the
    transcript.
12. 9Router pane saves, probes, opens the dashboard, and `9router.json`
    ends up with a user-only DACL (verify with `icacls`).
13. CLIProxy pane saves a DPAPI-encrypted key; the file is unreadable as
    plaintext (`type` it and confirm).

## Report

Status; files; tests; commit. Plus:
- whether CLIProxy fleet wiring landed or was deferred (+ issue);
- whether the engine toggle relaunches the tray or defers to next start;
- the `icacls` output for `9router.json` and `cliproxy.json`;
- anything where a capability gate had to be guessed rather than read
  from `EngineCapabilities`.
