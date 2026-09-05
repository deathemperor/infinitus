# 01 — Settings shell and navigation

**Blocks everything else in this wave.** Panes `02`–`06` compile against
the protocol this task defines. Land it first, alone.

Read `00-architecture.md` before starting. It is not repeated here.

## Goal

Replace the single 706-line flat dialog
(`windows/Sources/InfinitusTrayWin/SettingsWindow.swift`) with a
CodexBar-style shell: searchable sidebar on the left, one `WS_CHILD` pane
container on the right, dark chrome, DPI-correct, resizable, keyboard
navigable.

At the end of this task the window opens with **one real pane** — a
"Placeholder" pane that renders its own title and nothing else — plus
whatever stub descriptors the other five specs will fill in. Nothing that
exists today may regress: the four settings the current dialog exposes
(autostart, cswap auto-switch, theme combo, 9Router) move verbatim into a
temporary **"Legacy"** pane, so the tray never loses a control mid-wave.
`03` deletes that pane when it lands the real Accounts/engine panes; `02`
deletes the theme combo when it lands Themes.

## Files

| action | path |
|---|---|
| create | `windows/Sources/InfinitusWinUI/SettingsCatalogWin.swift` — pane descriptors, search filter, ID blocks (**no `WinSDK` in signatures**) |
| create | `windows/Sources/InfinitusWinUI/WinSettingsStore.swift` — `WinSettings` + load/save/update |
| create | `windows/Sources/InfinitusTrayWin/Metrics.swift` — shared DPI metrics (moved out of `FleetWindow`) |
| create | `windows/Sources/InfinitusTrayWin/SettingsShell.swift` — the window, sidebar, pane host, message routing |
| create | `windows/Sources/InfinitusTrayWin/SettingsPane.swift` — the protocol, `PaneContext`, `PaneHost` scroll container, shared control helpers |
| create | `windows/Sources/InfinitusTrayWin/Panes/LegacyPane.swift` — today's four controls, verbatim, until `02`/`03` replace them |
| create | `Sources/InfinitusCore/SettingsCatalog.swift` — the shared pane list + `matches` |
| modify | `windows/Sources/InfinitusTrayWin/SettingsWindow.swift` — becomes a ~20-line façade: `show()` forwards to `SettingsShell.show()` |
| modify | `windows/Sources/InfinitusTrayWin/WinDark.swift` — add `selection`, `hover`, `separator`, `destructive`; add `drawTile` |
| modify | `windows/Sources/InfinitusTrayWin/FleetWindow.swift` — use the shared `Metrics`, delete its private copy |
| modify | `windows/Sources/InfinitusTrayWin/main.swift` — `InitCommonControlsEx`, DPI awareness, `IsDialogMessageW` in both loops, `--settings [paneID]` |
| modify | `Package.swift` — add `InfinitusWinUI` target; link `crypt32`, `comdlg32` |
| create | `windows/Tests/InfinitusWinTests/SettingsShellTests.swift` |
| create | `Tests/InfinitusCoreTests/SettingsCatalogTests.swift` |

## Step 1 — Core: `SettingsCatalog`

`Sources/InfinitusCore/SettingsCatalog.swift`. Platform-free. The order
and titles come from `Sources/Infinitus/InfinitusApp.swift:172-253`
verbatim — that order was chosen deliberately (user 2026-08-30: "reorder
the settings", everyday panes first, engines trailing).

```swift
/// The Settings pane list as data, shared by the Mac's SwiftUI sidebar
/// and the Windows Win32 one — so the two can never disagree about what
/// a pane is called or what the search box matches on.
public enum SettingsCatalog {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let keywords: [String]
        /// Engines render in their own trailing sidebar section with a
        /// live dot instead of a tinted tile (CodexBar style).
        public let engine: Bool
    }

    public static let entries: [Entry] = [
        Entry(id: "display",    title: "Display",
              keywords: ["layout", "popup", "size", "compact", "menu bar", "icon", "title", "tray"], engine: false),
        Entry(id: "accounts",   title: "Accounts",
              keywords: ["account", "login", "relogin", "token", "add", "remove", "delete",
                         "oauth", "order", "reorder", "alias", "rename"], engine: false),
        Entry(id: "themes",     title: "Themes",
              keywords: ["theme", "skin", "gallery", "community", "rpg", "row", "gamification"], engine: false),
        Entry(id: "push",       title: "Push",
              keywords: ["slack", "telegram", "webhook", "notification"], engine: false),
        Entry(id: "usage",      title: "Usage",
              keywords: ["spend", "cost", "tokens", "estimate"], engine: false),
        Entry(id: "utilization", title: "Utilization",
              keywords: ["history", "utilization", "waste", "window", "5h", "7d",
                         "weekly", "chart", "over time"], engine: false),
        Entry(id: "stats",      title: "Stats",
              keywords: ["stats", "metrics", "commits", "prs", "lines", "messages",
                         "sessions", "week", "month", "year"], engine: false),
        Entry(id: "activity",   title: "Activity",
              keywords: ["history", "switches", "log", "events"], engine: false),
        Entry(id: "devices",    title: "Devices",
              keywords: ["sync", "settings", "devices", "phone", "iphone", "lan",
                         "companion", "tailscale", "pair", "qr"], engine: false),
        Entry(id: "about",      title: "About",
              keywords: ["update", "version", "license", "links"], engine: false),
        Entry(id: "cswap",      title: "cswap",
              keywords: ["engine", "auto switch", "interval", "config", "threshold",
                         "rotate", "claude", "provider", "update", "upgrade", "pypi",
                         "nudge", "resume", "wake", "session"], engine: true),
        Entry(id: "cliproxy",   title: "CLIProxyAPI",
              keywords: ["proxy", "cliproxy", "router", "management", "key",
                         "engine", "provider", "claude"], engine: true),
        Entry(id: "9router",    title: "9Router",
              keywords: ["9router", "router", "engine", "provider", "claude", "password"], engine: true),
    ]

    public static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// The Mac's `SettingsRoot.filtered` rule: an empty/blank query
    /// matches everything; otherwise a case-insensitive substring hit on
    /// the title or any keyword.
    public static func matches(_ entry: Entry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if entry.title.range(of: q, options: .caseInsensitive) != nil { return true }
        return entry.keywords.contains { $0.range(of: q, options: .caseInsensitive) != nil }
    }

    public static func filter(_ query: String) -> [Entry] {
        entries.filter { matches($0, query: query) }
    }
}
```

The Mac's `settingsTabs(...)` is **not** rewritten in this wave (it builds
`AnyView`s and `Color`s). Add a test asserting the two lists agree so a
future divergence fails loudly:

`Tests/InfinitusCoreTests/SettingsCatalogTests.swift`
- `testEveryEntryHasUniqueID`
- `testEmptyQueryMatchesEverything` (`""`, `"   "`)
- `testTitleMatchIsCaseInsensitive` — `"acc"`, `"ACCOUNTS"`, `"Accounts"`
- `testKeywordMatch` — `"tailscale"` → only `devices`; `"pypi"` → only
  `cswap`
- `testEngineSectionIsExactlyThree` — `entries.filter(\.engine).count == 3`
- `testOrderMatchesTheMacSidebar` — assert the id sequence literally, so
  reordering one side without the other fails.

## Step 2 — Windows: `WinSettings` + store

`windows/Sources/InfinitusWinUI/WinSettingsStore.swift`. The struct is in
`00-architecture.md`; implement it verbatim, `Codable`, every field with a
default, **hand-written `init(from:)` that falls back to the memberwise
default per key**. Reason, verbatim from `Stats.Day`
(`Sources/InfinitusCore/Stats.swift:213-219`): the synthesized initializer
throws on the first missing key, which would drop the whole settings file
on the ground every time a field is added.

Coding keys are the Mac's UserDefaults names (`show_account_name`,
`title_pct`, `title_scoped`, `title_remaining`, `title_reset`,
`title_icon_only`, `refresh_interval`, `gamification_style`,
`push_sessions_done`, `push_all_dead`, `push_last_alive`, `push_waiting`,
`push_aws_login`, `sort_headroom`) so a `SyncSnapshot.app` written by the
Mac imports here. Windows-only fields take new snake_case names
(`tray_balloons`, `mirror_port`, `auto_resume`, `last_pane`,
`window_width`, `window_height`).

```swift
public enum WinSettingsStore {
    public static var url: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("settings.json")
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: WinSettings?

    public static func load(from url: URL = url) -> WinSettings { … }
    public static func save(_ s: WinSettings, to url: URL = url) throws { … }
    public static func update(_ mutate: (inout WinSettings) -> Void) { … }
}
```

Behaviour:
- `load` with no file → defaults, no write, no error.
- `load` with **unparseable** JSON → rename to
  `settings.json.bad-<yyyyMMdd-HHmmss>`, return defaults. Never silently
  overwrite: the user may want to see what broke. Log one line.
- `load` with a *partially* valid file (extra keys, missing keys) →
  decode what is there, defaults for the rest, keep the file.
- `save` writes `settings.json.tmp` then removes + moves onto the target.
  **Not `replaceItemAt`** — the same reason `UsageHistory.prune` avoids it
  (`UsageHistory.swift:149-152`).
- `update` takes the lock, loads (from cache if warm), mutates, saves,
  refreshes the cache. Panes only ever call `update`, so a save from the
  Push pane cannot clobber a field the Display pane just wrote.
- `url` is settable in tests via the parameter; the default is the real
  path. Tests write to a temp dir, never `%APPDATA%`.

## Step 3 — shared `Metrics`

Move `FleetWindow.Metrics` (`FleetWindow.swift:36-60`) to
`windows/Sources/InfinitusTrayWin/Metrics.swift` as a top-level `struct
Metrics`, add the settings-shell fields from `00-architecture.md`, and
have `FleetWindow` use it. Keep the fleet-specific fields
(`barWidth`, `gaugeGap`, `nameWidth`, …) — one struct with both sets is
fine and better than two that drift.

`FleetWindow`'s `idealSize`/`place` signatures keep taking `Metrics`;
only the type's home moves. `FleetLayoutTests` must stay green.

## Step 4 — `SettingsPane` protocol + `PaneContext` + `PaneHost`

`windows/Sources/InfinitusTrayWin/SettingsPane.swift`.

The protocol is in `00-architecture.md`. Implement it plus:

```swift
/// Everything a pane needs from the shell. Handed to `attach`; panes
/// hold it for the window's lifetime.
final class PaneContext {
    let host: HWND                 // the pane's own WS_CHILD container
    let shell: HWND                // the settings window, for PostMessageW
    let instance: HMODULE?
    var metrics: Metrics           // re-made on WM_DPICHANGED
    var font: HFONT?               // Segoe UI, body
    var boldFont: HFONT?
    var captionFont: HFONT?        // smaller, for help text
    let idBase: Int32              // this pane's 512-id block
    /// Ask the shell to post `WM_APP_PANE_RESULT` back to this pane once
    /// `work` finishes on a worker thread. `generation` lets the pane
    /// drop a stale result.
    func async<T>(_ work: @escaping @Sendable () -> T,
                  then apply: @escaping (T) -> Void)
}
```

`PaneContext.async` is the **only** sanctioned way a pane leaves the UI
thread. It:
1. bumps a generation counter for that pane,
2. `Thread.detachNewThread { let r = work(); … }`,
3. stores `(generation, apply-thunk, result)` in a lock-guarded slot on
   the shell,
4. `PostMessageW(shell, WM_APP_PANE_RESULT, WPARAM(paneIndex), LPARAM(slot))`,
5. the shell's handler drains the slot on the UI thread, drops it if the
   generation is stale or the pane is not visible, else calls `apply`.

Because Swift closures cannot cross a `PostMessageW` `LPARAM` directly,
the slot is an index into an array the shell owns. Keep the array small
and reuse freed slots.

`PaneHost` is the scroll container:

```swift
/// A pane's WS_CHILD container with vertical scrolling. Panes place
/// controls in CONTENT coordinates (0 = top of the content); the host
/// offsets them. A pane never sees the scroll position.
enum PaneHost {
    static func create(parent: HWND, id: Int32, ctx: …) -> HWND?
    static func setContentHeight(_ host: HWND, _ height: Int32)
    // handles WM_VSCROLL, WM_MOUSEWHEEL, WM_SIZE via a subclass proc
}
```

Simplest correct implementation: the host is itself a plain child window
whose only job is scrolling; `ScrollWindowEx(host, 0, -delta, nil, nil,
nil, nil, SW_SCROLLCHILDREN | SW_INVALIDATE)` moves the real controls, and
`SetScrollInfo(host, SB_VERT, …)` keeps the bar honest. Clamp so the
content bottom never scrolls above the client bottom. Wheel delta:
`WHEEL_DELTA` notches × `SystemParametersInfoW(SPI_GETWHEELSCROLLLINES)` ×
`metrics.px(20)`.

Shared control helpers, lifted from today's `SettingsWindow` private
functions and made reusable — every pane will need them, and three copies
would be three bug sites:

```swift
enum PaneControls {
    static func label(_ text: String, in ctx: PaneContext,
                      x: Int32, y: Int32, w: Int32, h: Int32,
                      bold: Bool = false, caption: Bool = false,
                      color: COLORREF? = nil) -> HWND?
    static func edit(in ctx: PaneContext, id: Int32,
                     x: Int32, y: Int32, w: Int32, h: Int32,
                     password: Bool = false, multiline: Bool = false,
                     readOnly: Bool = false) -> HWND?
    static func checkbox(_ text: String, in ctx: PaneContext, id: Int32, …) -> HWND?
    static func button(_ text: String, in ctx: PaneContext, id: Int32,
                       default_: Bool = false, destructive: Bool = false, …) -> HWND?
    static func combo(_ items: [String], in ctx: PaneContext, id: Int32, …) -> HWND?
    static func sectionHeader(_ title: String, in ctx: PaneContext, y: Int32, width: Int32) -> Int32
    static func helpText(_ text: String, in ctx: PaneContext, x: Int32, y: Int32,
                         width: Int32) -> Int32   // returns the height it used

    // value access (today's setEditText/getEditText/… made public)
    static func text(_ hwnd: HWND?) -> String
    static func setText(_ hwnd: HWND?, _ s: String)
    static func checked(_ hwnd: HWND?) -> Bool
    static func setChecked(_ hwnd: HWND?, _ on: Bool)
    static func comboSelection(_ hwnd: HWND?) -> String
    static func setComboSelection(_ hwnd: HWND?, _ s: String)
}
```

`helpText` must measure: a two-line explanation is common in these panes
(the Mac's `.help()` and caption `Text`s), and a fixed height clips them.
Use `DrawTextW(..., DT_CALCRECT | DT_WORDBREAK)` against the available
width and return the measured height so the caller can advance `y`.

Every helper wires `WM_SETFONT`. Every button is
`BS_PUSHBUTTON | BS_OWNERDRAW` (or `BS_DEFPUSHBUTTON | BS_OWNERDRAW`) —
that is not optional; see `WinDark.drawButton`.

## Step 5 — the shell window

`windows/Sources/InfinitusTrayWin/SettingsShell.swift`.

### Creation

```swift
enum SettingsShell {
    private static let className = "InfinitusSettingsShell"
    static func show(paneID: String? = nil)
}
```

- Raise the existing window if open (today's behaviour, keep it), and if
  `paneID` is given, select that pane on the way.
- Style: `WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN`. **Not** `WS_POPUP |
  WS_EX_TOPMOST` — today's dialog is always-on-top over every app, which
  is wrong for a window a user reads while working. Drop `WS_EX_TOPMOST`.
- Size: `settings.windowWidth/Height` when non-zero, else
  `metrics.px(980) × metrics.px(680)`. Convert content→frame with
  `AdjustWindowRectExForDpi` **after** creation, the way `FleetWindow`
  learned to (`FleetWindow.swift:188-194`): `GetDpiForWindow` needs a real
  window, and `CreateWindowExW`'s size is the outer frame.
- Centre on the **monitor the cursor is on** (`MonitorFromPoint` +
  `GetMonitorInfoW`), not on `SM_CXSCREEN` — today's code centres on the
  primary monitor, so on a two-monitor box the window opens on the wrong
  screen.
- `WinDark.applyTitleBar` before `ShowWindow`.
- `WM_GETMINMAXINFO` → `ptMinTrackSize` = `px(900) × px(620)`.

### Sidebar

Owner-drawn in the parent's `WM_PAINT`, double-buffered exactly like
`FleetWindow.paint` (memory DC + `CreateCompatibleBitmap` + `BitBlt`;
`WM_ERASEBKGND` returns 1).

Layout, top to bottom, all through `metrics.px`:

```
 y=14   search EDIT           x=10, w=sidebarWidth-20, h=fieldHeight+4
 y=+10  ── general rows ──    each rowHeight tall
          [tile 22×22][8px][title]                  x=8 … sidebarWidth-8
 y=+14  "Engines"  ····  "N on"      caption, dim
 y=+4   ── engine rows ──
          [glyph 18][9px][title]              [● 7px green if live]
```

Row painting:
- selected → `RoundRect`-ish fill with `WinDark.selection`, title in
  `WinDark.text`;
- hovered (tracked via `WM_MOUSEMOVE` + `TrackMouseEvent(TME_LEAVE)`, the
  `FleetWindow` pattern) → `WinDark.hover`;
- otherwise → no fill, title in `WinDark.text`, engine rows in
  `WinDark.dim`.
- General rows carry a **tinted rounded tile** with the pane glyph in
  white — the Mac's `RoundedRectangle(cornerRadius: 6).fill(tab.tint)`.
  Add `WinDark.drawTile(dc:rect:tint:glyph:font:)`. A `RoundRect` with a
  `CreateSolidBrush(tint)` and a null pen is enough; no gradient needed.
- Engine rows carry a plain glyph and a green dot when
  `descriptor.badge?().live == true`. `placeholder == true` → dim the row
  and refuse selection.
- The engines header shows `"\(liveCount) on"`, matching
  `InfinitusApp.swift:319-323`.

Hit testing mirrors `FleetWindow.rowIndex(at:)`: walk the same placement
the paint uses, in one shared function, so the two can never desync.
Return `(section, index)` or nil.

Search:
- The EDIT sends `EN_CHANGE`; on it, re-filter with
  `SettingsCatalog.filter(query)`, repaint the sidebar.
- If the current pane falls out of the filter, **do not switch panes** —
  the Mac doesn't (`SettingsRoot.current` falls back to `tabs.first`, but
  in practice the pane stays because `selection` is untouched). Keep the
  content showing; the sidebar just lists fewer rows.
- Empty result → paint "No settings match" centred in the list area,
  `WinDark.faint`.

### Content host

- Content rect = `(sidebarWidth + 1, 0) … (clientRight, clientBottom)`.
  The 1px is the separator, filled with `WinDark.separator`.
- All 13 (+ Legacy) pane containers are created in `WM_CREATE`, sized to
  the content rect, all `SW_HIDE` except the initial pane.
- `select(paneID:)`:
  1. no-op if already current;
  2. `current.deactivate()`;
  3. `ShowWindow(current.host, SW_HIDE)`;
  4. `ShowWindow(next.host, SW_SHOW)`;
  5. `next.layout(width:height:)` (in case the window resized while it
     was hidden);
  6. `next.activate()`;
  7. persist `lastPaneID`;
  8. `InvalidateRect(shell, sidebarRect, false)`.
- Never `DestroyWindow` a pane container on switch. Handles and state stay.

### Message routing

```swift
switch Int32(bitPattern: msg) {
case WM_CREATE:            build fonts, search box, every pane container
case WM_SIZE:              relayout chrome + visible pane; save size (debounced)
case WM_GETMINMAXINFO:     enforce the minimum
case WM_DPICHANGED:        honour lParam's rect, rebuild fonts+metrics, relayout all
case WM_PAINT:             sidebar (double-buffered)
case WM_ERASEBKGND:        return 1
case WM_MOUSEMOVE:         sidebar hover + TrackMouseEvent
case WM_MOUSELEAVE:        clear hover
case WM_LBUTTONUP:         sidebar hit-test → select
case WM_MOUSEWHEEL:        forward to the visible pane's host
case WM_COMMAND:           search EN_CHANGE; else route by id block to the owning pane
case WM_NOTIFY:            route by NMHDR.idFrom's block
case WM_DRAWITEM:          WinDark.drawButton first; else route to the owning pane
case WM_CTLCOLOR*:         WinDark.controlColor (handled BEFORE the switch, as today)
case WM_APP_PANE_RESULT:   drain the async slot, apply if fresh + visible
case WM_KEYDOWN / WM_SYSKEYDOWN: shortcuts
case WM_CLOSE:             save window size + pane id, DestroyWindow
case WM_DESTROY:           release state, clear the singleton
}
```

Routing by id block: `paneIndex = (cmdID - PaneIDs.base) / PaneIDs.stride`.
Guard the range; an id below `base` is shell-owned.

### Keyboard

Handled in the **message pump**, not only the window proc, because
`IsDialogMessageW` must see the message first for `Tab` traversal:

```swift
while GetMessageW(&msg, nil, 0, 0) {
    if SettingsShell.handles(&msg) { continue }   // IsDialogMessageW + accelerators
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
```

`SettingsShell.handles(_:)` returns true when the message was consumed.
It must be called from **both** loops — the tray's in `run()` and the
`--settings` standalone one — so put it in one place and call it twice.

Shortcuts: `Ctrl+F`/`Ctrl+E` focus search; `Ctrl+Tab`/`Ctrl+Shift+Tab`
cycle panes; `Up`/`Down` move the sidebar selection when the sidebar has
focus or the search box does (so a user can type then arrow down, like
the Mac); `Esc` closes; `Enter` in the search box jumps to the first
match.

## Step 6 — the Legacy pane

`windows/Sources/InfinitusTrayWin/Panes/LegacyPane.swift`. Lift today's
controls **without behaviour changes**:

- autostart checkbox → `TrayAutostart`
- threshold / strategy / interval / cooldown / hysteresis / unhealthy
  ticks / include-API-key → `cswap config list|set`
- `ui.theme` combo
- 9Router base URL / password / Test / Open Dashboard
- Save / Cancel / Reload buttons

Two required fixes while moving it (both are real bugs, both cheap):

1. **`testNineRouterConnection` writes controls off the UI thread**
   (`SettingsWindow.swift:670-686`: `Thread.detachNewThread` → `Task` →
   `DispatchQueue.global().async` → `setEditText`). Route through
   `ctx.async`.
2. **The combo `CB_ADDSTRING` calls pass a dangling pointer.** In
   ```swift
   SendMessageW(hwnd, UINT(CB_ADDSTRING), 0,
                LPARAM(UInt(bitPattern: strWide.withUnsafeBufferPointer { $0.baseAddress })))
   ```
   the buffer pointer escapes the `withUnsafeBufferPointer` closure before
   `SendMessageW` runs. It happens to work today because the array is
   still alive on the stack, but it is undefined behaviour. Use the
   pattern the rest of the file uses for `WM_SETTEXT`:
   ```swift
   wide.withUnsafeBufferPointer { buf in
       SendMessageW(hwnd, UINT(CB_ADDSTRING), 0, LPARAM(UInt(bitPattern: buf.baseAddress)))
   }
   ```
   Fix it in `PaneControls.combo` so every pane inherits the correct form.

Mark the pane's descriptor `title: "Legacy"` and give it no keywords, so
it is findable but not advertised. `02` and `03` delete it.

## Step 7 — `main.swift` wiring

- **First statement of `run()`** (before any window): DPI awareness. Prefer
  a manifest (`00-architecture.md`); if manifest embedding is not
  achievable in this build, call
  `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
  and say so in the report.
- Next: `InitCommonControlsEx` with
  `ICC_STANDARD_CLASSES | ICC_UPDOWN_CLASS | ICC_PROGRESS_CLASS | ICC_LISTVIEW_CLASSES`.
- `--settings [paneID]` opens the shell on a named pane and runs its own
  loop (extend the existing branch at `main.swift:490-498`).
- `--probe` gains a settings section: print every catalogue entry, the
  resolved `settings.json` path, whether it parsed, and the pane count the
  shell built. This is how a failure gets diagnosed without a human at the
  screen — the same reason the tray's `--probe` prints its balloon rules.

## Tests

`windows/Tests/InfinitusWinTests/SettingsShellTests.swift` — everything
here is pure (`InfinitusWinUI`), no HWND:

- `testSettingsRoundTrip` — save then load into a temp dir, every field
  preserved.
- `testMissingFileYieldsDefaults`.
- `testCorruptFileIsQuarantinedAndYieldsDefaults` — write `"{ not json"`,
  assert defaults returned **and** a `.bad-*` sibling exists **and** the
  original path no longer holds the garbage.
- `testPartialFileKeepsKnownKeys` — a file with only `title_pct` decodes
  that and defaults the rest.
- `testUnknownKeysAreIgnored` — a Mac-exported file with `popup_layout`
  etc. loads clean.
- `testUpdateIsLastWriterPerField` — two `update` calls touching different
  fields both survive.
- `testPaneIDBlocksDoNotOverlap` — for 14 panes, every block is disjoint
  and above `PaneIDs.base`.
- `testCommandRoutingResolvesTheOwningPane` — `(base + 3*512 + 7)` →
  pane 3.
- `testScrollClamp` — content 1000 / viewport 400 → max offset 600;
  offsets clamp at 0 and 600.

## Acceptance

1. `swift build --product infinitus-tray-win` exits 0.
2. `swift test` green (Core + Win suites).
3. `infinitus-tray-win --settings` opens a window with a dark caption, a
   dark client area, a 215pt sidebar listing 10 general rows + an
   "Engines" header + 3 engine rows, and a search box.
4. Typing `tail` filters to **Devices** alone; clearing restores all 13.
5. Clicking each row swaps the content and leaves no ghost controls.
6. Resizing the window relayouts; shrinking below the minimum is refused.
7. A pane taller than the window scrolls with the wheel and the scrollbar.
8. `Ctrl+F`, `Ctrl+Tab`, `Tab`, `Esc` behave as specified.
9. The Legacy pane still saves autostart, all seven cswap keys, the theme
   and the 9Router config, and "Test connection" reports without freezing
   the window.
10. Reopening Settings lands on the pane last used, at the last size.
11. Dragging the window to a 150% monitor rescales text and controls
    (`WM_DPICHANGED`), no bitmap stretch.
12. Idle CPU with Settings open: **< 0.5%** over 15 s (Task Manager or
    `Get-Counter`). Record the number in the report.

## Report

Status; files; test one-liner; commit sha + subject; and specifically:
- which DPI-awareness route was taken (manifest or API call) and why;
- whether comctl32 v6 activation worked;
- the measured idle CPU;
- the final `SettingsPane` protocol **verbatim**, since `02`–`06` compile
  against it. If you changed a single signature from this document, say
  so in bold at the top of the report.
