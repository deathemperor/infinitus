# 06 — About pane and updates

**Depends on `01`.** Compile against `01`'s final `SettingsPane`
protocol. Read `00-architecture.md` first.

The smallest task in the wave. It is separate because it touches release
plumbing (`VERSION`, the tray's version constant, the GitHub release API)
that the other panes do not, and because it is a good first dispatch for
verifying the shell against something simple.

Mac source: `Sources/Infinitus/AboutPane.swift:350-547`.
Descriptor: `id: "about"`, glyph `` (Info), tint
`WinDark.rgb(100, 95, 220)` (the Mac's `.indigo`).

---

## What ports

| Mac | Windows |
|---|---|
| Hero card: app icon, version, build, build date, tagline | port |
| Updates: current vs latest, check button | port (GitHub release only) |
| Update channel stable/nightly picker | port — **as a read-only note**, see below |
| "Update via Homebrew" | **drop** — no brew |
| Channel switch buttons (`brew uninstall`/`install`) | **drop** |
| Notifications delivery + the usernoted explanation | replace with a Windows equivalent, see below |
| Links: GitHub, Website, Project | port |
| MIT licence footer | port |

## Layout

```
                        ┌────────┐
                        │  ∞     │         (the tray icon at 64×64)
                        └────────┘
                         Infinitus
                    Version 0.4.2 (tray)
                  Built Sep 5, 2026 at 14:02
     Every Claude account in one tray — swap before you stall.

Updates
  Infinitus 0.4.2 · installed from %LOCALAPPDATA%\Infinitus\bin
     0.5.0 is available on GitHub
  [x] Check for updates daily
  [ Check now ]   [ Open the release page ]
  Windows installs update by re-running windows\install.ps1 from a fresh
  checkout — the tray never replaces itself.
  [ Copy the update commands ]

Components
  infinitus-tray-win   0.4.2      this window
  infinitus-win        0.4.2      running on 47824      (or "not running")
  cswap                0.26.0     C:\Users\…\.local\bin\cswap.exe
  claude                2.1.260   C:\Users\…\AppData\…\claude.exe   (if found)
  Swift runtime        staged     %LOCALAPPDATA%\Infinitus\bin      (or "from PATH")

Notifications
  Delivery: tray balloons (Shell_NotifyIconW)
  Windows Focus Assist suppresses balloons while it is on; check
  Settings → System → Notifications if nothing appears.
  [ Open Windows notification settings ]

Links
  ⟨/⟩  GitHub                                                    ↗
  🌐   Website                                                   ↗
  📦   Project — Infinitus                                       ↗
  📄   Windows guide (windows/README.md)                         ↗

Infinitus by deathemperor · MIT License
```

## Version, honestly

There are **three** version strings in this repo and they disagree today:

- `VERSION` → `0.4.2` (the release track).
- `windows/Sources/InfinitusWin/main.swift:11` →
  `let infinitusWinVersion = "0.4.1"` (the daemon, stale).
- `windows/README.md:118` documents `infinitus-win 0.4.1`.

The tray has no version constant at all.

Fix as part of this task:
1. Add `let infinitusTrayWinVersion = "…"` next to the daemon's, or
   better, put **one** constant in `InfinitusCore` —
   `public enum InfinitusVersion { public static let current = "0.4.2" }`
   — and have both Windows executables and any future consumer read it.
   The Mac reads `CFBundleShortVersionString` from its Info.plist and
   keeps doing so; do not change that.
2. Bring `infinitusWinVersion` in line with `VERSION`.
3. Add a test in `windows/Tests/InfinitusWinTests/VersionTests.swift`
   (the file exists) asserting the daemon's `--version` output matches
   `InfinitusVersion.current`, so they cannot drift again.
4. Note in the report that `VERSION` and the constant must be bumped
   together, and add that to `docs/RELEASING.md` if it is not there.

Build date: the executable's modification time, exactly as the Mac reads
it (`AboutPane.swift:363-371` — "Stamped nowhere in Info.plist, so read
the truth"). On Windows:
`FileManager.default.attributesOfItem(atPath: CommandLine.arguments[0])[.modificationDate]`,
or `GetModuleFileNameW` + `GetFileTime`. Format with a plain
`DateFormatter` and **no `timeZone` assignment** — see the trap note in
`05`.

Install location: `Bundle.main.bundlePath` is meaningless here. Use
`GetModuleFileNameW(nil, …)` and show the directory. If it is under
`.build\debug`, say so plainly: **"debug build — runs only with the Swift
runtime DLLs staged or `env.ps1` sourced"**. That single line will save
somebody the silent `0xC0000135` failure documented in
`windows/README.md:59-67`.

## The icon

`TrayIcon.make(busy:)` draws the two-ring glyph as a 16×16 HICON
(`TrayIcon.swift`). It hardcodes `side: Int32 = 16`. Generalise it to
`make(busy:side:)` so About can request 64 (and DPI-scale it), then
`DrawIconEx` it into the hero area. Keep the default at 16 so the tray's
call site is unchanged.

If generalising turns out to touch the mask stride maths awkwardly, an
acceptable fallback is to draw the two rings directly in the pane's
`WM_PAINT` with the same geometry (`gap = side*0.18`, `radius = side*0.20`,
`stroke = max(1, side*0.07)`) — but prefer one implementation.

## Update check

`AppReleaseModel` (`AboutPane.swift:147-244`) minus the brew half:

```
GET https://api.github.com/repos/deathemperor/infinitus/releases/latest
    Accept: application/vnd.github+json
→ { "tag_name": "v0.5.0", "name": … }
```

- Strip a leading `v`, compare with `PackageVersion`
  (`Sources/InfinitusCore/UpdateCheck.swift` — portable, already tested,
  handles `0.26.0b1` correctly).
- `404` → "no releases published yet — this build came from source".
- Any error → "release check failed: <message>". Never claim up-to-date
  on a failed check.
- Auto-check: at most once per 24 h, on tray start and every 6 h
  thereafter, gated on `settings.updateAutoCheck`. Persist
  `app_update_last_check` (the Mac's key name).
- When an update is found and it is a **new** version since the last
  notification, raise one balloon: `"Infinitus 0.5.0 is available"`, and
  persist `app_update_notified_version` so it fires once per version.
- The nightly channel: the Mac checks a rolling `nightly` tag. Windows has
  no nightly artefact. Show the stable check only, and one line: "Nightly
  builds are macOS-only for now." Do **not** ship a channel picker that
  does nothing.
- All of it through `ctx.async` — a network call on the UI thread hangs
  the window for the socket timeout.

"Copy the update commands":

```
cd <repo>
git pull
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

(and `-Autostart` if `TrayAutostart.isEnabled()`). Straight from
`windows/README.md`.

## Components section

Small, and genuinely the first thing anyone asks when something is
broken. Each line is cheap:

- tray version → the constant.
- daemon → `infinitus-win.exe --version` beside this binary, plus
  `daemonAlreadyServing()` for the running state (reuse it — it reads the
  TCP table and needs no Winsock init; `main.swift:182-207`).
- cswap → `CswapLocator.locate()` for the path and `cswap --version`
  through `CswapCLI.version()` for the number. "not found" is a valid,
  useful answer.
- claude → look for `claude.exe` on PATH; show version if a
  `--version` call is cheap, else just the path. Skip if absent.
- Swift runtime → whether `swiftCore.dll` sits beside the executable
  (staged) or is being found on PATH. This is the single most common
  Windows failure mode in this project.

Every one of these shells out — do them **once** on `activate()`, in one
`ctx.async` batch, and cache for the pane's lifetime. Do not re-run on
every paint.

## Notifications section

The Mac's section explains the usernoted/provisioning-profile fallback.
The Windows equivalent is Focus Assist and the notification settings page:

- Delivery: "tray balloons (`Shell_NotifyIconW`)".
- If `settings.trayBalloonsEnabled` is off, say "turned off in Display",
  with a button that jumps to the Display pane
  (`SettingsShell.select(paneID: "display")` — a nice small proof that
  cross-pane navigation works).
- Button "Open Windows notification settings" →
  `ShellExecuteW(nil, "open", "ms-settings:notifications", nil, nil, SW_SHOWNORMAL)`.

## Links

`ShellExecuteW(nil, "open", url, nil, nil, SW_SHOWNORMAL)` — the pattern
already in `SettingsWindow.openNineRouterDashboard`
(`SettingsWindow.swift:698-704`). Full-row buttons with a leading glyph
and a trailing `↗`, owner-drawn like every other button.

URLs, verbatim from the Mac:
- `https://github.com/deathemperor`
- `https://huuloc.com`
- `https://github.com/deathemperor/infinitus`
- plus `https://github.com/deathemperor/infinitus/blob/main/windows/README.md`

## Tests

Core:
- `InfinitusVersion.current` parses as a `PackageVersion`.
- (`PackageVersion` itself is already tested — don't duplicate.)

`InfinitusWinUI`:
- `testReleaseTagStripsV` — `"v0.5.0"` → `"0.5.0"`; `"0.5.0"` unchanged.
- `testUpdateAvailableComparison` — `0.4.2` vs `0.5.0` → available;
  `0.5.0` vs `0.4.2` → not; `0.5.0` vs `0.5.0` → not;
  `0.5.0b1` vs `0.5.0` → available.
- `testAutoCheckDueAfter24h` — a pure
  `shouldCheck(lastCheck:now:enabled:) -> Bool`.
- `testNotifyOncePerVersion` — a pure
  `shouldNotify(latest:lastNotified:) -> Bool`.
- `testUpdateCommandsIncludeAutostartFlagWhenEnabled`.
- `testInstallLocationClassification` — a path under `\.build\debug\` →
  `.debugBuild`; under `LOCALAPPDATA\Infinitus\bin` → `.installed`;
  anything else → `.other`. (Pure string classification; the pane renders
  the right sentence from the enum.)

`windows/Tests/InfinitusWinTests/VersionTests.swift` — extend with the
daemon/constant agreement assertion.

## Acceptance

1. Pane shows the icon at 64×64, the correct version, and a build date
   that matches the binary's mtime.
2. A debug build says so; a `%LOCALAPPDATA%\Infinitus\bin` build says
   "installed".
3. "Check now" reaches GitHub, reports available/up-to-date/failed
   correctly, and never freezes the window.
4. With `app_update_last_check` cleared, tray start performs one check and
   at most one balloon per new version.
5. Components section correctly reports a missing cswap, a stopped
   daemon, and a debug build with unstaged DLLs.
6. Every link opens in the default browser.
7. "Open Windows notification settings" opens the Settings app on the
   notifications page.
8. The daemon's `--version`, `InfinitusVersion.current` and `VERSION`
   all agree, and `VersionTests` fails if they stop agreeing.

## Report

Status; files; tests; commit. Plus:
- the three version strings before and after;
- whether `TrayIcon.make` was generalised or the rings redrawn;
- confirmation that `docs/RELEASING.md` mentions bumping the shared
  constant alongside `VERSION` (add it if it does not).
