# 05 — Usage, Utilization, Stats and Activity panes

**Depends on `01`.** Compile against `01`'s final `SettingsPane`
protocol. Read `00-architecture.md` first.

Four read-only data panes. They share one hard problem — **the Mac draws
them with Swift Charts, which does not exist here** — and one hard rule —
**none of these scans may run on the UI thread**. One agent, so the GDI
chart primitives get written once.

---

## Shared: the chart primitives

Create `windows/Sources/InfinitusTrayWin/Charts.swift`. Four functions,
all taking a `HDC`, a `RECT` and plain arrays. No state, no controls.

```swift
enum GDIChart {
    /// Vertical bars, one per value, left to right. Used by: daily spend,
    /// session-length buckets, the 5h start-hour rhythm.
    static func bars(_ dc: HDC, _ rect: RECT, values: [Double],
                     color: COLORREF, labels: [String]? = nil,
                     metrics: Metrics, font: HFONT?)

    /// Horizontal bars with a leading label column. Used by: spend by
    /// model, activity/model effort tables.
    static func hbars(_ dc: HDC, _ rect: RECT, rows: [(label: String, value: Double)],
                      color: COLORREF, metrics: Metrics, font: HFONT?)

    /// One or more polylines over a shared x axis, y clamped 0…yMax.
    /// Used by: utilization over time.
    static func lines(_ dc: HDC, _ rect: RECT,
                      series: [(name: String, color: COLORREF, points: [(x: Double, y: Double)])],
                      yMax: Double, metrics: Metrics, font: HFONT?)

    /// A 7×24 intensity grid. Used by: the Stats hour heatmap.
    static func heatmap(_ dc: HDC, _ rect: RECT, values: [Int],
                        base: COLORREF, metrics: Metrics, font: HFONT?)

    /// A flat sparkline for a stat tile — no axes, no labels.
    static func spark(_ dc: HDC, _ rect: RECT, values: [Double], color: COLORREF)
}
```

Rules:
- **No animation, no timers.** CLAUDE.md's idle-CPU rule; the accounts
  panel idles at 0.13% precisely because it paints on demand.
- Every chart is painted inside the pane's existing `WM_PAINT`, into the
  same double-buffered memory DC. `WM_ERASEBKGND` returns 1.
- Axis labels and legends in `captionFont` / `WinDark.faint`.
- `CreatePen`/`CreateSolidBrush` are created and **deleted** per call.
  A leaked GDI object in a repainting window exhausts the 10 000-handle
  process quota and the window silently stops drawing.
- Degenerate input must not divide by zero: empty `values`, all-zero
  values, one point, `yMax == 0`. Return early and draw the empty label.

Empty state is a first-class case in every one of these panes. The Mac
says "No history yet — samples accrue while Infinitus runs". Say the
equivalent, and say *how* to get data.

## Shared: scanning off the UI thread

Every scan below goes through `ctx.async` with a generation guard
(`01`). Concretely:

| scan | cost | source |
|---|---|---|
| `cswap usage --days N --json` | seconds, streams GBs of transcripts | `CswapCLI.swift:292-294` |
| `StatsScanner.scan` | **minutes** cold; chunked at 64 MB | `StatsModel.swift:104-147` |
| `TokenRateScanner.scan` | seconds | `TokenRates.swift:80` |
| `UsageHistory.load` + merge | file IO, ~ms–s | `UsageHistory.swift:127` |
| repo git/gh scan | minutes on a long history | `RepoStatsScanner` |
| `cswap history --json` | fast | `CswapCLI.swift:282` |

Cache to disk so a pane never opens onto a spinner twice. Paths, all under
`%APPDATA%\Infinitus\` (`00-architecture.md`):
`usage-cache.json`, `token-rates-cache.json`, `stats\transcripts.json`,
`stats\repos\*.json`. The Core scanners already take a `cacheURL`
parameter — pass the Windows path, do not hardcode inside Core.

`StatsScanner.defaultCacheURL()` and `TokenRateScanner.defaultProjectsDir()`
use `FileManager.urls(for: .applicationSupportDirectory)`, which on
Windows resolves somewhere under the profile but **not**
`%APPDATA%\Infinitus`. `TokenRateScanner.defaultProjectsDir()` is fine —
it is `ClaudeSessions.configHome()/projects`, which is already correct on
Windows. For the caches, pass an explicit Windows URL from the pane rather
than changing Core's default (the Mac depends on it).

---

# Pane A — Usage

Mac source: `Sources/Infinitus/UsagePane.swift` (222 lines).
Descriptor: `id: "usage"`, glyph `` (Money / BarChart), tint
`WinDark.rgb(50, 190, 90)` (the Mac's `.green`).

Source: `cswap usage --days N --json` → `UsageReport`
(`Sources/InfinitusCore/Models.swift:287-345`). Fully portable.

```
Window: [7 days v]                            [ Refresh ]   scanning…

Daily estimated spend
  ▁▃▅▂▇▄▂        stacked bars, one colour per account, legend below

By model
  claude-opus-5      ████████████████  $42.10
  claude-sonnet-5    ██████            $16.40
  claude-haiku-5     █                 $ 1.02

Estimated spend, last 7 days
  1  alpha                                            $31.20
     412 msgs · out 1.2M · cache 8.4M · claude-opus-5
  2  bravo                                            $18.90
     …
     before switch log                                $ 9.42
  Total                                               $59.52

  <report.caveats joined — ALWAYS rendered>
```

Notes:
- The caveats **are the feature**. They carry the price-table date and
  the not-a-bill warning. Render them unconditionally, in `captionFont`,
  wrapped (`UsagePane.swift:133-137`).
- Window picker: 7 / 14 / 30 days; changing it re-scans.
- `report.unattributed` renders as a row named "before switch log".
- Number formatting: `TokenFormat.compact` — check whether it lives in
  `InfinitusUI` (macOS) or Core. If it is in `InfinitusUI`, **move it to
  Core**; it is pure integer→"1.2M" formatting and the Windows pane needs
  it. Same for `usd` formatting: `String(format: "$%.2f", v)`.
- Cache the last report to `usage-cache.json` and render it immediately on
  open while a fresh scan runs behind — exactly the Mac's `cacheOnly`
  behaviour (`UsagePane.swift:29-41`). A pane that opens blank for eight
  seconds reads as broken.
- No engine → "cswap not found — spend estimates come from
  `cswap usage`."

---

# Pane B — Utilization

Mac source: `Sources/Infinitus/UtilizationPane.swift` (619 lines).
Descriptor: `id: "utilization"`, glyph `` (StackedLineChart), tint
`WinDark.rgb(80, 210, 180)` (the Mac's `.mint`).

The Mac pane has eight sections. Port five; two of the dropped ones
depend on a live `AppModel` relay that has no Windows equivalent.

| section | Windows |
|---|---|
| Range picker (24h / 7d / 30d) | port |
| Forecast — every account at its own pace | port (computed here, see below) |
| Fleet — all accounts out / drain order | port |
| Battle plan — **live** | **drop** — the Mac's `LiveForecastRelay` is fed by `AppModel`'s snapshot loop |
| Run rate (tokens & $ per min/hour/day/week) | port |
| Utilization over time chart | port |
| 5h windows + rhythm | port |
| Battle plan — dry run | port (it is `WindowPlanner.replay` over history, no live state) |
| Waste at weekly resets | port |

### History has to exist first

`UsageHistory` samples are written by the Mac's `UsageHistoryRecorder`
from its snapshot loop. **Nothing writes them on Windows.** Without this,
every section here is permanently empty and the pane is pointless.

So this task must also add the recorder. Smallest correct place: the
tray's existing 5 s tick, where `TrayFleet` already holds a fresh
`AccountList`.

```swift
/// Appends UsageHistory samples for the accounts the tray just read.
/// One file per machine (usage-history.<machineID>.jsonl) so a future
/// sync never conflicts; readers merge. Best-effort — a full disk must
/// never break the tray.
enum WinUsageHistoryRecorder {
    static var url: URL   // %APPDATA%\Infinitus\usage-history.<machineID>.jsonl
    static func record(accounts: [Account])
}
```

Lift the logic from `Sources/Infinitus/UsageHistoryRecorder.swift`:
- dedupe on the engine's **poll instant** (`usageFetchedAt`), not the wall
  clock — `UsageHistory.samples` already keys on it, and recording the
  sampling time would write a line per tick instead of per poll;
- prune once per launch at 90 days (`UsageHistory.prune`);
- seed `WeeklyResetMemory` once per launch;
- `machineID` from `settings.json` (add a `machine_id` field, generated
  once), not `UserDefaults`.

Run it on a worker, not the tick's thread, or at minimum keep it to an
append — it is one `FileHandle.write` of a few hundred bytes and the
dedupe means most ticks write nothing.

### Sections

```
Range: [7 days v]                              [ Refresh ]

Forecast — every account at its own pace
  alpha   active                    5h binds first, 18:40
     5h    62%   +11%/h   out 18:40        resets 20:05
     7d    41%   +2%/h    resets before it fills   resets Sep 11 03:59
  bravo
     5h     0%   pace unknown                      resets —
  Estimate. 5h pace measured over the last hour, weekly and per-model
  paces over the last 24 hours.

Fleet
  All accounts out        no weekly pace measured yet
  Drain order: alpha → bravo → charlie

Run rate
                 Tokens    API-equivalent $    Turns
  per minute      12.4k            $0.31         0.4
  per hour       744k             $18.60        26
  per day        3.1M             $77.20       210
  per week       9.8M            $244.10       702
  Read off Claude Code's own transcripts … an estimate, not a bill.

Utilization — 7d                    Account: [All accounts v]  Window: [7d v]
  <line chart, y 0…100, one series per account>
  One point per engine usage poll, thinned for the range. Gaps are hours
  this PC (or its engine) wasn't running.

5h windows
  alpha   14:05        62% peak
  alpha   09:00         4% peak   unused
  …
  12 windows · mean peak 48% · 3 unused
  <bar chart: windows started per hour of day>

Battle plan — dry run
  6 switches · 2 onto a cold clock · stalled 41m
  18:40  switch to #2   alpha's 5h binds in 12 min
  Replay of the range above …

Waste at weekly resets
  alpha                                   38% wasted avg
     4 weekly resets observed · worst 61%
  Waste = headroom still unused when a 7-day window rolled over …
```

Every number here is computed by existing portable Core:
`UsageForecast.build`, `UsageForecast.burnRate(s)`, `WindowTelemetry.
fiveHourWindows/dailyRhythm/summary`, `WasteMath.generations`,
`WindowPlanner.replay/plan`, `TokenRateScanner.scan`,
`UsageHistory.merge/downsample`. **Compute nothing new.** The forecast
that the Mac gets from a live relay, this pane builds from the latest
samples the same way `UtilizationModel.dryRunPlan` does
(`UtilizationPane.swift:108-126`) — latest sample per account within the
last hour, so a stale file cannot fake a fleet.

`ForecastWords` / `ForecastClock` — check where they live. If they are in
`InfinitusUI` or the Mac app, move the pure string/format parts to Core;
the Windows pane needs "in 2h 14m" and "+11%/h" spelled identically.

Footers matter: every one of these sections carries an honesty note about
estimates and sampling. Port them verbatim. They are not decoration —
CLAUDE.md: "Usage-cost figures are estimates, never billing truth."

---

# Pane C — Stats

Mac source: `Sources/Infinitus/StatsPane.swift` (183 lines) +
`Sources/InfinitusCore/StatsPresentation.swift`.
Descriptor: `id: "stats"`, glyph `` (BarChart4), tint
`WinDark.rgb(100, 95, 220)` (the Mac's `.indigo`).

**This pane is nearly free.** `Stats.Presentation.groups(_:)` already
returns the exact tile catalogue — id, formatted value, delta string,
sparkline series — and was factored out precisely so "the phone renders
the exact same list" (`StatsPresentation.swift:5-7`). Windows is the third
consumer. Render, do not re-derive.

```
Period:  [ Today | This week | This month | This year ]
  2026-08-31 – 2026-09-06 · streak 12 days
  scanned 412 MB of 1,204 MB (318 files left)         (while scanning)

Throughput
  ┌───────────┐┌───────────┐┌───────────┐
  │ Commits   ││ Lines +   ││ Lines −   │
  │ 41   +12% ││ 3,204 +8% ││ 1,190 −4% │
  │ ▁▃▅▂▇▄▂   ││ ▁▂▆▃▇▅▁   ││ ▁▁▃▂▅▂▁   │
  └───────────┘└───────────┘└───────────┘
  … 12 tiles

Messages & sessions · Autonomy · Friction · Limits · Cost
  … same tile treatment

Where the effort went
  Activity          Stretches  Time    Tokens  Spend  Share
  Coding                   62  4h 10m   1.2M   $31.4  ████████
  Debugging                18  1h 02m   380k   $ 9.1  ██
  …
  Model
  Opus 5                   44  3h 20m   980k   $26.0  ███████
  …
  <activityFootnote>

Rhythm
  Activity by hour
  Mon ▁▁▁▂▃▅▇▇▅▃▂▁…                (7×24 heatmap)
  …
  Session lengths
  < 15 min   ████████
  15–60 min  ████
  1–4 h      ██
  > 4 h      █
                        41 h total · 62 min per session

  <model.notes lines>                          [ Refresh ]
```

Implementation:
- Tile grid: `GridItem(.adaptive(minimum: 150))` on the Mac → columns =
  `max(1, contentWidth / px(160))`, tile `px(150)×px(78)`.
- Tile paint: id in `captionFont`/`dim`; value in a semibold body font,
  monospaced digits (`CreateFontW` with `FIXED_PITCH` or just Segoe UI —
  Segoe UI's digits are tabular by default); delta in green for `+`,
  orange for `−` (note: the delta strings use U+2212 MINUS SIGN, not
  ASCII `-` — `StatsPresentation.deltaText` emits `"−\(-pct)%"`. Match on
  the right character); sparkline via `GDIChart.spark` when any value is
  non-zero, else blank space so the tiles stay the same height.
- Period persists (`stats_period`, the Mac's `@AppStorage` key).
- Scanning progress line from the chunk loop, exactly as `StatsModel`
  publishes it: `"scanned X MB of Y MB (n files left)"`.
- **Port `StatsModel`'s chunk loop**, not a single blocking scan. Its
  shape (`StatsModel.swift:148-233`) is the requirement, not a
  suggestion: a cold backfill is minutes; scanning the whole corpus in one
  shot shows nothing until it finishes. Specifically keep:
  - 64 MB `byteBudget` per pass, publishing after every pass;
  - the `stuck` check (a pass that consumes nothing or does not reduce
    `bytesRemaining` breaks the loop) and the `maxPasses` backstop;
  - the repo scan as a **separate** task started after the first chunk,
    merging into `days` when it finishes — and neither side ever
    overwriting `days` wholesale (that bug is documented at
    `StatsModel.swift:35-42`: a transcript chunk publishing after the repo
    scan dropped its commits back to 0).
- The repo scan needs `git` and optionally `gh` on PATH. On Windows,
  `RepoStatsScanner` is Mac-app code — port it to the tray (or, better,
  move the `Process`-running half into `InfinitusWinUI` and keep
  `RepoStats`'s pure parsers in Core, which they already are). If `git` is
  absent, skip repos and add the note "git not found — commits and lines
  aren't counted"; `RepoStats.parseLog`/`parsePRs` stay untested-by-you
  because Core already tests them.
- Session cwds come from the first transcript chunk's `cwds`, same as the
  Mac.

Empty/first-run: "No transcripts scanned yet." plus the progress line as
soon as the first pass starts.

---

# Pane D — Activity

Mac source: `Sources/Infinitus/ActivityPane.swift` (42 lines) +
`Sources/Infinitus/EventStore.swift` + `SwitchHistoryView.swift`.
Descriptor: `id: "activity"`, glyph `` (History), tint
`WinDark.rgb(60, 180, 180)` (the Mac's `.teal`).

```
Switch history
  alpha  →  bravo                                    20:20
  bravo  →  charlie                        yesterday 17:21
  charlie → alpha                            Aug 28 06:44
  [ Open full log… ]

Engine events
  ⇄  switched to bravo — alpha hit its 5h limit           20:20
  💀 charlie is out until 03:59                           19:02
  ⟲  nudged infinitus-c9 back to work                     18:40
  No events yet                                    (when empty)
```

Two sources:

1. **Switch history** — `cswap history --json --limit 20` →
   `SwitchHistoryList{ switches: [{from, to, at}], logPath }`. Resolve
   numbers to names from the current fleet (alias, else the email's local
   part). Time formatting: "20:20" today, "yesterday 17:21", "Aug 28
   06:44" (`SwitchHistoryView.swift:48-61`).
   > **Windows date-formatting hazard.** Setting
   > `DateFormatter.timeZone` to a named IANA zone **traps** on Windows
   > (swift-corelibs-foundation, Swift 6.3.3 — verified 2026-09-05; it
   > took down the whole `swift test` run at `StatsTests`, see
   > `Sources/InfinitusCore/Stats.swift:354-365`). `SwitchHistoryView`
   > uses a bare `DateFormatter` with `dateFormat` and no `timeZone`
   > assignment, which is fine. **Do not add a `timeZone` setter.** For
   > anything date-keyed, use `Calendar.dateComponents` and format by
   > hand, as `Stats.dayKey` does.

2. **Engine events** — the Mac's durable `events.jsonl`. **Nothing writes
   one on Windows.** Same situation as the usage history: without a
   writer the section is permanently empty, and worse, the Stats pane's
   "Limits" tile group (switches, limit stops, revivals, ignites,
   resumes, minutes lost) reads from `StatsEvents.days(...)` over that
   same file — so this affects two panes.

   Add a Windows `EventStore`:
   ```swift
   /// The tray's durable event log — %APPDATA%\Infinitus\events.jsonl,
   /// one JSON line per event. The Mac's EventStore, minus the actor
   /// (the tray has no Swift concurrency runtime driving it): a plain
   /// enum with an NSLock, appended from the tick and read by the panes.
   enum WinEventStore {
       static var url: URL
       static func append(_ event: StatsEvent)
       static func load() -> [StatsEvent]
       static func prune(now: Date = Date())   // 400-day retention
   }
   ```
   Encode/decode with `.iso8601` dates and `.sortedKeys`, exactly as the
   Mac does (`EventStore.swift:14-24`), so the two files are
   interchangeable.

   Then **emit** events from the tray, from the places that already know:
   - `switch` — in `TrayFleet.requestSwitch`'s report path, on a
     `.switched(to:)` outcome. Text: `"switched to \(name)"`.
   - `death` — when an account crosses into `AccountVitals.isDead` between
     two `TrayFleet` refreshes.
   - `limit` — when **every** account is dead (opens the all-out span
     `StatsEvents` measures).
   - `revival` — when an account leaves the dead set.
   - `resume`/`nudge` — the daemon's `ResumeSupervisor` is the one that
     nudges; if it cannot reach the tray cheaply, have the **daemon**
     append to the same file. Two writers appending short lines to a JSONL
     is safe enough with `O_APPEND` semantics on small writes, but be
     explicit about it in a comment and keep every line under 4 KB.

   The `kind` strings are load-bearing — `StatsEvents.days` switches on
   `"switch"`, `"death"`, `"limit"`, `"revival"`, `"ignite"`,
   `"resume"`, `"nudge"` (`StatsEvents.swift:38-53`). Use those exact
   strings or the Stats "Limits" group stays at zero.

   The `icon` field is an SF Symbol name on the Mac. On Windows, map it to
   a Segoe glyph at render time; store whatever the Mac stores so the file
   stays interchangeable, and keep a small `icon → glyph` table with a
   neutral fallback.

Display: newest first, last 30 in the pane (`suffix(30).reversed()`),
timestamp right-aligned in `captionFont`.

## Tests

Core — mostly already covered; add only what is new:
- If `TokenFormat` / `ForecastWords` / `ForecastClock` move to Core, their
  existing behaviour must be pinned by a test before the move and after.

`InfinitusWinUI`:
- `testEventStoreRoundTrip` — append 3, load 3, order preserved.
- `testEventStoreSkipsTornLine` — a truncated last line is ignored, the
  rest load (the Mac's `load` already does this via `split` +
  `compactMap`; assert it).
- `testEventStorePrunesOlderThan400Days`.
- `testUsageHistoryDedupesOnPollInstant` — two ticks with the same
  `usageFetchedAt` append one line.
- `testChartBarsHandleDegenerateInput` — empty, all-zero, single value,
  negative: no crash, no divide-by-zero. (Pure geometry function extracted
  from `GDIChart.bars`: `barRects(count:maxValue:in:) -> [RECT]`.)
- `testHeatmapIndexing` — 168 values map to (day, hour) the same way
  `Stats.hourSlot` produces them: Monday = 0.
- `testStatsChunkLoopStopsWhenStuck` — drive a fake scanner that never
  reduces `bytesRemaining`; assert the loop exits.

## Acceptance

1. Every pane opens in **under 200 ms** and shows either cached data or a
   named empty state — never a frozen window.
2. No pane blocks the UI thread; the sidebar stays clickable during a
   cold `StatsScanner` backfill.
3. Usage: window picker re-scans; caveats always visible; cached report
   renders instantly on the second open.
4. Utilization: after the tray has run long enough to write history
   samples, the chart, 5h windows and waste sections populate. Verify the
   JSONL is being written (`%APPDATA%\Infinitus\usage-history.*.jsonl`
   grows, one line per engine poll, not per tick).
5. Stats: tile values match `infinitusctl stats` on the Mac for the same
   corpus where comparable; the progress line counts up and stops; the
   repo scan adds commits without dropping transcript numbers.
6. Activity: a real account switch appends a `switch` event and it shows
   in the list **and** increments the Stats "Switches" tile.
7. Idle CPU with any of these panes open and scanning finished:
   **< 0.5%** over 15 s.
8. No GDI handle leak: open/close each pane 50 times and watch the
   process's GDI object count in Task Manager (add the column) — it must
   return to its baseline.

## Report

Status; files; tests; commit. Plus:
- which of `TokenFormat` / `ForecastWords` / `ForecastClock` moved to
  Core, and confirmation the Mac renders unchanged;
- whether the usage-history recorder and the event store landed (they are
  prerequisites for two panes having any content at all — if either
  slipped, say so loudly);
- the measured GDI handle count before/after the 50-open test;
- the measured idle CPU.
