# 02 — Display and Themes panes

**Depends on `01`.** Compile against the `SettingsPane` protocol exactly
as `01`'s report states it. Read `00-architecture.md` first.

Two panes, one task: they share the theme colour resolution and both are
pure-preference panes with no engine calls, so one agent doing both avoids
a merge on `ThemePalette`.

---

# Pane A — Display

Mac source: `Sources/Infinitus/DisplayPane.swift` (208 lines).
Descriptor: `id: "display"`, glyph `` (Segoe Fluent `TaskbarSettings`
``, MDL2 fallback `` Settings), tint `WinDark.rgb(150, 90, 220)`
(the Mac's `.purple`).

## What ports and what does not

The Mac pane mixes three unrelated things: menu-bar title format, popup
presentation, and machine behaviour. Only the first and third exist here.

| Mac control | Windows |
|---|---|
| Menu bar shows only the icon | **port** → "Tray tooltip shows only the icon" |
| Show account name in menu bar | **port** → tray tooltip |
| Title percentage (`off`/`5h`/`7d`/`both`) | **port** |
| Reset time in title (`off`/`countdown`/`clock`) | **port** |
| Show model limits in title | **port** |
| Menu bar counts remaining, not used | **port** |
| Popup layout (wide/stacked/hstack) | **drop** — no popup |
| Popup size | **drop** |
| Popup transparency | **drop** |
| Compact popup | **drop** |
| Hide popup actions | **drop** |
| Floating countdown panel | **drop** |
| Wall | **drop** |
| Name unnamed sessions with Haiku | **drop** — the namer shells `claude -p`; out of scope for wave 01, file an issue |
| Show menu bar icon | **drop** — hiding the tray icon would strand the app |
| Refresh interval (30/60/300) | **port** |
| Start at login | **port** — `TrayAutostart` (moves here from Legacy) |
| Keep Mac awake while sessions work | **port** → "Keep Windows awake while sessions are working" (see below) |

New, Windows-only:
- **Balloon notifications** on/off — the tray's `TrayNotify.transitions`
  rules already decide *when*; this is the master switch. Show the two
  rules underneath as help text so the user knows what they get:
  "a session starts waiting on you" and "a session stops while busy".
- **Accounts panel sorts rows by headroom** — `sort_headroom`, the same
  key the Mac's Accounts pane owns. It belongs here on Windows because
  it governs `FleetWindow`'s row order, which is a display concern.

## Layout

One scrolling column. Section headers in bold; help text under the
control it explains, in `captionFont` + `WinDark.dim`, wrapped and
measured (`PaneControls.helpText`).

```
Menu bar → "Tray"
  [x] Tray tooltip shows only the icon
      Just the session counts — no account name or percentages. The
      settings below return when this is off.
  [x] Show account name in the tooltip                        (disabled if icon-only)
  Title percentage:      [both        v]                      (disabled if icon-only)
  Reset time:            [countdown   v]                      (disabled if icon-only)
      When the active account's fuller window resets — as a countdown
      (2h14m) or a clock time (20:29).
  [ ] Show model limits                                       (disabled if icon-only)
  [ ] Count remaining, not used                               (disabled if icon-only)
      Flips the percentages to what's left. The accounts panel gauges
      already count remaining.

Accounts panel
  [x] Sort rows by headroom (active and next first)
      Display only — slot numbers don't move.

Notifications
  [x] Show balloon notifications
      Two events only: a session starts waiting on you, and a session
      stops while it was busy. Routine busy/idle churn is never announced.

System
  [x] Start Infinitus Tray with Windows
      Registers this executable's current path. A debug build registers
      .build\debug — use windows\install.ps1 -Autostart for the release
      binary.
  Refresh interval:      [60 seconds  v]
  [ ] Keep Windows awake while sessions are working
      Holds a power request while any Claude Code session is mid-turn.
      The display may still sleep; the machine won't.
```

## Behaviour

- Every control writes **immediately** on change
  (`WinSettingsStore.update`), like the Mac's `@Published`+`didSet`. There
  is no Save button on this pane. `01`'s Legacy pane had one; Display does
  not — do not add one.
- Disabling: `EnableWindow(hwnd, !iconOnly)` on the five title controls,
  driven from the icon-only checkbox's `BN_CLICKED`, and once in
  `activate()`.
- Autostart reads `TrayAutostart.isEnabled()` in `activate()` (the
  registry can change behind the app) and writes with
  `TrayAutostart.setEnabled`. The setter returns whether it stuck
  (`TrayAutostart.swift:27-28`) — if it returns false, re-read and show
  "couldn't write the Run key" in the status line rather than leaving the
  checkbox lying.
- The autostart help text must carry the debug/release warning verbatim
  from `windows/README.md:101-104` — a user who ticks this in a debug
  tray gets a Run key pointing at `.build\debug`, which breaks on the next
  `swift build --clean`.
- **Refresh interval** currently is a compile-time constant
  (`refreshMilliseconds: UINT = 5000`, `main.swift:37`). Wire it: read
  `settings.refreshIntervalSeconds` at tray start, and on change call
  `KillTimer` + `SetTimer` with the new period. Note the two are different
  clocks — the Mac's `refresh_interval` is the *engine snapshot* cadence
  and the tray's 5 s timer is the *session* re-read. Keep the 5 s session
  tick fixed (it is what drives balloons) and apply this setting to
  `TrayFleet`'s cache TTL instead: `TrayFleet.cacheSeconds` becomes a
  `var` defaulting to 30 and set from this preference. Document that in
  the help text: "How often the accounts panel re-asks the engine."
- **Keep awake**: `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`
  while any session is `busy`, and `ES_CONTINUOUS` alone to release. Call
  it from the tray's existing `refresh()` where `busy` is already
  computed (`main.swift:231-257`), gated on the setting. **Do not** set
  `ES_DISPLAY_REQUIRED` — the Mac's equivalent is `caffeinate -i` and
  explicitly lets the display sleep. Prefer `PowerSetRequest` if the
  simpler API proves unreliable, but `SetThreadExecutionState` is enough
  and needs no handle lifetime management.
- Balloon toggle gates `TrayNotify.balloon` at its call site in
  `refresh()`; leave `TrayNotify.transitions` untouched — it is pure and
  tested.

## Title preview

The Mac has no preview because the menu bar *is* the preview. The Windows
tooltip is not visible while Settings is open, so add one: a read-only
line under the title section rendering the **live** title through
`TitleFormatter.format(account:prefs:now:icon:)`
(`Sources/InfinitusCore/DisplayLogic.swift:85-127`) using the current
active account from `TrayFleet.cached()`, or a fabricated one when no
engine is present:

```swift
Account(number: 1, email: "you@example.com", alias: "alpha",
        usage: Usage(fiveHour: UsageWindow(pct: 21, resetsAt: …),
                     sevenDay: UsageWindow(pct: 68, resetsAt: …)))
```

Re-render on every control change. This is the whole point of the section
and costs ~10 lines — `TitleFormatter` is already portable Core and
already tested.

Pass `icon: ""` (the tray has its own icon) so the preview shows exactly
what the tooltip will.

---

# Pane B — Themes

Mac source: `Sources/Infinitus/ThemesPane.swift` (169 lines) +
`Sources/InfinitusCore/RowTheme.swift`.
Descriptor: `id: "themes"`, glyph `` (Color), tint
`WinDark.rgb(230, 140, 40)` (the Mac's `.orange`).

## Scope

- **15 built-ins**, not 14. `RowTheme.builtins` is
  `[off, rpg, movie, hades, mgs, agent, swe, scifi, west, cyber, gothic,
  musical, earth, cosmo, ocean]` (`RowTheme.swift:461-464`). The brief's
  "14" omitted `agent` ("AI Agentic"). Render whatever `builtins`
  contains — never a hardcoded list.
- **Custom themes** from `%APPDATA%\Infinitus\themes.json`.
- **Community gallery: out of scope.** The Mac's
  `CommunityThemesSection` fetches a GitHub index over HTTPS and writes
  the local file. It is a clean follow-up but it is network + install
  semantics, and this pane is already the largest owner-draw job in the
  wave. Put a one-line note and a "Open the gallery in your browser"
  button pointing at
  `https://github.com/deathemperor/infinitus/tree/main/themes`.

## Core work: `ThemePalette`

`Sources/InfinitusCore/ThemePalette.swift`, per `00-architecture.md`.

Move the colour table out of `Sources/InfinitusUI/ThemeColor.swift:11-33`
into Core as RGB triples, and reduce `ThemeColor.resolve` to:

```swift
public static func resolve(_ name: String) -> Color {
    guard let c = ThemePalette.rgb(name) else {
        return name == "secondary" || name == "gray" ? .secondary : .primary
    }
    return Color(red: Double(c.r)/255, green: Double(c.g)/255, blue: Double(c.b)/255)
}
```

The Mac's rendering must be **byte-identical** afterwards. The named
colours it maps to SwiftUI system colours (`.red`, `.blue`, …) are *not*
fixed RGB — they are dynamic. So `ThemePalette` returns nil for every
name SwiftUI resolves dynamically, and Windows supplies its own table for
those names. Concretely:

```swift
public enum ThemePalette {
    public struct RGB: Sendable, Equatable, Hashable {
        public let r: UInt8, g: UInt8, b: UInt8
    }
    /// "#rrggbb" only. Named colours are platform-dynamic and return nil
    /// — `named` below carries a fixed fallback for platforms without a
    /// system palette (Win32).
    public static func hex(_ name: String) -> RGB?
    /// The canonical names a RowTheme may use.
    public static let names = ["red", "blue", "green", "yellow", "orange",
                               "purple", "indigo", "cyan", "teal", "pink",
                               "mint", "brown", "gray", "secondary", "primary"]
    /// Fixed sRGB for each name — Apple's dark-appearance system colours,
    /// so the Windows tray and the Mac popup read the same at a glance.
    /// `secondary`/`gray`/`primary` return nil: they mean "the platform's
    /// label colour", which the caller supplies.
    public static func named(_ name: String) -> RGB?
    /// hex → named → nil.
    public static func rgb(_ name: String) -> RGB?
}
```

Values for `named` (Apple dark-mode system colours, sRGB 8-bit):
`red 255,69,58` · `blue 10,132,255` · `green 48,209,88` ·
`yellow 255,214,10` · `orange 255,159,10` · `purple 191,90,242` ·
`indigo 94,92,230` · `cyan 100,210,255` · `teal 64,200,224` ·
`pink 255,55,95` · `mint 102,212,207` · `brown 172,142,104`.

Windows: `WinDark.themeColor(_ name: String) -> COLORREF` = `rgb(name)`
mapped to `COLORREF`, falling back to `WinDark.dim` for
`secondary`/`gray` and `WinDark.text` for `primary`/unknown.

Tests (`Tests/InfinitusCoreTests/ThemePaletteTests.swift`):
- `testHexParses` — `"#ff2d95"` → (255,45,149); `"#FF2D95"` too.
- `testHexRejectsMalformed` — `"#fff"`, `"ff2d95"`, `"#gggggg"`, `""`.
- `testEveryBuiltinThemeColourResolves` — iterate `RowTheme.builtins`,
  every `sessionColor`/`weeklyColor`/`scopedColor`/`creditColor`/
  `flashColor` (non-empty) returns non-nil from `rgb` **or** is one of
  `secondary`/`gray`/`primary`. This is the test that catches a new theme
  shipping with a typo'd colour.
- `testMacResolveUnchanged` — in `InfinitusUI`'s own tests if any exist;
  otherwise assert `ThemeColor.resolve("#ff2d95")` equals the literal
  `Color(red:green:blue:)` it used to produce.

## Layout — the gallery

A grid of preview cards, owner-drawn. **Not** a `SysListView32` in icon
mode: the theme card renders coloured gauge bars and emoji labels, which
`LVN_` owner-draw makes harder than a plain custom control.

```
Built-in
 ┌──────────────────────┐ ┌──────────────────────┐
 │ MP ▓▓▓▓▓░░░ 4h 8m    │ │ 🎥 ▓▓▓▓▓░░░ 4h 8m   │
 │ HP ▓▓░░░░░░ 🧪5d 9h  │ │ 🎞 ▓▓░░░░░░ re-…    │
 │ $  ▓▓░░ ⚔Dragon 💰1k │ │ 🎟 ▓▓░░ ★Epic 💵1k  │
 │ ◉ RPG — HP/MP gauges │ │ ○ Movie — reels &…  │
 └──────────────────────┘ └──────────────────────┘
 …

Your themes
   (none yet — themes.json skins appear here)
   [ Open themes file… ]   [ Reload ]
   Add your own skins — JSON, reloaded when this pane opens.

Community
   Browse and contribute themes on GitHub.   [ Open gallery… ]
```

Card geometry at 96 dpi: `px(300)` wide, `px(120)` tall, `px(10)` gap,
columns = `max(1, (contentWidth - pad*2 + gap) / (cardW + gap))`.
Reflow on resize; `contentHeight` = rows × (cardH + gap) + section
chrome.

Card contents — the same fabricated numbers for every card so they
compare like-for-like, exactly as the Mac does
(`ThemesPane.swift:113-114`): **session 21% used, weekly 68% used,
credit 74%, model "Fable" at 74%, $1,131**. Reuse those literals.

Two render modes, matching `RowTheme.plain`:
- `plain == true` (the Off theme): three text lines, no bars —
  `"5h 21% 4h 8m (22:09)"`, `"7d 68% 5d 9h (Sep 4 03:59)"`,
  `"$ 74% · Fable 74%"`.
- otherwise: three rows of `[label][bar][caption]` where the bar fills
  **remaining** (79%, 32%, 26% — HP semantics, `GaugeMath.remaining`), the
  label uses the theme's `sessionLabel`/`weeklyLabel`/`creditLabel` and
  the bar/label colour comes from `WinDark.themeColor(theme.sessionColor)`
  etc. Then `theme.scopedPrefix + theme.modelName("Fable")` and
  `"\(theme.cashIcon)1,131"`.

The bar drawing is `FleetWindow.paintGauge`'s track+fill, minus the pace
marker (a preview has no pace). Factor the two-rect fill into a small
shared helper rather than copy-pasting it.

**Emoji.** Theme labels are emoji-heavy (`🎥`, `🗡`, `🦇`, `💰`). GDI's
`DrawTextW` with Segoe UI renders these as monochrome glyphs at best and
tofu at worst. Options, in order of preference:
1. Select **Segoe UI Emoji** as the font for the label/icon runs
   specifically (create a second HFONT with face `"Segoe UI Emoji"`,
   select it for those `DrawTextW` calls only). This gives colour emoji
   through GDI on Windows 10+ for most codepoints.
2. If a specific glyph still fails, it fails **visibly as tofu, not as a
   crash** — acceptable for a preview, and the theme name underneath
   always identifies the card.
Do **not** pull in DirectWrite/Direct2D for this. Report which of the 15
built-ins render their icons correctly; a table of "renders / tofu" is a
useful artefact for the follow-up.

Selection:
- selected card → 2px border in `WinDark.sessionColor` + a filled radio
  glyph; unselected → 1px `WinDark.track` + hollow glyph.
- hover → `WinDark.hover` plate behind the card.
- click anywhere in a card selects that theme: write
  `settings.gamificationStyle` and repaint. The change must reach
  `FleetWindow` — post it a refresh so an open accounts panel re-renders
  with the new theme (`FleetWindow.refresh()` if `isOpen`).

**Where the theme is actually consumed on Windows today:** nowhere yet.
`FleetPanel`/`FleetLayout` take no theme and `FleetWindow` hardcodes
`"5h"`/`"7d"` labels and its own colours (`FleetWindow.color(for:)`).
This task therefore has a second half:

- Thread `RowTheme` into the Windows accounts panel: `FleetWindow` reads
  `settings.gamificationStyle` → `RowTheme.builtins + loadCustom()` →
  match by id (fall back to `.off`), and uses
  `theme.sessionLabel`/`weeklyLabel`, `theme.modelName(...)`,
  `theme.revivePrefix`, `theme.deadMarker` and the themed colours in
  place of the hardcoded ones.
- If that proves larger than it looks, **it is acceptable to land the
  gallery first and the consumption second**, but then the pane must say
  so honestly ("Themes apply to the accounts panel — coming in the next
  build") rather than silently doing nothing. Report which you did.

Custom themes:
- Path: `RowTheme.customThemesURL(appSupport:)` takes the App Support dir
  as a parameter, so Windows passes `%APPDATA%\Infinitus` and gets
  `%APPDATA%\Infinitus\themes.json`. Add a small Windows helper rather
  than hardcoding the join in two places.
  ```swift
  var windowsThemesURL: URL   // %APPDATA%\Infinitus\themes.json
  ```
  Note `RowTheme.loadCustom` also does a legacy `CswapBar/themes.json`
  copy-migration — harmless and irrelevant on Windows; leave it.
- "Open themes file…" writes `RowTheme.templateJSON` when the file is
  absent (the Mac's behaviour, `ThemesPane.swift:66-75`), then
  `ShellExecuteW(nil, "open", path, …)`.
- "Reload" calls `RowTheme.loadCustom` and repaints. Also reload in
  `activate()`, as the Mac does `.onAppear`.
- A broken themes.json yields `[]`, never a crash
  (`RowTheme.loadCustom` already guarantees this). Show
  "themes.json didn't parse — no custom themes loaded" when the file
  exists but decodes empty.

## Tests

Pure only, in `InfinitusWinUI` / Core:
- `ThemePaletteTests` (above).
- `testCardGridColumns` — width 980 → N columns; width 320 → 1; never 0.
- `testCardGridContentHeight` — 15 built-ins at 2 columns → 8 rows.
- `testThemeSelectionFallsBackToOff` — a `gamificationStyle` naming a
  theme that no longer exists resolves to `RowTheme.off`, not a crash.
- `testDisplayPrefsRoundTripThroughTitleFormatter` — build `TitlePrefs`
  from a `WinSettings`, format a fixture account, assert the string. This
  pins the Display pane's preview against `TitleFormatter`'s own tests.

## Acceptance

1. Display pane: every control reads its stored value on open, writes on
   change, survives a tray restart.
2. Icon-only greys the five title controls.
3. The title preview updates live and matches what the tray tooltip shows
   after the change.
4. Autostart round-trips against `HKCU\…\Run` and reports failure rather
   than lying.
5. Balloon toggle actually suppresses balloons.
6. Keep-awake holds `ES_SYSTEM_REQUIRED` only while a session is busy
   (verify with `powercfg /requests` — it lists the executable under
   SYSTEM).
7. Refresh interval changes `TrayFleet`'s cache TTL and the value persists.
8. Themes pane shows **15** built-in cards plus any custom ones.
9. Selecting a card persists and (per the note above) either re-themes
   the accounts panel or says it will.
10. "Open themes file…" creates the template on first use and opens it.
11. A deliberately corrupt themes.json shows the message and does not
    crash the tray.
12. Both panes relayout on resize and on a DPI change.

## Report

Status; files; tests; commit. Plus:
- the emoji render table (15 themes × icons render/tofu);
- whether theme consumption in `FleetWindow` landed in this task or was
  deferred (and if deferred, the issue number);
- confirmation that the Mac's `ThemeColor.resolve` output is unchanged.
