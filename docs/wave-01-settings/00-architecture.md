# Windows Settings — architecture

> Wave 01. Written 2026-09-05 from the repo at `04ce8e8` (branch
> `windows-remote`). Every Mac reference below was read from the source
> named; every Win32 fact was read from `windows/Sources/InfinitusTrayWin/`
> or from the hard-won notes in `CLAUDE.md`. Nothing is guessed.

## The problem

The Mac Settings window is a CodexBar-style shell: a searchable sidebar of
icon-tile rows on the left, one pane on the right, engines in their own
trailing section (`Sources/Infinitus/InfinitusApp.swift:161-412`). It has
**13 panes** (14 with the debug-only Animations tab).

The Windows tray has **one flat dialog**, 706 lines, 500×680 px, fixed
layout, no scrolling, no sidebar
(`windows/Sources/InfinitusTrayWin/SettingsWindow.swift`). It exposes
exactly four things: autostart, seven cswap `autoswitch.*` keys, a `ui.theme`
combo, and 9Router base URL + password. That is roughly 8% of the Mac's
settings surface.

This wave replaces that dialog with a real shell and ports every pane that
has meaning on Windows.

## Parity table — Mac pane → Windows plan

| Mac pane | Source | Windows | Spec |
|---|---|---|---|
| Display | `DisplayPane.swift` | port (subset: no popup/glass/menu-bar prefs; keeps title prefs, tray prefs, autostart, refresh interval) | `02` |
| Accounts | `AccountsPane.swift` (1064 ln) | port (roster, alias, hold, switch, prefer, remove, backup; **no OAuth add** — no WebKit on Windows) | `03` |
| Themes | `ThemesPane.swift` | port (14 built-ins + custom `themes.json`; GDI preview tiles) | `02` |
| Push | `NotifyPane.swift` | port (Slack + Telegram via `cswap notify`, five trigger toggles, test button) | `04` |
| Usage | `UsagePane.swift` | port (no Swift Charts — GDI bar chart + rows) | `05` |
| Utilization | `UtilizationPane.swift` | port (subset: 5h windows, waste, run rate; forecast only when history exists) | `05` |
| Stats | `StatsPane.swift` | port (tiles + heatmap; `StatsScanner` runs on Windows) | `05` |
| Activity | `ActivityPane.swift` | port (switch history + event log; needs a Windows `EventStore`) | `05` |
| Devices | `SyncPane.swift` | port (subset: pair QR, routes, token rotate; **no** iCloud, **no** cloudflared, **no** APNs) | `04` |
| About | `AboutPane.swift` | port (subset: version, GitHub release check, links, license; **no** Homebrew) | `06` |
| cswap engine | `ClaudeEnginePane.swift` | port (spec-driven `config list --json` rows, resume diagnostics, PyPI update check) | `03` |
| CLIProxyAPI engine | `CLIProxyEnginePane.swift` | port (base URL, key, probe, routing strategy) | `03` |
| 9Router engine | `NineRouterEnginePane.swift` | port (base URL, password, probe, dashboard link) | `03` |
| Animations (debug) | `AnimationsDebugPane.swift` | **skip** — the effects it tunes are CAAnimations that do not exist here | — |

### What is deliberately dropped, and why

Each of these is a hard "no", not a "later". State the reason in the pane
so a user is never left looking for a control that cannot exist.

- **Popup layout / popup size / glass transparency / compact rows /
  menu-bar icon / pop-out / revival panel / wall.** These configure the
  macOS `NSPopover`/`NSPanel` presentation. Windows has an accounts
  *window* (`FleetWindow.swift`), not a menu-bar popup. Any of these
  settings would write a key nothing reads.
- **iCloud settings sync** (`SettingsSyncModel`). There is no iCloud Drive
  container on Windows. File export/import **is** ported — it is the same
  `SyncSnapshot` (`Sources/InfinitusCore/SettingsSync.swift`), which is
  already portable Core.
- **Cloudflare named/quick tunnel** (`NamedTunnel.swift`, `QuickTunnel`).
  macOS-only in this repo (`windows/README.md` "Not Yet Implemented" §3).
  The Devices pane says so and offers LAN + tailnet.
- **APNs Live Activity push** (`LiveActivityPusher`). Requires an Apple
  developer key and an Apple push endpoint the Windows daemon does not
  serve (`POST /activities/token` → 204, discarded — `windows/README.md`).
- **OAuth account add** (`TokenFlow`). The Mac hosts `claude auth login`
  on a PTY and shows the OAuth page in a `WKWebView`. Windows Swift has
  neither WebKit nor `openpty`. Accounts are added with `cswap add` /
  `cswap add-token` at a shell, or in the 9Router dashboard; the pane
  prints the exact command.
- **Homebrew update channel** (`BrewUpdater`). No brew. The About pane
  checks the GitHub release and points at `windows/install.ps1`.
- **`Charts`** (Swift Charts). Apple-only framework. Charts are GDI
  polylines/bars — see `05`.

## Shell design: sidebar + child-window content

### Why child windows, not a redraw-everything owner-draw pane

`FleetWindow` paints its whole client area by hand in `WM_PAINT` because
it renders *data* (rows, gauges). Settings renders *controls* — EDIT,
BUTTON, COMBOBOX, LISTVIEW — which are real HWNDs. Recreating them on every
tab switch would leak handles and lose focus/selection state.

So: **one `WS_CHILD` container window per pane**, all created once, all
sized to the same content rect, exactly one `SW_SHOW`n at a time.

```
InfinitusSettingsWindow  (WS_OVERLAPPEDWINDOW, resizable, dark caption)
├── sidebar               owner-drawn region of the parent (no child HWND)
│   │                     — rows are painted in the parent's WM_PAINT and
│   │                       hit-tested in WM_LBUTTONUP, exactly like
│   │                       FleetWindow's account rows
│   └── search EDIT       one real child at the top of the sidebar
├── separator             1px line at x = sidebarWidth
└── content host          the pane child windows stack here
    ├── InfinitusPaneDisplay      WS_CHILD | WS_CLIPCHILDREN [| WS_VSCROLL]
    ├── InfinitusPaneAccounts     …
    ├── … one per pane
```

The sidebar is owner-drawn rather than a `LISTBOX`/`SysListView32` for the
same reason `FleetWindow` is: a themed common control ignores the
`WM_CTLCOLOR*` brush and paints its own light chrome
(`WinDark.swift:100-108` — and `uxtheme`'s `SetWindowTheme`, which would
fix it, is **not in the Windows Swift SDK's module map**, verified
2026-09-05). Painting 14 rows by hand is less code than fighting that.

### The pane protocol

Each pane is a Swift `enum` with static members, mirroring the existing
file-per-window style (`SettingsWindow`, `FleetWindow`, `SessionWindow`).
Panes never call `CreateWindowExW` for a top-level window and never run a
message loop.

```swift
/// One settings pane. Implementations live in their own file and own
/// their child controls; the shell owns the container HWND, the font and
/// the metrics.
protocol SettingsPane: AnyObject {
    /// Sidebar row: title, glyph, tint, and the words the search box
    /// matches (the Mac's `SettingsTab.keywords`).
    static var descriptor: PaneDescriptor { get }

    /// Create the pane's child controls inside `host`. Called once, from
    /// the shell's WM_CREATE. `ctx` carries the shared font handles and
    /// the DPI metrics.
    func attach(host: HWND, ctx: PaneContext)

    /// Re-place every control for a new content size. Called on resize,
    /// on WM_DPICHANGED, and once right after `attach`.
    func layout(width: Int32, height: Int32)

    /// The pane became visible. Load/refresh here, NEVER in `attach` —
    /// 14 panes each shelling out at window-open would take seconds.
    func activate()

    /// The pane was hidden. Stop timers; keep state.
    func deactivate()

    /// WM_COMMAND from one of the pane's own controls. Return true when
    /// handled so the shell can stop looking.
    func command(id: Int32, code: UINT, from: HWND?) -> Bool

    /// WM_NOTIFY (list views, up-downs) — same contract.
    func notify(_ header: UnsafePointer<NMHDR>) -> Bool

    /// WM_DRAWITEM for a pane-owned owner-draw control (theme tiles,
    /// chart canvases). Return true when drawn.
    func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool

    /// The pane's natural content height at `width` — drives the
    /// container's scroll range.
    func contentHeight(width: Int32) -> Int32
}
```

`PaneDescriptor` is the Windows twin of `SettingsTab`
(`Sources/Infinitus/StatusItemController.swift:20-43`):

```swift
struct PaneDescriptor {
    let id: String            // stable key, persisted as the last-open pane
    let title: String         // "Display", "Accounts", …
    let glyph: String         // one Segoe UI Symbol / Segoe Fluent Icons codepoint
    let tint: COLORREF        // the sidebar tile colour (Mac's SettingsTab.tint)
    let keywords: [String]    // search terms beyond the title
    var section: Section = .general   // .general | .engines
    var badge: (() -> ProviderBadge)? = nil   // engines: live dot / dimmed
}

struct ProviderBadge { var live = false; var placeholder = false }
```

Glyphs: **Segoe Fluent Icons** (Windows 11) with a **Segoe MDL2 Assets**
fallback (Windows 10). Both ship with the OS; neither is a new asset. Pick
the codepoint at the descriptor, never inline in the paint code. If neither
font resolves, the tile falls back to the pane title's first letter — a
missing glyph must never render as a tofu box.

### Command ID allocation

The current file hand-numbers IDs (`2001`, `2101`, `2201`…). With 13 panes
that collides. Fix it with a per-pane block:

```swift
enum PaneIDs {
    /// 512 command ids per pane — far more than any pane needs, and the
    /// arithmetic stays readable in a debugger.
    static let stride: Int32 = 512
    static let base: Int32 = 0x1000
    static func block(_ index: Int32) -> Int32 { base + index * stride }
}
```

Pane *n* owns `[base + n*512, base + (n+1)*512)`. Shell-level commands
(search box, Close) live below `base`. A pane that needs a dynamic run of
ids (one per account row) allocates from the top of its own block
downwards and records the mapping in a dictionary, the way
`TrayState.accountCommands` already does (`main.swift:59-60`).

### Window lifetime and the message-loop rule

- One settings window process-wide. `show()` raises the existing one
  (`SettingsWindow.show()` already does this — keep it).
- The tray pumps a Win32 `GetMessageW` loop and **never drains
  `DispatchQueue.main`**. Any background result must come back by
  `PostMessageW`, exactly as `postEngineReport` does
  (`main.swift:350-357`). A `DispatchQueue.main.async` in a pane is a
  silent no-op — this is the single most common way a pane will appear to
  hang. Every async pane (probes, scans, `cswap` shells) posts a private
  `WM_APP+n` to the settings HWND with a slot id, and the pane drains a
  lock-guarded result queue in that handler.
- `WM_NCCREATE` stashes the state pointer in `GWLP_USERDATA`; read it with
  `GetWindowLongPtrW` only — never a Set/Set dance. Writing 0 and putting
  the old value back leaves USERDATA zeroed for any message arriving in
  between, which gave the session window a blank first paint (2026-09-04,
  `FleetWindow.swift:319-321`).
- `Int32(bitPattern: msg)`, never `Int32(msg)`. Windows sends messages
  above `Int32.max` and the checked initializer **traps**
  (`SessionWindow.swift:260-263`).
- Pane containers are `WS_CHILD` of the settings window, so they are
  destroyed with it. Release the retained state in the parent's
  `WM_DESTROY`, once.

### Resize, scroll, keyboard

- Window is `WS_OVERLAPPEDWINDOW` (resizable), min size 900×620 at 96 dpi,
  remembered in `settings.json` (`window.width` / `window.height`).
  `WM_GETMINMAXINFO` enforces the minimum in **device** pixels
  (`Metrics.px`).
- `WM_SIZE` → reposition the search box, the separator and the visible
  pane container; then ask the visible pane to `layout(width:height:)`.
- Panes taller than the content rect get `WS_VSCROLL` on their container.
  The container handles `WM_VSCROLL` and `WM_MOUSEWHEEL` by `ScrollWindowEx`
  + `SetScrollInfo`; `contentHeight(width:)` sets `nMax`. Scroll in units
  of `Metrics.px(20)` per wheel notch × `SPI_GETWHEELSCROLLLINES`.
- Keyboard, per Win32 convention:
  - `Ctrl+F` / `Ctrl+E` → focus the search box.
  - `Up`/`Down` in the sidebar moves the selection; `Tab` leaves it.
  - `Ctrl+Tab` / `Ctrl+Shift+Tab` cycles panes.
  - `Esc` closes the window (`WM_CLOSE`).
  - `IsDialogMessageW` in the message pump gives `Tab`/`Shift+Tab`
    traversal across the pane's `WS_TABSTOP` controls for free. The
    settings window's own loop (`--settings` mode, `main.swift:490-498`)
    and the tray's shared loop both need this — put it in one place.
- The last-open pane id persists to `settings.json`; reopening lands where
  the user left off.

## DPI

`FleetWindow.Metrics` (`FleetWindow.swift:36-60`) is the model: a struct
built from `GetDpiForWindow`, exposing `px(_:)` that scales a 96-dpi
reference number. Promote it to a shared `Metrics.swift` in
`InfinitusTrayWin` and have both windows use it — two copies would drift.

```swift
struct Metrics {
    let scale: Double
    init(hwnd: HWND?) {
        let dpi = hwnd.map { Double(GetDpiForWindow($0)) } ?? 96.0
        scale = max(1.0, dpi / 96.0)
    }
    func px(_ value: Int32) -> Int32 { Int32((Double(value) * scale).rounded()) }

    // Settings-shell reference geometry, 96 dpi
    var sidebarWidth: Int32   { px(215) }   // matches the Mac's 215pt
    var rowHeight: Int32      { px(30) }
    var tileSide: Int32       { px(22) }
    var pad: Int32            { px(12) }
    var fieldHeight: Int32    { px(22) }
    var buttonHeight: Int32   { px(26) }
    var labelColumn: Int32    { px(200) }
    var sectionGap: Int32     { px(14) }
}
```

Rules:
- Every literal that reaches a `CreateWindowExW`/`MoveWindow`/`FillRect`
  goes through `px`. The current dialog hardcodes `20, y, 160, 18` and is
  therefore wrong on a 150% display.
- Fonts are created in device pixels (negative height = character height),
  recreated on `WM_DPICHANGED` — `FleetWindow.makeFonts` is the pattern.
- The app must be **per-monitor-v2 DPI aware** or `GetDpiForWindow` returns
  96 everywhere and Windows bitmap-stretches the window. Declare it in the
  application manifest, not by calling `SetProcessDpiAwarenessContext` late
  (a window created before the call keeps the old awareness). Add to
  `windows/build.ps1` / `install.ps1` the embedding of a manifest with:
  ```xml
  <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
  ```
  If manifest embedding proves impractical in the SwiftPM build, call
  `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
  as the **first statement** of `run()` in `main.swift`, before any
  `CreateWindowExW`. Report which route was taken.
- `WM_DPICHANGED` carries the suggested rect in `lParam` — honour it with
  `SetWindowPos`, then rebuild fonts and re-`layout` every pane.

## Dark theme

`WinDark.swift` already holds the palette, the brushes, the immersive
dark title bar and the owner-draw button. It needs three additions for
Settings and nothing else changes:

```swift
extension WinDark {
    /// Sidebar selection fill (the Mac's Color.accentColor row).
    static let selection = rgb(52, 92, 158)
    /// Hover plate for an unselected sidebar row.
    static let hover = rowBg
    /// Hairline between sidebar and content.
    static let separator = rgb(48, 48, 54)
    /// A destructive action's label ("Remove", "Forget key").
    static let destructive = dangerColor
}
```

Constraints carried over verbatim from `WinDark`'s header:

- `WM_CTLCOLOR*` must return a brush that **outlives the message**. The
  cached `backgroundBrush`/`controlBrush` are process-lifetime for exactly
  this reason. Never `CreateSolidBrush` in the handler.
- Push buttons are `BS_OWNERDRAW`; a themed button ignores the brush.
- Combo boxes keep the system look. Their drop-down is a separate themed
  window that owner-draw does not reach, and `uxtheme` is not in the SDK
  module map (verified 2026-09-05). **Do not attempt `CBS_OWNERDRAWFIXED`
  as a workaround** — it dark-paints the closed control and leaves the
  open list light, which reads as a bug rather than as a limitation.
  Where a dark list matters (the theme gallery), use an owner-drawn
  custom control instead of a combo.
- `WM_CTLCOLORLISTBOX` covers a plain `LISTBOX`. `SysListView32` needs
  `LVM_SETBKCOLOR` / `LVM_SETTEXTBKCOLOR` / `LVM_SETTEXTCOLOR` **and**
  still draws light headers — so the Accounts roster is owner-drawn
  (`03`), not a list view.
- Every new top-level window (there are none in this wave beyond the
  shell) calls `WinDark.applyTitleBar` **before** `ShowWindow`; DWM
  re-renders the frame on the change, so a visible window flashes light
  first (`WinDark.swift:70-80`).

## Data: what is Core, what is local

### Rule

**Anything that decides *meaning* lives in `InfinitusCore` and is shared
with the Mac. Only *presentation* is Windows-local.** This is the rule
`FleetPanel.swift` already establishes for the accounts panel
(`FleetLayout.swift:16-21`: "Only the arithmetic of PAINTING is local; the
arithmetic of MEANING is shared"). Wave 01 does not weaken it.

### Already portable — use as-is, add nothing

| What | Core file | Used by pane |
|---|---|---|
| `RowTheme` + 15 built-ins + `loadCustom`/`saveCustom` | `RowTheme.swift` | Themes |
| `TitlePrefs`, `TitleFormatter`, `ResetLabel`, `AccountVitals` | `DisplayLogic.swift` | Display |
| `SettingEntry`, `ConfigList`, `JSONValue` | `Models.swift:226-285` | cswap engine |
| `SettingDraft.validate` | `SettingsLogic.swift:8-47` | cswap engine |
| `ClaudeCodeConfig` (effective value, backup-then-write) | `SettingsLogic.swift:56-114` | cswap engine (resume diagnostics) |
| `PushTriggers` + `Flags` | `PushTriggers.swift` | Push |
| `Stats`, `Stats.Presentation`, `StatsScanner`, `StatsEvents`, `RepoStats` | `Stats*.swift` | Stats, Activity |
| `UsageHistory`, `WindowTelemetry`, `WasteMath`, `UsageForecast`, `WindowPlanner` | `UsageHistory.swift`, `WindowTelemetry.swift`, `UsageForecast.swift`, `WindowPlanner.swift` | Utilization |
| `TokenRates` / `TokenRateScanner` | `TokenRates.swift` | Utilization |
| `UsageReport` | `Models.swift:287-345` | Usage |
| `MirrorPairing` (token, mask, pair URL) | `MirrorPairing.swift` | Devices |
| `SyncSnapshot` | `SettingsSync.swift` | Devices (export/import) |
| `PackageVersion` | `UpdateCheck.swift` | About |
| `EngineCapabilities`, `EngineFleet`, `AccountEngine` | `AccountEngine.swift` | Accounts, engines |
| `CswapCLI` (all verbs), `CswapLocator` | `Engines/Cswap/CswapCLI.swift` — `#if !os(iOS)`, so Windows gets it, and `defaultCandidates` already has the Windows paths | every engine pane |
| `NineRouterEngine`, `NineRouterFleet` (+ `StoredConfig`, `configURL`) | `Engines/NineRouter/` | 9Router, Accounts |
| `CLIProxyEngine` | `Engines/CLIProxy/` | CLIProxyAPI, Accounts |
| `FleetPanel` | `FleetPanel.swift` | Accounts |

### Core additions this wave needs

Three small, testable, platform-free additions. Each is a *decision* the
Mac already makes inline in SwiftUI and Windows would otherwise duplicate.
Add them with tests in `Tests/InfinitusCoreTests/`; the Mac keeps working
unchanged (nothing is removed).

1. **`SettingsCatalog.swift`** — the pane list as data. Titles, ids,
   keywords, order, section. The Mac's `settingsTabs(...)` keeps building
   its `[SettingsTab]` but reads titles/keywords from here, so the two
   platforms can never disagree about what "Devices" is called or what it
   matches on. Pure strings; no `Color`, no `AnyView`.
   ```swift
   public enum SettingsCatalog {
       public struct Entry: Sendable, Equatable {
           public let id: String
           public let title: String
           public let keywords: [String]
           public let engine: Bool
       }
       public static let entries: [Entry] = [ /* 13 */ ]
       /// Case-insensitive title-or-keyword match — the Mac's
       /// `SettingsRoot.filtered` rule, shared so both search boxes
       /// behave identically.
       public static func matches(_ entry: Entry, query: String) -> Bool
   }
   ```

2. **`ThemePalette.swift`** — `RowTheme`'s colour strings → RGB. The Mac's
   `ThemeColor.resolve` returns a SwiftUI `Color` and lives in
   `InfinitusUI` (macOS-only). Move the *table* to Core as
   `(r, g, b)` triples; `InfinitusUI.ThemeColor.resolve` becomes a
   two-line wrapper over it, and Windows makes a `COLORREF`. Without this,
   the theme names in `RowTheme` ("#ff2d95", "indigo", "secondary") get a
   second, drifting interpretation on Windows.
   ```swift
   public enum ThemePalette {
       public struct RGB: Sendable, Equatable { public let r, g, b: UInt8 }
       /// Named colour or "#rrggbb"; nil for "primary"/unknown so each
       /// platform supplies its own foreground.
       public static func rgb(_ name: String) -> RGB?
   }
   ```
   Note the two names that are **not** literal colours: `"secondary"` and
   `"gray"` both mean the platform's secondary label colour, and
   `"primary"` means the default foreground. Return nil for those and let
   the caller substitute (`WinDark.dim` / `WinDark.text`).

3. **`WinSettingsStore`** (Windows-local, but modelled on Core's shape) —
   see below.

### Persistence: `%APPDATA%\Infinitus\settings.json`

The Mac persists app prefs in `UserDefaults` (`AppModel.swift:213-260`).
Windows has no `UserDefaults` backing store worth relying on under a
non-packaged Swift executable, and the tray already established
`%APPDATA%\Infinitus\` as its config dir (`9router.json`,
`pair-token` — `NineRouterFleet.configURL`, `WinPairingStore.defaultPath`).

**One file, one type, atomic writes:**

```
%APPDATA%\Infinitus\
├── settings.json      ← this wave (app prefs)
├── 9router.json       ← existing (NineRouterFleet.StoredConfig)
├── pair-token         ← existing (user-only DACL)
├── events.jsonl       ← this wave (Activity pane, see 05)
├── usage-history.<machineID>.jsonl  ← this wave (Utilization, see 05)
└── stats\
    ├── transcripts.json   ← StatsScanner cache
    └── repos\*.json       ← RepoStatsScanner cache
```

```swift
/// App preferences for the Windows tray — the subset of the Mac's
/// UserDefaults keys that mean anything here. Keys are the Mac's
/// verbatim (`title_pct`, `gamification_style`, …) so a settings file
/// exported on one platform imports on the other (SyncSnapshot.app).
struct WinSettings: Codable, Equatable {
    // Display / title
    var showAccountName = true
    var titlePct = "both"          // off | 5h | 7d | both
    var titleScoped = false
    var titleRemaining = false
    var titleReset = "countdown"   // off | countdown | clock
    var titleIconOnly = false
    var refreshIntervalSeconds = 60    // 30 | 60 | 300
    // Theme
    var gamificationStyle = "off"
    // Push triggers (PushTriggers.Flags)
    var pushSessionsDone = true
    var pushAllDead = true
    var pushLastAlive = true
    var pushWaiting = true
    var pushAwsLogin = true
    // Tray behaviour
    var trayBalloonsEnabled = true
    var sortByHeadroom = true
    // Devices
    var mirrorPort: UInt16 = 47824
    var autoResume = false
    // Shell
    var lastPaneID = "display"
    var windowWidth: Int32 = 0     // 0 = use the default
    var windowHeight: Int32 = 0
}
```

Store contract:

```swift
enum WinSettingsStore {
    static var url: URL   // %APPDATA%\Infinitus\settings.json
    /// Best-effort: a missing or corrupt file yields defaults, never a
    /// crash — the tray must always come up. A corrupt file is renamed
    /// `settings.json.bad-<stamp>` first so the user can see what broke,
    /// rather than being silently overwritten.
    static func load() -> WinSettings
    /// Atomic: write to `.tmp`, then replace. Never a partial file —
    /// the tray reads this at every launch.
    static func save(_ s: WinSettings) throws
    /// One-value convenience that load-modify-saves under a lock; panes
    /// use this so a save from one pane can't clobber another's field.
    static func update(_ mutate: (inout WinSettings) -> Void) throws
}
```

Rules:
- **Never** put a secret in `settings.json`. The 9Router password stays in
  `9router.json` (existing behaviour), the CLIProxy management key gets
  DPAPI (below), push webhooks stay inside `cswap notify`'s own store and
  are only ever read back **masked** via `cswap notify --json`.
- Values that belong to the **engine** stay in the engine.
  `autoswitch.threshold` and friends are read/written with
  `cswap config list|set|unset --json` — never mirrored into
  `settings.json`. CLAUDE.md: account policy lives in the engines.
- The file is the unit `SyncSnapshot.app` carries, so an exported
  `infinitus-settings.json` from the Mac can be imported here (Devices
  pane) and vice versa. Unknown keys are ignored on both sides.

### Secrets on Windows

There is no keychain. The Mac's `Keychain.swift` has four services; two of
them matter here.

| Secret | Mac | Windows |
|---|---|---|
| 9Router dashboard password | keychain `…9router` | `%APPDATA%\Infinitus\9router.json`, **existing behaviour** — see the warning below |
| CLIProxyAPI management key | keychain `…cliproxy` | `%APPDATA%\Infinitus\cliproxy.json`, value **DPAPI-encrypted** (`CryptProtectData`, `CRYPTPROTECT_UI_FORBIDDEN`), file carries the same user-only DACL as `pair-token` |
| pairing token | `UserDefaults` | `%APPDATA%\Infinitus\pair-token`, user-only DACL — **existing** |
| APNs .p8 | keychain | not applicable |

> **Security note — read before implementing.**
> `9router.json` today stores the dashboard password in **plaintext**
> (`SettingsWindow.swift:83-86`, `NineRouterFleet.StoredConfig`). This
> wave does not silently change that format, because the daemon and the
> tray both read it and a one-sided change would break 9Router account
> reads. What it MUST do: (1) apply the same user-only DACL
> `WinPairingStore.restrictToUser` applies to `pair-token`, so the file is
> not world-readable; (2) state plainly in the 9Router pane that the
> password is stored on disk for this user only; (3) file a follow-up
> issue to move both `9router.json` and the new `cliproxy.json` to DPAPI
> with a versioned format. Do not defer (1) — it is three lines and the
> file is a credential today.

New secrets (the CLIProxy key) are DPAPI from the start:

```swift
/// DPAPI-at-rest for a per-user secret. CryptProtectData ties the blob
/// to this Windows user account: copying the file to another machine or
/// user yields ciphertext nothing can open. Not a substitute for the
/// DACL — apply both.
enum WinSecret {
    static func protect(_ plaintext: String) -> Data?     // CryptProtectData
    static func unprotect(_ blob: Data) -> String?        // CryptUnprotectData
}
```

`CRYPTPROTECT_UI_FORBIDDEN` on both calls: a settings pane must never
block on a system prompt (the Mac learned this the hard way with the
keychain ACL — `CLAUDE.md`, "reads skip UI").

## Threading

One rule, three consequences.

**The UI thread owns every HWND. Nothing that can take longer than ~16 ms
runs on it.**

Slow things, measured or documented in this repo:
- `cswap list --json` — up to 20 s timeout (`TrayFleet.timeout`).
- `cswap usage --days N --json` — "multi-second, streams ~GBs of
  transcripts" (`CswapCLI.swift:292-294`).
- `StatsScanner.scan` — a cold backfill is *minutes*
  (`StatsModel.swift:122-147`); it is chunked with a 64 MB byte budget for
  exactly this reason.
- `NineRouterEngine.probe()` / `CLIProxyEngine.probe()` — network.
- The GitHub release check — network.

Pattern (already used twice in this target —
`TrayFleet.requestSwitch`, `SettingsWindow.testNineRouterConnection`):

```
UI thread                    worker (Thread.detachNewThread)
─────────                    ──────────────────────────────
pane.activate()
  set "Loading…"
  spawn worker  ───────────► do the slow thing
                             lock; queue.append(result); unlock
                             PostMessageW(settingsHwnd, WM_APP_PANE_RESULT,
                                          wParam: paneIndex, lParam: slot)
◄──────────────────────────
WM_APP_PANE_RESULT
  drain the queue under the lock
  pane.apply(result)
  InvalidateRect / SetWindowText
```

Note the existing `testNineRouterConnection` is **subtly wrong** and must
be fixed as part of `03`: it hops `Thread.detachNewThread` → `Task` →
`DispatchQueue.global().async` and then calls `setEditText` from a
*background* thread (`SettingsWindow.swift:670-686`). `SendMessageW`
across threads to another thread's window blocks on that thread's message
pump; it happens to work here only because the target is on the pumping
thread and the message is trivial. Route it through `PostMessageW` like
everything else.

Guards:
- A pane that is deactivated before its worker returns must drop the
  result, not apply it to hidden controls. Give each request a monotonically
  increasing generation counter; compare on arrival (`StatsModel`'s
  `bundleGeneration` is the precedent).
- Never two concurrent scans of the same kind. One `isRefreshing` flag per
  pane under the same lock as the queue (`TrayFleet.isRefreshing`).
- Timers: only the *visible* pane may hold one, killed in `deactivate()`.
  CLAUDE.md's idle-CPU rule is not negotiable — the accounts panel idles
  at 0.13% and Settings must not be worse. Target: **< 0.5% CPU** with
  Settings open on any pane, measured over 15 s.

## Testing

Executable targets cannot be imported by a test target
(`FleetLayoutTests.swift:12-14` — "linking the executable's module kills
it"). So:

- **Pure decisions go to Core** and are tested in
  `Tests/InfinitusCoreTests/` — `SettingsCatalog.matches`,
  `ThemePalette.rgb`, and anything else a pane would otherwise decide.
- **Windows-local pure code** (settings load/save round trip, the corrupt
  file path, ID-block arithmetic, scroll-range maths, search filtering
  over descriptors) goes in `windows/Tests/InfinitusWinTests/`. To be
  testable it must live in a **library** target, not the executable.
  This wave therefore adds:
  ```swift
  // Package.swift, inside #if os(Windows)
  .target(name: "InfinitusWinUI", dependencies: ["InfinitusCore"],
          path: "windows/Sources/InfinitusWinUI")
  ```
  with `InfinitusTrayWin` depending on it. Anything with no `WinSDK`
  window handle in its signature belongs there.
- **Painting and layout** are verified by screenshot, as `FleetWindow`'s
  were (`windows/README.md` "Accounts panel"), plus a
  `infinitus-tray-win --settings <paneID>` flag that opens straight onto
  one pane so each can be shot without clicking.
- `windows/ci.ps1` runs `swift build --product` twice and `swift test` —
  unchanged; the new suite rides along.

## Build

`Package.swift` (`#if os(Windows)` block) gains the `InfinitusWinUI`
target and, for `InfinitusTrayWin`, these linked libraries on top of
what is there:

| library | for |
|---|---|
| `comctl32` | already linked — `InitCommonControlsEx` for the up-down / progress / tooltip controls |
| `crypt32` | `CryptProtectData` / `CryptUnprotectData` |
| `msimg32` | `GradientFill` for the sidebar tiles (optional; a flat `FillRect` is acceptable) |
| `ole32` | only if a shell file dialog (`IFileDialog`) is used for export/import; `GetOpenFileNameW` from `comdlg32` avoids COM entirely — prefer that |
| `comdlg32` | `GetOpenFileNameW` / `GetSaveFileNameW` (Devices export/import, Themes file open) |

`InitCommonControlsEx(ICC_STANDARD_CLASSES | ICC_UPDOWN_CLASS | ICC_PROGRESS_CLASS | ICC_LISTVIEW_CLASSES)`
must run **once at startup** in `main.swift` before any control is
created, and the binary needs a **comctl32 v6 manifest** for the modern
control set. If v6 activation is not achievable, say so in the report and
fall back to v5 controls — do not ship a half-themed window.

## Execution order

See `README.md` in this directory for the dependency graph and the agent
briefs. In one line: **`01` first and alone**, then `02`/`03`/`04`/`05`/`06`
in parallel against the frozen `SettingsPane` protocol.
