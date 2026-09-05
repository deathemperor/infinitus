# Wave 01 — Windows Settings

Bring the Windows tray's Settings from one flat 706-line dialog to the
Mac's 13-pane shell.

Written 2026-09-05 against the repo at `04ce8e8` (branch
`windows-remote`). Every Mac reference in these documents was read from
the source file named; every Win32 constraint came from
`windows/Sources/InfinitusTrayWin/` or from `CLAUDE.md`'s hard-won facts.

## The documents

| file | covers |
|---|---|
| [`00-architecture.md`](00-architecture.md) | **read first.** Parity table, what is dropped and why, the shell design, the `SettingsPane` protocol, DPI, dark theme, Core-vs-local data, persistence, secrets, threading, testing, build |
| [`01-settings-shell-and-navigation.md`](01-settings-shell-and-navigation.md) | sidebar, search, pane host, scrolling, resize, keyboard, dark chrome, `WinSettings` store, `SettingsCatalog` |
| [`02-display-and-themes.md`](02-display-and-themes.md) | Display pane (title prefs, tray, system) + Themes pane (15 built-ins, custom, GDI preview cards) + `ThemePalette` in Core |
| [`03-accounts-and-engines.md`](03-accounts-and-engines.md) | Accounts roster across fleets + cswap / CLIProxyAPI / 9Router engine panes |
| [`04-push-and-devices.md`](04-push-and-devices.md) | Push channels & triggers + phone pairing, QR, routes, export/import |
| [`05-usage-utilization-stats-activity.md`](05-usage-utilization-stats-activity.md) | the four data panes, GDI charts, the usage-history recorder and the Windows event store |
| [`06-about-and-updates.md`](06-about-and-updates.md) | About, version truth, GitHub release check, components diagnostics |

## Dependency graph

```
                        ┌─────────────────────────┐
                        │ 01  shell + navigation  │   ← land alone, first
                        │     SettingsPane proto  │
                        └───────────┬─────────────┘
                                    │  protocol frozen
        ┌──────────┬────────────────┼────────────────┬──────────┐
        ▼          ▼                ▼                ▼          ▼
   ┌────────┐ ┌─────────┐   ┌──────────────┐  ┌───────────┐ ┌───────┐
   │ 02     │ │ 03      │   │ 04           │  │ 05        │ │ 06    │
   │display │ │accounts │   │push          │  │usage      │ │about  │
   │themes  │ │engines  │   │devices       │  │utilization│ │       │
   └───┬────┘ └────┬────┘   └──────┬───────┘  │stats      │ └───────┘
       │           │               │          │activity   │
       │           │               │          └─────┬─────┘
       │           │               │                │
       └───────────┴───────────────┴────────────────┘
                          soft couplings
```

`02`–`06` are parallel. The soft couplings are worth knowing but do not
serialise the work:

- `02` adds `ThemePalette` to Core; `05`'s charts use theme colours if
  present, and fall back to `WinDark`'s fixed palette if `02` has not
  landed. **Do not** have `05` block on `02`.
- `03` adds `EngineCatalog.capabilities(for:)` to Core; nothing else needs
  it.
- `04` and `05` both may touch `windows/Sources/InfinitusWin/` (the push
  tick; the event store's daemon-side writes). Coordinate: `04` owns
  `serve`'s push tick, `05` owns the event store's *shape*. If both need
  a daemon change in the same file, `05` lands first and `04` rebases.
- `02` and `03` each delete part of `01`'s temporary Legacy pane. Whoever
  lands second removes the file.
- `06` deletes nothing and touches no shared Core file — safest first
  parallel dispatch, and the best smoke test of `01`'s protocol.

## Non-negotiables for every dispatch

Restated here because a subagent reads its brief, not the whole tree.
These come from `CLAUDE.md` and are not open to interpretation.

1. **Engine isolation.** Every engine touchpoint is a `cswap … --json`
   subprocess or the engine's own documented HTTP API. Never read
   `~/.claude-swap-backup/*`, never 9Router's database, never
   CLIProxyAPI's config or credential files. Reading Claude Code's own
   files is fine: `~/.claude/settings.json`, `~/.claude/sessions/*.json`
   (+ `.key`), `~/.claude/projects/*/*.jsonl`.
2. **Account policy lives in the engines.** Forward the ask, report the
   answer — including a refusal, verbatim. Never a second policy layer
   app-side.
3. **Secrets over stdin, never argv.** Shown masked only. Nothing secret
   in `settings.json`, in a log, in a status line, or in `--probe`
   output.
4. **Idle CPU stays near zero.** No repaint timers for decoration. A
   visible pane may hold one timer; a hidden one holds none. Target
   < 0.5% with Settings open, measured over 15 s and reported.
5. **`Int32(bitPattern: msg)`, never `Int32(msg)`.** Windows sends
   messages above `Int32.max` and the checked initializer traps.
6. **`GetWindowLongPtrW` for `GWLP_USERDATA`, never a Set/Set dance.**
7. **`WM_CTLCOLOR*` returns a process-lifetime brush.** Never one created
   in the handler.
8. **`PostMessageW` for cross-thread results.** This process pumps
   `GetMessageW` and never drains `DispatchQueue.main`; a dispatched block
   silently never runs.
9. **Never `DateFormatter.timeZone = <named IANA zone>` on Windows** —
   it traps (swift-corelibs-foundation, Swift 6.3.3, verified
   2026-09-05). Use `Calendar.dateComponents` and format by hand.
10. **One commit per dispatch**, conventional subject, staged by explicit
    path, `Co-Authored-By: Claude Code <noreply@anthropic.com>` (the repo
    hook appends it — run `git config core.hooksPath tools/githooks` once
    per clone). **Never push.**
11. **`swift build --product X` — one `--product` per invocation.** With
    two flags SwiftPM builds only the last.
12. **Todos and research notes go to GitHub issues, not files.**

## Verification, every dispatch

```powershell
. .\windows\env.ps1
swift build --product infinitus-tray-win
swift test
.\.build\debug\infinitus-tray-win.exe --settings <paneID>
```

Plus, before handing off: `powershell -ExecutionPolicy Bypass -File .\windows\ci.ps1`.

The `--settings <paneID>` flag comes from `01`; it opens the shell
directly on one pane so each can be exercised and screenshotted without
clicking through.

---

# Dispatch briefs

Copy one of these verbatim as a subagent's task. Each is self-contained
apart from the two documents it names.

## Brief — `01` shell (dispatch first, alone)

> Implement the Windows Settings shell and navigation.
>
> Read, in order:
> - `docs/wave-01-settings/00-architecture.md`
> - `docs/wave-01-settings/01-settings-shell-and-navigation.md`
>
> Build the CodexBar-style Settings shell for the Windows tray: a
> searchable owner-drawn sidebar, a `WS_CHILD` pane container per pane
> with vertical scrolling, dark chrome via `WinDark`, DPI-correct
> geometry via a shared `Metrics`, resize, and keyboard navigation. Add
> `SettingsCatalog` to `InfinitusCore` and `WinSettings` /
> `WinSettingsStore` to a new `InfinitusWinUI` library target so the pure
> parts are testable (an executable target cannot be imported by tests).
>
> Move today's four working controls into a temporary "Legacy" pane so
> nothing regresses mid-wave; fix the two real bugs noted in the spec
> while moving them (the off-UI-thread control write, the escaping
> `CB_ADDSTRING` buffer pointer).
>
> `02`–`06` compile against the `SettingsPane` protocol you finalise, so
> your report must quote it verbatim and flag any signature you changed
> from the spec, in bold, at the top.
>
> Acceptance: the 12 numbered checks at the end of `01`. Report the
> DPI-awareness route taken, whether comctl32 v6 activated, and the
> measured idle CPU with Settings open.
>
> One commit, conventional subject, staged by explicit path. Never push.

## Brief — `02` Display + Themes

> Implement the Windows Settings Display and Themes panes.
>
> Read: `docs/wave-01-settings/00-architecture.md`,
> `docs/wave-01-settings/02-display-and-themes.md`, and the `01` dispatch
> report for the final `SettingsPane` protocol.
>
> Display: title/tooltip preferences through `TitlePrefs` +
> `TitleFormatter` with a live preview, autostart, refresh interval,
> balloon toggle, keep-awake. Every control writes immediately; no Save
> button.
>
> Themes: a GDI card gallery over `RowTheme.builtins` (there are **15**,
> not 14 — `agent` is easy to miss) plus custom themes from
> `%APPDATA%\Infinitus\themes.json`. Move the colour table from
> `InfinitusUI.ThemeColor` into a new Core `ThemePalette` so both
> platforms resolve a theme's colours identically — the Mac's rendering
> must be unchanged. Then thread the selected `RowTheme` into
> `FleetWindow` so the accounts panel actually uses it; if that is too
> large for this dispatch, land the gallery and say on screen that themes
> apply next build, and file an issue.
>
> Delete the theme combo from `01`'s Legacy pane.
>
> Acceptance: the 12 checks at the end of `02`. Report the emoji render
> table for the 15 built-ins and whether theme consumption landed.
>
> One commit. Never push.

## Brief — `03` Accounts + engines

> Implement the Windows Settings Accounts pane and the three engine panes
> (cswap, CLIProxyAPI, 9Router).
>
> Read: `docs/wave-01-settings/00-architecture.md`,
> `docs/wave-01-settings/03-accounts-and-engines.md`, and the `01`
> dispatch report for the final `SettingsPane` protocol.
>
> This is the largest task in the wave and the one where engine isolation
> is easiest to break. Every action forwards an ask to the engine and
> reports its answer verbatim, including refusals. Every control is gated
> on `EngineCapabilities`, never on engine identity. The cswap pane
> renders **every** key `cswap config list --json` returns, driven by the
> `SettingEntry` metadata — no hand-wired keys, and a loading guard so
> opening the pane never auto-commits a config write.
>
> No OAuth flow: Windows Swift has no WebKit and no `openpty`. Show the
> exact `claude auth login` / `cswap add` commands with a Copy button
> instead of a dead button.
>
> Apply a user-only DACL to `9router.json` (it holds a password in
> plaintext today) and store the new CLIProxy key DPAPI-encrypted.
>
> If wiring CLIProxyAPI into `TrayFleet` is more than this dispatch can
> hold, land the pane and return `DONE_WITH_CONCERNS` with an issue — but
> never half-wire a fleet whose switch silently does nothing.
>
> Delete `01`'s Legacy pane (or the rest of it, if `02` went first).
>
> Acceptance: the 13 checks at the end of `03`. Report the `icacls`
> output for both credential files.
>
> One commit. Never push.

## Brief — `04` Push + Devices

> Implement the Windows Settings Push and Devices panes.
>
> Read: `docs/wave-01-settings/00-architecture.md`,
> `docs/wave-01-settings/04-push-and-devices.md`, and the `01` dispatch
> report for the final `SettingsPane` protocol.
>
> Push: Slack and Telegram through `cswap notify`, with every secret on
> **stdin** and read back only masked from `cswap notify --json`. Five
> trigger toggles backed by `PushTriggers.Flags`. The triggers need a
> long-lived process to tick them — add that to `infinitus-win serve`,
> modelled on the Linux tray's `tickPushes`; if that is its own dispatch,
> land the pane and say on screen that the toggles apply to the daemon,
> and file an issue. Never ship silently dead toggles.
>
> Devices: the live 4-step pairing checklist, the serve toggle over the
> tray's existing `startDaemon`/`daemonAlreadyServing`, pairing token
> reveal/copy/rotate, the route list, and a **scannable QR**. The QR needs
> an encoder: implement a byte-mode level-M encoder in Core with a
> checked-in fixture verified against a trusted encoder, or fall back to
> `qrencode`-if-present plus a typed-route path. A QR that encodes the
> wrong bytes is a silent failure — do not ship one unverified.
> Also port the settings-file export/import over `SyncSnapshot`.
>
> Acceptance: the 14 checks at the end of `04` — including scanning the
> QR with a real phone. Report the QR route taken and confirm, in words,
> that no secret reaches argv, a log, a status line or `--probe`.
>
> One commit. Never push.

## Brief — `05` Usage + Utilization + Stats + Activity

> Implement the four Windows Settings data panes.
>
> Read: `docs/wave-01-settings/00-architecture.md`,
> `docs/wave-01-settings/05-usage-utilization-stats-activity.md`, and the
> `01` dispatch report for the final `SettingsPane` protocol.
>
> Swift Charts does not exist here, so write the five GDI chart
> primitives once and share them. Every number comes from existing
> portable Core — `UsageReport`, `Stats.Presentation`, `UsageForecast`,
> `WindowTelemetry`, `WasteMath`, `TokenRates` — compute nothing new.
>
> Two panes have **no data source on Windows yet**, so this task must add
> both: a usage-history recorder writing
> `%APPDATA%\Infinitus\usage-history.<machineID>.jsonl` from the tray
> tick (deduped on the engine's poll instant, not the wall clock), and a
> `WinEventStore` over `%APPDATA%\Infinitus\events.jsonl` with the tray
> emitting `switch`/`death`/`limit`/`revival` events using the exact
> `kind` strings `StatsEvents.days` switches on. Without these, both
> Utilization and Activity — and the Stats "Limits" tiles — are
> permanently empty.
>
> Port `StatsModel`'s chunked scan loop, not a single blocking scan: a
> cold backfill is minutes. Keep the 64 MB budget, the stuck check, the
> pass cap, and the rule that the transcript and repo scans never
> overwrite each other's days.
>
> Nothing blocks the UI thread. Watch for GDI handle leaks — delete every
> pen and brush you create.
>
> Acceptance: the 8 checks at the end of `05`. Report the GDI handle
> count before/after 50 open/close cycles, the measured idle CPU, and
> whether the recorder and event store both landed.
>
> One commit. Never push.

## Brief — `06` About

> Implement the Windows Settings About pane.
>
> Read: `docs/wave-01-settings/00-architecture.md`,
> `docs/wave-01-settings/06-about-and-updates.md`, and the `01` dispatch
> report for the final `SettingsPane` protocol.
>
> Hero card with the tray icon at 64×64, the real version and the
> binary's build time; a GitHub release check with `PackageVersion`
> comparison (no Homebrew, no nightly channel on Windows); a Components
> section reporting tray / daemon / cswap / claude / Swift-runtime state
> — including a plain "debug build, runtime DLLs not staged" warning,
> which is the most common silent failure on this platform; a
> notifications note pointing at Focus Assist; links; MIT footer.
>
> Fix the version truth while you are here: `VERSION` says 0.4.2, the
> daemon's constant says 0.4.1, and the tray has none. Put one constant
> in `InfinitusCore`, have both Windows binaries read it, and extend
> `VersionTests` so they cannot drift again.
>
> This is the smallest pane and touches no shared Core file besides the
> version constant — a good first parallel dispatch after `01`.
>
> Acceptance: the 8 checks at the end of `06`. Report the three version
> strings before and after.
>
> One commit. Never push.

---

## After the wave

Follow-ups these specs deliberately deferred. File them as GitHub issues
(never as files — CLAUDE.md), one line each:

- Community theme gallery on Windows (fetch + install from the GitHub
  index).
- Drag-to-reorder accounts (wave 01 ships ▲/▼ buttons).
- Move `9router.json` and `cliproxy.json` to a versioned DPAPI format.
- Cloudflare tunnel support on Windows (`NamedTunnel` is macOS-only).
- WIC thumbnails for the image route (already tracked in
  `windows/README.md`).
- Haiku session auto-naming on Windows.
- Release rule: bump `VERSION` and the shared version constant together
  (add to `docs/RELEASING.md` if `06` did not).

And the release rule that applies to the wave as a whole: **every release
updates `site/` and the GitHub README with the new features** in the
release commit, not after. When wave 01 lands, the Windows section of
`README.md` and `windows/README.md`'s feature list both need the new
Settings window described — one line per feature.
