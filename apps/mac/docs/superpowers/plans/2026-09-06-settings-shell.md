# Settings polish — the window shell, Display, Themes, dashboards, Lock, About (`settings-shell`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings stops being a hand-rolled list of eighteen buttons around a 700pt column. The sidebar becomes a real `List(selection:)` — arrow keys, type-select, focus ring, VoiceOver rows — grouped the way System Settings groups; the search field finds a setting by its own label and takes you to the row it lives on; the window is called "Settings" and says which pane you are in; Display's two anonymous cards of 8 and 13 controls become five named sections with footers that explain what each one costs; the Themes cards stop hiding half of themselves in a horizontal scroller and show the names a theme would give your accounts; and every dashboard, Lock and About pane speaks in whole sentences with Title Case status values instead of `no`, `held` and "osascript fallback".

**Architecture:** One new pure type in Core — `SettingsSearchIndex` over `SettingsSearchEntry` (pane, section, label, keywords, anchor) — ranks a query against the real setting labels and groups the hits by pane; it has no SwiftUI and is tested on its own. Each pane this stream owns publishes `static let searchEntries: [SettingsSearchEntry]` next to the sections it tags with `.settingsAnchor(_:)`, and `SettingsSearchCatalog` (app target) stitches those together with a title+keyword entry for every pane, including the panes another stream owns. `SettingsRoot` keeps its `HStack` (no `NavigationSplitView` — see the 2026-08-30 freeze note it carries) but the sidebar is now `SettingsSidebar`, a `List(selection:)` in `.sidebar` style whose selection is either a pane title or a search hit's row id; picking a hit selects the pane, scrolls to the section's `.id` through a `ScrollViewReader` and flashes it once through a `settingsHighlight` environment value. The window's title and subtitle are set from the view by a tiny `NSViewRepresentable`; `StatusItemController` only names it "Settings" and caps its width.

**Tech Stack:** Swift 6 compiler in Swift 5 language mode (`swift-tools-version: 5.9`, `platforms: [.macOS(.v14), .iOS(.v17)]`), SwiftUI + AppKit (app target), Foundation only in `InfinitusCore`, XCTest.

**Spec:** `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` — the design critique this whole round implements. Task 1 copies it into this worktree from `/Users/deathemperor/death/limitless-e2/.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md`; read it before Task 2. The rulings this stream implements are P1 "The shell", P2 "Explanations live in three containers", P2 "Copy that should not ship", the macOS half of P0 "no accessibility labels and no keyboard path", and the minor observations about the Themes scroller, the Stats orphan tile, the Utilization emoji and About's Update channel.

## Global Constraints

- **File ownership (three streams in parallel, all merging into `main`).**
  - This stream MAY edit:
    - `Sources/Infinitus/InfinitusApp.swift` — `settingsTabs(...)` and `SettingsRoot` (lines 192–476)
    - `Sources/Infinitus/StatusItemController.swift` — ONLY inside `showSettingsWindow()`: the `w.title` line (641), one added `w.contentMaxSize` line and one added frame-clamp line after `w.setFrameAutosaveName` (655). Nothing else in that file, and never `struct SettingsTab` (lines 20–34).
    - `Sources/Infinitus/DisplayPane.swift`, `ThemesPane.swift`, `CommunityThemes.swift`, `StatsPane.swift`, `UsagePane.swift`, `UtilizationPane.swift`, `MachinePane.swift`, `ActivityPane.swift`, `LockPane.swift`, `AboutPane.swift`, `AnimationsDebugPane.swift`
    - `Sources/Infinitus/WallWindow.swift` — ONLY `struct WallSection`'s body (lines 125–151). Ownership extension, see "Decisions" below.
    - `Sources/Infinitus/StatsTiles.swift` — ONLY the tile grid (`group` / `tileView`, lines 15–47). Ownership extension, see "Decisions".
    - new `Sources/Infinitus/SettingsSidebar.swift`, new `Sources/Infinitus/SettingsSearch.swift`
    - new `Sources/InfinitusCore/SettingsSearchIndex.swift`, new `Tests/InfinitusCoreTests/SettingsSearchIndexTests.swift`
    - new `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` (Task 1, copied in)
    - `CHANGELOG.md` — lines under `## 0.4.4 (unreleased)` → `### Mac`, in the LAST task only
  - This stream MUST NOT edit: `Sources/Infinitus/AccountsPane.swift` (read-only reference in Task 2), `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift`, `Sources/Infinitus/MirrorServer.swift`, anything under `Sources/InfinitusCore/Team/`, anything under `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/` (the popup's shared views — `SwitchHistoryView`, `GaugeBar`, `PopupFont`, `ForecastWords` are read and reused, never edited).
  - Every task's **Files** block repeats the forbidden list as "Do not touch:".
- **Read the craft floor before the first edit of any UI task**: `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`. It is step 1 of every task from Task 2 on.
- **Apple's containers, one rule everywhere.** A `Section` header NAMES the group (a noun phrase, never a sentence). A `Section` footer EXPLAINS the consequence. `.help()` survives only on icon-only buttons, and those also get an `.accessibilityLabel`. No `Text(...).font(.caption)` row inside a section pretending to be a footer.
- **Casing.** Sentence case for labels, toggles, pickers and footers. Title Case for buttons and menu items that are commands ("Sample Now", "Check for Updates…", "Open Themes File…"). Title Case for status values ("Active", "On Hold", "Not Set Up", "Nothing to flag"). The ellipsis is the single character `…` and only appears when the action opens something else.
- **Copy.** No engine names for their own sake, no PR numbers, no competitor names, no backticked CLI in user-facing text, no raw `"\(error)"` — every error is a sentence that names the problem and the next step. The house voice is the Remove-account alert: "The Claude account itself is untouched — you can add it back any time."
- **Accessibility.** Every icon-only button gets `.accessibilityLabel` naming its object; tooltip prose becomes `.accessibilityHint`; custom rows get `.accessibilityElement(children: .combine)`. No hard-coded font sizes or row heights in anything this stream writes (the existing "Aa" size preview in `DisplayPane.sizeTile` is exempt — the point size IS the value being previewed).
- **Reduce Motion.** Every animation this stream touches or adds reads `@Environment(\.accessibilityReduceMotion)`. Two `withAnimation` calls in this stream exist to make an open `NSPopover` re-measure (`DisplayPane.setLayout`, `ThemesPane.choose`) — they must NOT become unanimated, or the popup overflows (CLAUDE.md: "NSPopover measures content once"). Under Reduce Motion they use `.linear(duration: 0.01)`, which still re-measures through the animated path.
- **Performance (repo rule).** Idle CPU with any window open stays ~0%. No `TimelineView`, no `repeatForever`, no `.contentTransition(.numericText)` on anything that ticks. The one animation added here (the search highlight flash) is a single one-shot `.animation(_:value:)` that ends after 1.2 s.
- **Theme-aware.** Words and colours come from `RowTheme` (`liveTheme`, `model.rowTheme`); nothing hard-codes a theme's labels or colours.
- **Verification.** Every task ends with `swift build --product Infinitus` (ONE `--product` per invocation — with two flags SwiftPM builds only the last). Core work also runs `swift test --filter SettingsSearchIndexTests`. The full `swift test` runs in the last task. There is no app UI test target. A screenshot of a pane is OPTIONAL; if you take one, run the dev instance with `INFINITUS_CONTROL_SOCKET=/tmp/s-shell.sock` — without it `ControlServer.start()` unlinks the real app's socket.
- **CHANGELOG** lines go under `## 0.4.4 (unreleased)` → `### Mac`, one short sentence each, in the LAST task only.
- Every commit carries the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage by explicit path. **Never push.** No subagents from implementers.

## Decisions taken in this plan (the orchestrator rules on them)

1. **`WallWindow.swift` is an ownership extension.** Display's "Fleet wall" section is `WallSection`, which lives in `WallWindow.swift` and already carries a caption row where a footer belongs. Only its `body` (lines 125–151) is touched; no other stream claims that file.
2. **`StatsTiles.swift` is an ownership extension.** The orphan tile the critique names is produced by the `LazyVGrid` inside `StatsTiles`, not by `StatsPane`. `TeamMemberPane` renders the same view and benefits; its own file is never opened.
3. **`StatusItemController.swift` gets three lines, not one.** Capping the window (ruling 3) is impossible from SwiftUI, so `contentMaxSize` and a one-line clamp of the restored autosaved frame join the `w.title` line.
4. **Utilization's methodology goes into a `DisclosureGroup`, not a `.help`.** Ruling 6 asks for a "Learn more" tooltip; the stream's own container rule forbids `.help()` on anything but an icon-only button, and a hover-only tooltip is invisible to keyboard and VoiceOver users — which is the P0 this round is fixing. The footer becomes one sentence and the rest sits under a `DisclosureGroup("How this is measured")` inside the section.
5. **About's "Software Update" is the first *titled* section**, directly under the unlabeled hero. The hero is not a section with a name, so this satisfies "at the top of About" without nesting the update controls under the hero.
6. **Sidebar groups are derived from the pane title in `SettingsSidebar.swift`**, not from a new field on `SettingsTab` — `SettingsTab` lives in `StatusItemController.swift`, which this stream may barely touch. `LockModel.paneTitle` / `TeamModel.paneTitle` are used as the constants, and `provider != nil` means Engines.
7. **Panes owned by the other streams contribute their pane title and their existing `keywords` to the index and nothing else.** The other stream may add `searchEntries` to its own panes later; `SettingsSearchCatalog` is written so that adding one line per pane is the whole change.

---

## File structure

| File | Responsibility |
|---|---|
| `Sources/InfinitusCore/SettingsSearchIndex.swift` (new) | `SettingsSearchEntry`, `SettingsSearchIndex.matches(_:)` / `.grouped(_:)`. Pure Foundation, tested. |
| `Sources/Infinitus/SettingsSearch.swift` (new) | `SettingsSearchCatalog.index(tabs:)`, the `settingsHighlight` environment value and the `.settingsAnchor(_:)` modifier. |
| `Sources/Infinitus/SettingsSidebar.swift` (new) | `SettingsGroup` (General / Accounts / Dashboards / Engines / app) and `SettingsSidebar`, a `List(selection:)` sidebar with grouped pane rows and search-result rows. |
| `Sources/Infinitus/InfinitusApp.swift` | `SettingsRoot`: query state, index, selection→pane→highlight wiring, content width cap, ⌘F, window title/subtitle. |
| `Sources/Infinitus/StatusItemController.swift` | Window titled "Settings", capped at 1200pt wide. |
| `Sources/Infinitus/DisplayPane.swift` | Five named sections with footers, the headroom-sort toggle, anchors + `searchEntries`. |
| `Sources/Infinitus/WallWindow.swift` | `WallSection`'s caption becomes a `Section` footer. |
| `Sources/Infinitus/ThemesPane.swift` | `ThemeCard` wraps instead of scrolling and shows "Names like: …". |
| `Sources/Infinitus/CommunityThemes.swift` | Status copy in the house voice. |
| `Sources/Infinitus/UtilizationPane.swift` | Themed gauge legend, Title Case statuses, one-sentence run-rate footer + disclosure. |
| `Sources/Infinitus/StatsTiles.swift` | Tile rows that fill their width, so 13 tiles never orphan one. |
| `Sources/Infinitus/StatsPane.swift`, `UsagePane.swift` | Headers/footers, error sentences, copy. |
| `Sources/Infinitus/MachinePane.swift`, `ActivityPane.swift`, `LockPane.swift`, `AboutPane.swift`, `AnimationsDebugPane.swift` | Containers, casing, About's Software Update section and the notification-delivery wording. |
| `Tests/InfinitusCoreTests/SettingsSearchIndexTests.swift` (new) | Ranking, grouping, blank queries, unicode labels. |

---

### Task 1: The critique snapshot and the search index (Core)

**Files:**
- Create: `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` (copied, not authored)
- Create: `Sources/InfinitusCore/SettingsSearchIndex.swift`
- Create: `Tests/InfinitusCoreTests/SettingsSearchIndexTests.swift`
- Do not touch: `Sources/Infinitus/AccountsPane.swift`, `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift`, `MirrorServer.swift`, `Sources/InfinitusCore/Team/`, `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/`.

**Interfaces:**
- Produces:

```swift
public struct SettingsSearchEntry: Sendable, Equatable, Identifiable {
    public let pane: String
    public let section: String?
    public let label: String
    public let keywords: [String]
    public let anchor: String
    public var id: String { "\(anchor)#\(label)" }
    public init(pane: String, section: String? = nil, label: String,
                keywords: [String] = [], anchor: String? = nil)
}
public struct SettingsSearchIndex: Sendable {
    public init(_ entries: [SettingsSearchEntry])
    public var entries: [SettingsSearchEntry] { get }
    public func matches(_ query: String, limit: Int = 60) -> [SettingsSearchEntry]
    public func grouped(_ query: String, limit: Int = 60) -> [(pane: String, entries: [SettingsSearchEntry])]
    public func entry(id: String) -> SettingsSearchEntry?
}
```

- [ ] **Step 1: Copy the spec into the worktree.** From the worktree root:

```sh
mkdir -p .impeccable/critique
cp /Users/deathemperor/death/limitless-e2/.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md \
   .impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md
```

Read it before Task 2 — it is the spec for the whole round. Do not edit it.

- [ ] **Step 2: Write the failing tests.** New file `Tests/InfinitusCoreTests/SettingsSearchIndexTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

/// The Settings search index (critique P1 "the shell": the field matched
/// eight hand-written keywords per tab and never a setting's own label,
/// so "transparency", "keep awake" and "start at login" all returned
/// nothing though every one of them is a real setting).
final class SettingsSearchIndexTests: XCTestCase {
    private let index = SettingsSearchIndex([
        SettingsSearchEntry(pane: "Display", section: "Menu bar",
                            label: "Show only the icon",
                            keywords: ["menu bar", "glyph"]),
        SettingsSearchEntry(pane: "Display", section: "Popup",
                            label: "Transparency",
                            keywords: ["glass", "blur", "opacity"]),
        SettingsSearchEntry(pane: "Display", section: "Popup",
                            label: "Sort rows by headroom",
                            keywords: ["order", "sort"]),
        SettingsSearchEntry(pane: "Display", section: "Startup",
                            label: "Start at login", keywords: ["login item"]),
        SettingsSearchEntry(pane: "Display", section: "Startup",
                            label: "Keep the Mac awake while sessions are working",
                            keywords: ["caffeinate", "sleep"]),
        SettingsSearchEntry(pane: "Display", section: "Sessions",
                            label: "Checkpoint the repository at every prompt",
                            keywords: ["checkpoint", "git", "restore"]),
        SettingsSearchEntry(pane: "Themes", label: "Themes",
                            keywords: ["skin", "gallery"]),
        SettingsSearchEntry(pane: "Push", label: "Push",
                            keywords: ["slack", "telegram", "webhook"]),
    ])

    func testFindsASettingByItsOwnLabel() {
        let hits = index.matches("transparency")
        XCTAssertEqual(hits.first?.pane, "Display")
        XCTAssertEqual(hits.first?.label, "Transparency")
        XCTAssertEqual(hits.first?.anchor, "Display/Popup")
    }

    /// The critique's own examples. "keep awake" is not a substring of
    /// "Keep the Mac awake while sessions are working" — a query whose
    /// words all appear in a row still has to find it.
    func testTheQueriesTheOldFieldCouldNotAnswer() {
        for query in ["keep awake", "start at login", "headroom", "checkpoint"] {
            let hits = index.matches(query)
            XCTAssertEqual(hits.first?.pane, "Display", "\(query) found nothing")
        }
        XCTAssertEqual(index.matches("keep awake").first?.label,
                       "Keep the Mac awake while sessions are working")
    }

    func testRankingPrefersTheLabelOverAKeywordOverThePaneTitle() {
        // "sort" is this row's label word AND another row's keyword.
        let hits = index.matches("sort")
        XCTAssertEqual(hits.first?.label, "Sort rows by headroom")
        // A keyword-only hit still lands, after the label hits.
        XCTAssertTrue(index.matches("blur").contains { $0.label == "Transparency" })
        // The pane title matches every row of that pane, in declared order.
        XCTAssertEqual(index.matches("push").map(\.label), ["Push"])
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertFalse(index.matches("TRANSPARENCY").isEmpty)
        XCTAssertFalse(index.matches("  Keep Awake  ").isEmpty)
    }

    func testABlankQueryMatchesNothing() {
        XCTAssertTrue(index.matches("").isEmpty)
        XCTAssertTrue(index.matches("   \n").isEmpty)
        XCTAssertTrue(index.grouped(" ").isEmpty)
    }

    func testGroupedKeepsPaneOrderAndNeverRepeatsAPane() {
        let groups = index.grouped("s")
        XCTAssertEqual(groups.map(\.pane), Array(NSOrderedSet(array: groups.map(\.pane)) as! [String]))
        XCTAssertEqual(groups.first?.pane, "Display")
        XCTAssertEqual(groups.reduce(0) { $0 + $1.entries.count }, index.matches("s").count)
    }

    func testUnicodeLabelsAreSafe() {
        let themed = SettingsSearchIndex([
            SettingsSearchEntry(pane: "Utilization", section: "Forecast",
                                label: "🎥 session (5h)", keywords: ["window"]),
        ])
        XCTAssertEqual(themed.matches("🎥").count, 1)
        XCTAssertEqual(themed.matches("session").count, 1)
    }

    func testEntryLookupById() {
        let hit = index.matches("transparency")[0]
        XCTAssertEqual(index.entry(id: hit.id)?.label, "Transparency")
        XCTAssertNil(index.entry(id: "Display/Nowhere#Nothing"))
    }
}
```

- [ ] **Step 3: Run** `swift test --filter SettingsSearchIndexTests` → compile FAIL (`SettingsSearchIndex` does not exist).

- [ ] **Step 4: Implement.** New file `Sources/InfinitusCore/SettingsSearchIndex.swift`:

```swift
import Foundation

/// One searchable row of Settings: the pane it lives on, the section
/// that holds it, its own visible label, and any words a user might
/// type instead. `anchor` is the id the pane tags its Section with, so
/// a hit can scroll to and flash the group the row belongs to.
///
/// Panes declare these as `static let searchEntries` next to the
/// sections they describe, so a renamed label and its index entry move
/// together (critique P1: the old field matched a hand-written keyword
/// list that had drifted away from the settings themselves).
public struct SettingsSearchEntry: Sendable, Equatable, Identifiable {
    public let pane: String
    public let section: String?
    public let label: String
    public let keywords: [String]
    public let anchor: String

    public var id: String { "\(anchor)#\(label)" }

    public init(pane: String, section: String? = nil, label: String,
                keywords: [String] = [], anchor: String? = nil) {
        self.pane = pane
        self.section = section
        self.label = label
        self.keywords = keywords
        self.anchor = anchor ?? "\(pane)/\(section ?? "")"
    }
}

/// Ranked search over every setting the window can show. Pure
/// Foundation: it builds and ranks the same way on Linux, and its
/// ranking is the part worth testing.
public struct SettingsSearchIndex: Sendable {
    public let entries: [SettingsSearchEntry]
    /// Lower-cased once at build time — the query is matched against
    /// this, never against the display strings.
    private let folded: [Folded]

    private struct Folded: Sendable {
        let label: String
        let section: String
        let keywords: [String]
        let pane: String
        /// Everything above in one string, for the loose word match.
        let all: String
    }

    public init(_ entries: [SettingsSearchEntry]) {
        self.entries = entries
        self.folded = entries.map { entry in
            let label = entry.label.lowercased()
            let section = (entry.section ?? "").lowercased()
            let keywords = entry.keywords.map { $0.lowercased() }
            let pane = entry.pane.lowercased()
            return Folded(label: label, section: section, keywords: keywords,
                          pane: pane,
                          all: ([label, section, pane] + keywords).joined(separator: " "))
        }
    }

    public func entry(id: String) -> SettingsSearchEntry? {
        entries.first { $0.id == id }
    }

    /// Best matches first: an exact label, then a label that starts
    /// with the query, then a label that contains it, then the section,
    /// then a keyword, then the pane's own name — and last, a row where
    /// every word of the query appears somewhere, so "keep awake" finds
    /// "Keep the Mac awake while sessions are working". Ties keep
    /// declaration order, so a pane's rows stay in the order it shows them.
    public func matches(_ query: String, limit: Int = 60) -> [SettingsSearchEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let words = q.split(separator: " ").map(String.init)
        var scored: [(rank: Int, order: Int, entry: SettingsSearchEntry)] = []
        for (i, f) in folded.enumerated() {
            let rank: Int
            if f.label == q { rank = 0 }
            else if f.label.hasPrefix(q) { rank = 1 }
            else if f.label.contains(q) { rank = 2 }
            else if f.section.contains(q) { rank = 3 }
            else if f.keywords.contains(where: { $0.contains(q) }) { rank = 4 }
            else if f.pane.contains(q) { rank = 5 }
            else if words.count > 1, words.allSatisfy({ f.all.contains($0) }) { rank = 6 }
            else { continue }
            scored.append((rank, i, entries[i]))
        }
        return scored.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .prefix(limit).map(\.entry)
    }

    /// The same matches, gathered under their pane in the order the
    /// panes first appear — the shape the sidebar draws.
    public func grouped(_ query: String, limit: Int = 60) -> [(pane: String, entries: [SettingsSearchEntry])] {
        var order: [String] = []
        var byPane: [String: [SettingsSearchEntry]] = [:]
        for hit in matches(query, limit: limit) {
            if byPane[hit.pane] == nil { order.append(hit.pane) }
            byPane[hit.pane, default: []].append(hit)
        }
        return order.map { ($0, byPane[$0] ?? []) }
    }
}
```

- [ ] **Step 5: Run** `swift test --filter SettingsSearchIndexTests` → PASS (8 tests). Then `swift build --product Infinitus` → succeeds.

- [ ] **Step 6: Commit.**

```sh
git add .impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md \
        Sources/InfinitusCore/SettingsSearchIndex.swift \
        Tests/InfinitusCoreTests/SettingsSearchIndexTests.swift
git commit -m "settings: a ranked index of every setting's own label, and the critique it answers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Display — five named sections, footers instead of tooltips, and the headroom toggle

**Files:**
- Modify: `Sources/Infinitus/DisplayPane.swift` (whole `body`, lines 16–168)
- Modify: `Sources/Infinitus/WallWindow.swift` (ONLY `WallSection.body`, lines 130–150)
- Read only, never edit: `Sources/Infinitus/AccountsPane.swift` (lines 640–651 — the toggle and binding being moved here)
- Do not touch: `AccountsPane.swift`, `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift`, `MirrorServer.swift`, `Sources/InfinitusCore/Team/`, `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/`.

**Interfaces:**
- Produces: `extension DisplayPane { static let searchEntries: [SettingsSearchEntry] }` and five anchors, `"Display/Menu bar"`, `"Display/Popup"`, `"Display/Fleet wall"`, `"Display/Sessions"`, `"Display/Startup"`.
- Consumes: `$model.sortByHeadroom` (`AppModel.swift:541`, `@Published var sortByHeadroom` backed by the `sort_headroom` default) — the same binding `AccountsPane.swift:644` uses today. The accounts stream deletes that toggle from `AccountsPane`; do not edit that file yourself, and do not be surprised if it is still there when you build.
- `.settingsAnchor(_:)` does not exist yet (Task 7 adds it). This task writes the anchors as `.id(...)` on each Section, and Task 7 replaces those with `.settingsAnchor(...)`. Nothing here depends on Task 7.

- [ ] **Step 1: Read** `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md` and `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` (the "Jordan — first-timer" red flag and P2 "Explanations live in three containers" are this task's spec). Then read `Sources/Infinitus/DisplayPane.swift` in full.

- [ ] **Step 2: Replace the body.** In `Sources/Infinitus/DisplayPane.swift`, replace lines 16–168 — `var body` through the closing `}` of `body` and the blank lines after it, i.e. everything from `var body: some View {` down to and including line 168. `setLayout` (171–173), `sizeTile` (175–182), `glassSlider` (184–196) and `PickTile` (203–227) all stay exactly where they are; Steps 3 and 4 edit two of them in place. The replacement:

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            menuBarSection
            popupSection
            WallSection(model: model)
                .id("Display/Fleet wall")
            sessionsSection
            startupSection
        }
        .formStyle(.grouped)
    }

    // MARK: menu bar

    @ViewBuilder private var menuBarSection: some View {
        Section {
            Toggle("Show only the icon", isOn: $model.titleIconOnly)
            Toggle("Show the account name", isOn: $model.showAccountName)
                .disabled(model.titleIconOnly)
            Picker("Percentages", selection: $model.titlePct) {
                ForEach(TitlePrefs.pctChoices, id: \.self) {
                    Text(pctLabels[$0] ?? $0).tag($0)
                }
            }
            .disabled(model.titleIconOnly)
            Picker("Reset time", selection: $model.titleReset) {
                ForEach(TitlePrefs.resetChoices, id: \.self) {
                    Text(resetLabels[$0] ?? $0).tag($0)
                }
            }
            .disabled(model.titleIconOnly)
            Toggle("Show model limits", isOn: $model.titleScoped)
                .disabled(model.titleIconOnly)
            Toggle("Count what's left, not what's used", isOn: $model.titleRemaining)
                .disabled(model.titleIconOnly)
            Toggle("Follow the theme", isOn: $model.menuBarThemed)
            Toggle("Effects", isOn: $model.menuBarEffects)
                .disabled(!model.menuBarThemed)
            Toggle("Show the icon in the menu bar", isOn: $model.menuBarIconShown)
            if !model.menuBarIconShown {
                Text("The icon is hidden until the next launch. The engine "
                     + "keeps running, and this window and the pinned window "
                     + "still reach it.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Menu bar")
        } footer: {
            Text("Showing only the icon puts the rest of this group away "
                 + "until you turn it off. The reset time is when the active "
                 + "account's fuller window refills — as a countdown (↺2h14m) "
                 + "or a clock time (↺20:29). Effects glow the item on a "
                 + "switch and breathe an ember while the active account "
                 + "burns ahead of pace. Hiding the icon lasts until quit: it "
                 + "always comes back on the next launch, so the app can "
                 + "never strand itself with no way in.")
        }
        .id("Display/Menu bar")
    }

    // MARK: popup

    @ViewBuilder private var popupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Layout")
                HStack(spacing: 12) {
                    PickTile(title: "Wide rows",
                             selected: model.popupLayout == "wide",
                             choose: { setLayout("wide") }) {
                        VStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in
                                Capsule().fill(Color.secondary.opacity(0.65))
                                    .frame(height: 3)
                            }
                        }
                        .padding(.horizontal, 9)
                    }
                    PickTile(title: "Stacked cards",
                             selected: model.popupLayout == "stacked",
                             choose: { setLayout("stacked") }) {
                        VStack(spacing: 3) {
                            ForEach(0..<2, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.65))
                                    .frame(width: 22, height: 10)
                            }
                        }
                    }
                    PickTile(title: "Horizontal cards",
                             selected: model.popupLayout == "hstack",
                             choose: { setLayout("hstack") }) {
                        HStack(spacing: 3) {
                            ForEach(0..<2, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.65))
                                    .frame(width: 10, height: 22)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Size")
                HStack(spacing: 12) {
                    sizeTile("Default", "default", 11)
                    sizeTile("Large", "large", 13)
                    sizeTile("Extra large", "xlarge", 15)
                    sizeTile("Huge", "huge", 18)
                }
            }
            glassSlider("Transparency", value: $model.glassFocused)
            Toggle("Compact rows", isOn: $model.compactRows)
            Toggle("Hide the action buttons", isOn: $model.footerActionsHidden)
            Toggle("Sort rows by headroom", isOn: $model.sortByHeadroom)
            Toggle("Floating countdown when every account is out",
                   isOn: $model.revivalPanelShown)
        } header: {
            Text("Popup")
        } footer: {
            Text("Transparency is one value for every state — the popup "
                 + "never shifts with focus, and a bright app behind it is "
                 + "capped to a legible level at every setting. Hiding the "
                 + "action buttons leaves everything they did in the menu "
                 + "bar icon's right-click menu. Sorting by headroom puts "
                 + "the active account first, then the next candidate, then "
                 + "the fullest — slot numbers don't move, and Settings › "
                 + "Accounts keeps the engine's own order. The floating "
                 + "countdown is a small always-on-top panel saying who "
                 + "recovers first and when.")
        }
        .id("Display/Popup")
    }

    // MARK: sessions

    @ViewBuilder private var sessionsSection: some View {
        Section {
            Toggle("Checkpoint the repository at every prompt",
                   isOn: $model.checkpointsEnabled)
            Toggle("Name unnamed sessions with Claude Haiku",
                   isOn: $model.sessionAutoNames)
            Picker("New sessions from the phone open in", selection: $model.sessionHost) {
                Text("cmux when installed, else Terminal").tag("auto")
                Text("cmux").tag("cmux")
                Text("Terminal").tag("terminal")
            }
        } header: {
            Text("Sessions")
        } footer: {
            Text("Checkpointing records the working tree as a hidden git "
                 + "ref at every prompt, so a session can be compared or "
                 + "put back later; ignored files stay out and git status "
                 + "is untouched. Naming asks Claude Haiku once per "
                 + "session on the active account — roughly a fraction of "
                 + "a cent each, and it re-asks when the work moves on. "
                 + "The terminal choice takes effect at the next launch.")
        }
        .id("Display/Sessions")
    }

    // MARK: startup

    @ViewBuilder private var startupSection: some View {
        Section {
            Picker("Refresh interval", selection: $model.refreshInterval) {
                ForEach(TitlePrefs.refreshChoices, id: \.self) {
                    Text(intervalLabels[$0] ?? "\($0)s").tag($0)
                }
            }
            Toggle("Start at login",
                   isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                .onAppear { login.refresh() }
            if let note = login.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Keep the Mac awake while sessions are working",
                   isOn: $model.keepAwake)
        } header: {
            Text("Startup")
        } footer: {
            Text("The login item points at where the app is right now — "
                 + "move it and turn this off and on again. Keeping the Mac "
                 + "awake holds a power assertion while any session is "
                 + "mid-turn; the display may still sleep, the machine "
                 + "won't.")
        }
        .id("Display/Startup")
    }
```

Notes for the implementer, all of them load-bearing:

- Every `.help()` on this pane is gone; its content is in the footers above. That is the P2 fix ("one rule, Apple's").
- Labels shed the words the section header now carries ("Menu bar shows only the icon" → "Show only the icon"). Do not re-add them.
- "Menu bar counts remaining, not used" becomes "Count what's left, not what's used" — the same setting, a sentence a first-timer can parse.
- The headroom toggle is NEW here and its binding is `$model.sortByHeadroom`; it is not a display-only afterthought in Accounts any more.
- `WallSection` is called with `.id("Display/Fleet wall")` so the search can land on it.

- [ ] **Step 3: `setLayout` honours Reduce Motion without losing the re-measure.** Replace `setLayout` (lines 171–173) with:

```swift
    /// withAnimation is not decoration here: an open NSPopover measures
    /// its content once, and only an animated change makes it re-measure
    /// live (CLAUDE.md). Under Reduce Motion the animation shrinks to a
    /// single frame instead of disappearing — dropping it outright leaves
    /// the popup overflowing or padded.
    private func setLayout(_ value: String) {
        withAnimation(reduceMotion ? .linear(duration: 0.01)
                                   : .easeInOut(duration: 0.3)) {
            model.popupLayout = value
        }
    }
```

- [ ] **Step 4: `PickTile` gets an accessible identity.** In `PickTile.body` (line 209), replace `.buttonStyle(.plain)` (line 225) with:

```swift
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
```

- [ ] **Step 5: `WallSection`'s caption becomes a footer.** In `Sources/Infinitus/WallWindow.swift`, replace lines 131–149 (`Section("Fleet wall") { … }`) with:

```swift
        Section {
            Picker("Display", selection: $choice) {
                Text("Spare screen (auto)").tag("")
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .onChange(of: choice) { _, v in
                if v.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "wall_display")
                } else {
                    UserDefaults.standard.set(v, forKey: "wall_display")
                }
            }
            Button("Enter Full-Screen Fleet Wall") { model.showWall?() }
        } header: {
            Text("Fleet wall")
        } footer: {
            Text("The popup, screen-sized, for the display that's just "
                 + "there to look at. Esc leaves it.")
        }
```

- [ ] **Step 6: The search entries.** Append to the END of `Sources/Infinitus/DisplayPane.swift`, after `PickTile` (line 227's closing brace):

```swift
/// What Settings search can find on this pane. One entry per visible
/// row; `anchor` is the Section id the row lives under, so a hit scrolls
/// to and flashes its group.
extension DisplayPane {
    static let searchEntries: [SettingsSearchEntry] = {
        let menuBar = "Menu bar", popup = "Popup", wall = "Fleet wall"
        let sessions = "Sessions", startup = "Startup"
        func entry(_ section: String, _ label: String, _ keywords: [String]) -> SettingsSearchEntry {
            SettingsSearchEntry(pane: "Display", section: section,
                                label: label, keywords: keywords)
        }
        return [
            entry(menuBar, "Show only the icon", ["glyph", "icon only", "menu bar"]),
            entry(menuBar, "Show the account name", ["name", "alias"]),
            entry(menuBar, "Percentages", ["percent", "5h", "7d", "session", "weekly"]),
            entry(menuBar, "Reset time", ["countdown", "clock", "refill", "reset"]),
            entry(menuBar, "Show model limits", ["model", "scoped", "opus", "fable"]),
            entry(menuBar, "Count what's left, not what's used", ["remaining", "used", "headroom"]),
            entry(menuBar, "Follow the theme", ["theme", "colour", "color"]),
            entry(menuBar, "Effects", ["glow", "ember", "animation", "flash"]),
            entry(menuBar, "Show the icon in the menu bar", ["hide", "hidden", "status item"]),
            entry(popup, "Layout", ["wide", "stacked", "horizontal", "cards", "rows"]),
            entry(popup, "Size", ["text size", "large", "huge", "scale"]),
            entry(popup, "Transparency", ["glass", "blur", "opacity", "translucent"]),
            entry(popup, "Compact rows", ["compact", "one line", "dense"]),
            entry(popup, "Hide the action buttons", ["actions", "buttons", "footer", "chips"]),
            entry(popup, "Sort rows by headroom", ["order", "sort", "headroom", "next"]),
            entry(popup, "Floating countdown when every account is out", ["revival", "panel", "floating", "all out"]),
            entry(wall, "Display", ["wall", "screen", "monitor", "full screen"]),
            entry(wall, "Enter Full-Screen Fleet Wall", ["wall", "full screen", "kiosk"]),
            entry(sessions, "Checkpoint the repository at every prompt", ["checkpoint", "git", "restore", "diff", "undo"]),
            entry(sessions, "Name unnamed sessions with Claude Haiku", ["haiku", "name", "title", "auto name"]),
            entry(sessions, "New sessions from the phone open in", ["terminal", "cmux", "phone", "host"]),
            entry(startup, "Refresh interval", ["poll", "interval", "refresh", "seconds"]),
            entry(startup, "Start at login", ["login item", "startup", "launch", "boot"]),
            entry(startup, "Keep the Mac awake while sessions are working", ["keep awake", "awake", "caffeinate", "sleep", "power"]),
        ]
    }()
}
```

Add `import InfinitusCore` at the top of the file if it is not already there (it is, line 2).

- [ ] **Step 7: Verify.** `swift build --product Infinitus` → succeeds. Read the rendered pane once (optional screenshot; if you take one, run the dev instance with `INFINITUS_CONTROL_SOCKET=/tmp/s-shell.sock`) and confirm: five named groups, every footer legible at the default window width, no tooltip left on any toggle in this file (`grep -c '\.help(' Sources/Infinitus/DisplayPane.swift` → 0).

- [ ] **Step 8: Commit.**

```sh
git add Sources/Infinitus/DisplayPane.swift Sources/Infinitus/WallWindow.swift
git commit -m "settings: Display is five named groups with footers, and it owns the headroom sort

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Themes — cards that show the whole theme, including the names it gives accounts

**Files:**
- Modify: `Sources/Infinitus/ThemesPane.swift`
- Modify: `Sources/Infinitus/CommunityThemes.swift` (copy only, lines 36, 38, 56, 58, 84, 98–102)
- Do not touch: `AccountsPane.swift`, `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift`, `MirrorServer.swift`, `Sources/InfinitusCore/Team/` (`RowTheme` in `Sources/InfinitusCore/RowTheme.swift` is READ, never edited), `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/`.

**Interfaces:**
- Produces: `extension ThemesPane { static let searchEntries: [SettingsSearchEntry] }`, anchors `"Themes/Built-in"`, `"Themes/Your themes"`, `"Themes/Community"`.
- Consumes (read-only): `RowTheme.accountNames` (`Sources/InfinitusCore/RowTheme.swift:72`) — may be empty for a plain theme; `RowTheme.plain` (:15).

- [ ] **Step 1: Read** the craft floor, then `Sources/Infinitus/ThemesPane.swift` in full. The critique's minor observation is the spec: "ThemeCard's preview sits inside a horizontal ScrollView — wide themes are silently scrollable inside a card, which no user will discover" and "Themes previews never show the theme's name pool, even though Randomize names draws from it".

- [ ] **Step 2: The card wraps instead of scrolling.** In `Sources/Infinitus/ThemesPane.swift`, replace `ThemeCard.body`'s preview host (lines 88–91):

```swift
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    preview.fixedSize()
                }
```

with:

```swift
            VStack(alignment: .leading, spacing: 8) {
                // Three layouts, widest first: SwiftUI takes the first
                // that fits the card. A horizontal ScrollView used to
                // hide the right-hand half of a wide theme with no hint
                // that there was more (critique, minor observations).
                ViewThatFits(in: .horizontal) {
                    preview(wrapped: false, times: true)
                    preview(wrapped: true, times: true)
                    preview(wrapped: true, times: false)
                }
                namePool
```

- [ ] **Step 3: The preview takes the two knobs, and gains the name pool.** Replace the whole `preview` computed property (lines 113–168) with:

```swift
    // Same fake numbers for every theme so the cards compare like-for-like:
    // session 21% used, weekly 68% used (ahead of pace), credit 74%, $1,131.
    // `wrapped` splits the credit row (the widest) over two lines;
    // `times` keeps the reset clocks — dropping them is the last resort
    // for a very wide custom theme.
    @ViewBuilder private func preview(wrapped: Bool, times: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if theme.plain {
                HStack(spacing: 3) {
                    Text(theme.sessionLabel).foregroundStyle(.secondary)
                    Text("21%").monospacedDigit()
                    if times {
                        Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 3) {
                    Text(theme.weeklyLabel).foregroundStyle(.secondary)
                    Text("68%").monospacedDigit()
                    if times {
                        Text("5d 9h (Sep 4 03:59)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 3) {
                    Text(theme.creditLabel).foregroundStyle(.secondary)
                    Text("74%").monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(theme.scopedPrefix + theme.modelName("Fable")).foregroundStyle(.secondary)
                    Text("74%").monospacedDigit()
                }
            } else {
                // Every row wears its own fixedSize: a bare VStack of
                // text+bar rows under-reports its ideal HEIGHT (macOS 26,
                // probed 2026-08-30) and the last row clipped to ":"
                // slivers (user screenshot).
                HStack(spacing: 3) {
                    Text(theme.sessionLabel).font(.caption).bold()
                        .foregroundStyle(ThemeColor.resolve(theme.sessionColor))
                    GaugeBar(remaining: 79, color: ThemeColor.resolve(theme.sessionColor), animated: false)
                    if times {
                        Text("4h 8m (22:09)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                HStack(spacing: 3) {
                    Text(theme.weeklyLabel).font(.caption).bold()
                        .foregroundStyle(ThemeColor.resolve(theme.weeklyColor))
                    GaugeBar(remaining: 32, color: ThemeColor.resolve(theme.weeklyColor), animated: false)
                    if times {
                        Text(theme.revivePrefix + "5d 9h (Sep 4 03:59)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
                creditRow(wrapped: wrapped)
            }
        }
    }

    /// The widest row: credit gauge, the model alias and its gauge, and
    /// the cash figure. `wrapped` puts the model half on its own line.
    @ViewBuilder private func creditRow(wrapped: Bool) -> some View {
        let credit = HStack(spacing: 3) {
            Text(theme.creditLabel).font(.caption).bold()
                .foregroundStyle(ThemeColor.resolve(theme.creditColor))
            GaugeBar(remaining: 26, color: ThemeColor.resolve(theme.creditColor), animated: false)
        }
        let model = HStack(spacing: 3) {
            Text(theme.scopedPrefix + theme.modelName("Fable")).font(.caption).bold()
                .foregroundStyle(ThemeColor.resolve(theme.scopedColor))
            GaugeBar(remaining: 26, color: ThemeColor.resolve(theme.scopedColor), animated: false)
            Text(verbatim: "\(theme.cashIcon)1,131")
                .font(.caption).foregroundStyle(.yellow)
        }
        if wrapped {
            credit.fixedSize()
            model.fixedSize()
        } else {
            HStack(spacing: 3) { credit; model }.fixedSize()
        }
    }

    /// "Names like: Sheriff, Outlaw" — the pool Randomize names draws
    /// from, which the cards never showed even though the tooltip said
    /// so (critique, minor observations). A theme with no pool of its
    /// own (the plain one) simply doesn't show the line.
    @ViewBuilder private var namePool: some View {
        let names = theme.accountNames.prefix(2)
        if !names.isEmpty {
            Text("Names like: " + names.joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
```

- [ ] **Step 4: The card is one accessible element.** Replace `ThemeCard.body`'s trailing `.buttonStyle(.plain)` (line 110) with:

```swift
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityHint("Shows a live preview of this theme's gauges, "
                           + "labels and account names.")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
```

- [ ] **Step 5: `choose` keeps its re-measure under Reduce Motion.** Replace `choose` (lines 54–62) with:

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func choose(_ id: String) {
        // withAnimation is load-bearing: an open popover re-measures
        // through the animated path, and a theme with wider or narrower
        // cells otherwise left the popup overflowing or padded
        // (user-reported). Reduce Motion shortens it to one frame
        // rather than removing it.
        withAnimation(reduceMotion ? .linear(duration: 0.01)
                                   : .easeInOut(duration: 0.3)) {
            model.gamification = id
        }
    }
```

(`@Environment` must be declared with the other properties at the top of `ThemesPane`, not inside the function — put it under `@ObservedObject var model: AppModel` on line 11 and leave only the function here.)

- [ ] **Step 6: Section anchors and the file button's casing.** In `ThemesPane.body`: add `.id("Themes/Built-in")` to the `Section("Built-in")`, `.id("Themes/Your themes")` to `Section("Your themes")`, and give the second section a real footer instead of the caption beside the button — replace lines 28–48 with:

```swift
            Section {
                if model.customThemes.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.customThemes) { theme in
                            ThemeCard(theme: theme,
                                      selected: model.gamification == theme.id) {
                                choose(theme.id)
                            }
                        }
                    }
                }
                Button("Open Themes File…") { openThemesFile() }
            } header: {
                Text("Your themes")
            } footer: {
                Text("Your own skins live in a JSON file; Infinitus reloads "
                     + "it every time this pane opens.")
            }
            .id("Themes/Your themes")
            CommunityThemesSection(model: model)
                .id("Themes/Community")
```

- [ ] **Step 7: Community copy.** In `Sources/Infinitus/CommunityThemes.swift`:
  - line 36: `status = "no community themes yet — add the first!"` → `status = "No community themes yet — yours could be the first."`
  - line 38: `status = "couldn't load the gallery: \(error.localizedDescription)"` → `status = "Couldn't reach the gallery. Check your connection and choose Refresh."`
  - line 56: `status = "installed \(theme.name)"` → `status = "Installed \(theme.name)."`
  - line 58: `status = "install failed: \(error.localizedDescription)"` → `status = "Couldn't install that theme. Choose Refresh and try again."`
  - line 84: `Text("Installed")` stays.
  - lines 97–103: the button row loses its caption sibling and the disclosure gains a footer:

```swift
            HStack {
                Button("Refresh") { Task { await gallery.refresh() } }
                    .disabled(gallery.busy)
                Button("Share Yours…") { openURL(CommunityThemesModel.contributeURL) }
            }
            Text("Themes here are copied into your own file when you install "
                 + "one, so they keep working offline. Share yours by adding "
                 + "it to the gallery on GitHub.")
                .font(.caption).foregroundStyle(.secondary)
```

  (This one stays a caption `Text`: it is inside a `DisclosureGroup`, which has no footer slot. Note it in the commit body.)

- [ ] **Step 8: Search entries.** Append to the end of `Sources/Infinitus/ThemesPane.swift`:

```swift
extension ThemesPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Themes", section: "Built-in", label: "Theme",
                            keywords: ["theme", "skin", "row theme", "gamification",
                                       "rpg", "wild west", "cyberpunk", "hades"]),
        SettingsSearchEntry(pane: "Themes", section: "Your themes",
                            label: "Open Themes File…",
                            keywords: ["custom", "json", "themes file", "own theme"]),
        SettingsSearchEntry(pane: "Themes", section: "Community",
                            label: "Community themes",
                            keywords: ["gallery", "community", "install", "share"],
                            anchor: "Themes/Community"),
    ]
}
```

- [ ] **Step 9: Verify.** `swift build --product Infinitus` → succeeds. Confirm by eye (optional screenshot, `INFINITUS_CONTROL_SOCKET=/tmp/s-shell.sock`): no card scrolls sideways, the widest built-in theme (Cyberpunk or Metal Gear) wraps its credit row instead of clipping, and every card that has a pool shows "Names like: …".

- [ ] **Step 10: Commit.**

```sh
git add Sources/Infinitus/ThemesPane.swift Sources/Infinitus/CommunityThemes.swift
git commit -m "settings: theme cards wrap instead of hiding half of themselves, and show the names a theme gives accounts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The dashboards — Utilization's legend, Stats' orphan tile, Usage's errors

**Files:**
- Modify: `Sources/Infinitus/UtilizationPane.swift`
- Modify: `Sources/Infinitus/StatsTiles.swift` (the grid only, lines 15–47)
- Modify: `Sources/Infinitus/StatsPane.swift`
- Modify: `Sources/Infinitus/UsagePane.swift`
- Do not touch: `AccountsPane.swift`, `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift` (`TeamMemberPane` renders `StatsTiles` and must keep compiling — do not open it), `MirrorServer.swift`, `Sources/InfinitusCore/`, `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/`.

**Interfaces:**
- Produces: `searchEntries` for `UtilizationPane`, `StatsPane`, `UsagePane`; anchors `"Utilization/Forecast"`, `"Utilization/Run rate"`, `"Stats/Period"`, `"Usage/Estimate"`.
- Consumes: `RowTheme.plain`, `.sessionLabel`, `.weeklyLabel`, `.scopedPrefix` via the pane's existing `liveTheme` (`UtilizationPane.swift:338`).

- [ ] **Step 1: Read** the craft floor and the critique's "Valley 2 — Utilization" and Stats minor observation. Then read all four files.

- [ ] **Step 2: Utilization's forecast gets a legend and Title Case statuses.** In `Sources/Infinitus/UtilizationPane.swift`, in `forecastSection` (line 233):
  - Immediately after `Section {` (line 234), insert the legend row:

```swift
            if !liveTheme.plain {
                // The gauge keys are the theme's own words, and under a
                // themed skin they are emoji — three glyphs per account
                // with nothing saying what they mean (critique: "un-legended
                // column keys"). One themed line fixes it for all thirteen.
                HStack(spacing: 14) {
                    Text("\(liveTheme.sessionLabel) session (5h)")
                    Text("\(liveTheme.weeklyLabel) weekly (7d)")
                    if !liveTheme.scopedPrefix.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("\(liveTheme.scopedPrefix.trimmingCharacters(in: .whitespaces)) model limit")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
```

  - line 241: `Text("active")` → `Text("Active")`
  - line 243: `Text("held")` → `Text("On Hold")`
  - line 250: `Text("no limit in sight")` → `Text("No limit in sight")`
  - line 268: `Text("resets " + ForecastClock.label(r))` → `Text("Resets " + ForecastClock.label(r))`
  - line 264: `?? (w.ratePctPerHour == nil ? "" : "resets before it fills")` → `?? (w.ratePctPerHour == nil ? "" : "Resets before it fills")`
  - line 262: `"out " + ForecastClock.label($0)` → `"Out " + ForecastClock.label($0)`
  - line 259: `?? "pace unknown"` → `?? "Pace unknown"`
  - line 274: `Text("No projection yet — needs an active account and ten minutes of polls.")` stays.
  - Add `.id("Utilization/Forecast")` after the section's `footer:` closure (i.e. on the `Section`).
  - Give each account line one accessible identity: on the `VStack(alignment: .leading, spacing: 3)` at line 237, add `.accessibilityElement(children: .combine)`.

- [ ] **Step 3: The run-rate methodology moves out of the footer.** Replace `runRateSection`'s `footer:` (lines 211–217) with a one-sentence footer, and add the disclosure inside the section body — that is, insert this just before the closing `}` of the section's content (after line 203's `Text("No transcript usage found.")` branch):

```swift
            DisclosureGroup("How this is measured") {
                Text("Per minute and per hour come from the last 60 minutes, "
                     + "per day from the last 24 hours, per week from the "
                     + "last 7 days. One turn is counted once. Dollars are "
                     + "what the same tokens would cost at API list prices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

and the footer becomes:

```swift
        } footer: {
            Text("Read off Claude Code's own transcripts — an estimate, "
                 + "never a bill.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .id("Utilization/Run rate")
```

(Ruling 6 asked for a `.help` tooltip; a disclosure is the same content, reachable by keyboard and VoiceOver, and does not break this stream's own "tooltips only on icon-only buttons" rule. See "Decisions" in this plan.)

- [ ] **Step 4: The rest of Utilization's copy.** Same file:
  - line 191: `Text("Unpriced (tokens counted, $ not): " …)` → `Text("Tokens counted but not priced: " + r.unpricedModels.joined(separator: ", "))`
  - line 446/452: `Text("unused")` → `Text("Unused")`, `Text("open")` → `Text("Open")`
  - line 473: the footer's escaped quotes `\"used\"` → curly quotes `“used”`.
  - line 157: `Text("No history yet — samples accrue while Infinitus runs (one per engine usage poll).")` → `Text("No history yet. Samples build up while Infinitus runs — one per engine usage poll.")`

- [ ] **Step 5: Stats tiles fill their last row.** In `Sources/Infinitus/StatsTiles.swift`, replace `group` (lines 15–22) with:

```swift
    private func group(_ g: Stats.Presentation.Group) -> some View {
        Section(g.id) {
            TileRows(tiles: g.tiles) { tileView($0) }
        }
    }
```

and append to the same file, after `StatsTiles`'s closing brace:

```swift
/// Tiles laid out in rows that always fill the width. A LazyVGrid with
/// a fixed column count left the 13th Throughput tile alone in a row of
/// four with three empty cells beside it (critique, minor observations);
/// 13 has a remainder of one at every plausible column count, so the fix
/// is to let the last row's tiles share the leftover width instead of
/// leaving holes.
private struct TileRows<Content: View>: View {
    let tiles: [Stats.Presentation.Tile]
    @ViewBuilder let tile: (Stats.Presentation.Tile) -> Content

    private static var minTile: CGFloat { 150 }
    private static var spacing: CGFloat { 10 }

    @State private var width: CGFloat = 0

    private var columns: Int {
        max(1, Int((width + Self.spacing) / (Self.minTile + Self.spacing)))
    }

    private var rows: [[Stats.Presentation.Tile]] {
        stride(from: 0, to: tiles.count, by: columns).map {
            Array(tiles[$0..<min($0 + columns, tiles.count)])
        }
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.spacing) {
                    ForEach(row) { t in
                        tile(t).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        )
    }
}
```

Then make a tile one accessible element: in `tileView` (line 24), add after `.background(...)` (line 46):

```swift
        .accessibilityElement(children: .combine)
```

- [ ] **Step 6: Stats pane copy and anchor.** In `Sources/Infinitus/StatsPane.swift`:
  - line 27: `Text("\(s.from) – \(s.to) · streak \(s.streak) day…")` → `Text("\(s.from) – \(s.to) · \(s.streak)-day streak")`
  - line 45–46: wrap the notes and Refresh in a titled section — replace lines 44–47 with:

```swift
            Section {
                Button("Refresh") { model.refresh() }.disabled(model.scanning)
            } header: {
                Text("Scan")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.notes, id: \.self) { Text($0) }
                }
            }
```

  - Add `.id("Stats/Period")` to the first `Section` (line 21) and `.id("Stats/Rhythm")` to `Section("Rhythm")` (line 39).
  - line 149: `Text("Nothing yet this period")` stays (Title Case already).

- [ ] **Step 7: Usage errors become sentences.** In `Sources/Infinitus/UsagePane.swift`:
  - line 64: `} catch { self.error = "\(error)" }` →

```swift
            } catch {
                Lifecycle.log.error("usage scan failed: \(String(describing: error), privacy: .public)")
                self.error = "Couldn't read the transcripts. Make sure the "
                    + "engine is installed, then choose Refresh."
            }
```

  - line 89–91: the error row keeps `.red` but gains an identity:

```swift
            if let err = model.error {
                Text(err).font(.caption).foregroundStyle(.red)
                    .accessibilityLabel("Error. \(err)")
            }
```

  - line 126: `bucketRow(extra, fallbackName: "before switch log")` → `fallbackName: "Before the switch log"`.
  - line 160: `Text("\(row.messages) msgs")` → `Text("\(row.messages) messages")`.
  - line 195: `?? "unattributed"` → `?? "Unattributed"`.
  - line 140: `Text("Scanning transcripts…")` stays.
  - line 150: add `.accessibilityElement(children: .combine)` to the `VStack` in `bucketRow`.
  - Add `.id("Usage/Estimate")` to the `Section` that begins at line 121, and wrap the top `HStack` (lines 75–88) in a section so the window picker is not a naked row:

```swift
            Section {
                HStack {
                    Picker("Window", selection: $model.days) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                    if model.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { model.refresh() }
                    }
                }
            } footer: {
                Text("Spend is estimated from your own transcripts at API "
                     + "list prices — it is not a bill.")
            }
```

- [ ] **Step 8: Search entries for the three panes.** Append at the end of each file:

`UtilizationPane.swift`:

```swift
extension UtilizationPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Utilization", section: "Forecast", label: "Forecast",
                            keywords: ["forecast", "binds", "pace", "projection", "when"]),
        SettingsSearchEntry(pane: "Utilization", section: "Run rate", label: "Run rate",
                            keywords: ["tokens per minute", "run rate", "rate", "burn", "throughput"]),
        SettingsSearchEntry(pane: "Utilization", section: "Forecast", label: "Range",
                            keywords: ["range", "24 hours", "7 days", "30 days", "history"]),
    ]
}
```

`StatsPane.swift`:

```swift
extension StatsPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Stats", section: "Period", label: "Period",
                            keywords: ["week", "month", "year", "period", "streak"], anchor: "Stats/Period"),
        SettingsSearchEntry(pane: "Stats", section: "Rhythm", label: "Rhythm",
                            keywords: ["heatmap", "hours", "session lengths", "rhythm"], anchor: "Stats/Rhythm"),
    ]
}
```

`UsagePane.swift`:

```swift
extension UsagePane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Usage", section: "Estimate", label: "Window",
                            keywords: ["7 days", "14 days", "30 days", "window"], anchor: "Usage/Estimate"),
        SettingsSearchEntry(pane: "Usage", section: "Estimate", label: "Estimated spend",
                            keywords: ["spend", "cost", "dollars", "estimate", "tokens"], anchor: "Usage/Estimate"),
    ]
}
```

- [ ] **Step 9: Verify.** `swift build --product Infinitus` → succeeds. Confirm the Throughput group's last row is one full-width tile, not an orphan beside three holes (optional screenshot, `INFINITUS_CONTROL_SOCKET=/tmp/s-shell.sock`).

- [ ] **Step 10: Commit.**

```sh
git add Sources/Infinitus/UtilizationPane.swift Sources/Infinitus/StatsTiles.swift \
        Sources/Infinitus/StatsPane.swift Sources/Infinitus/UsagePane.swift
git commit -m "settings: the dashboards say what their glyphs mean, fill their last tile row and answer errors with a next step

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Machine, Activity, Lock, About, Animations — containers, casing and the Software Update group

**Files:**
- Modify: `Sources/Infinitus/MachinePane.swift`, `ActivityPane.swift`, `LockPane.swift`, `AboutPane.swift`, `AnimationsDebugPane.swift`
- Do not touch: `AccountsPane.swift`, `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift`, `MirrorServer.swift`, `Sources/InfinitusCore/`, `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/`.

**Interfaces:**
- Produces: `searchEntries` for `MachinePane`, `ActivityPane`, `LockPane`, `AboutPane`. `AnimationsDebugPane` gets none — it only exists when the `debug_menu` default is set, and a search hit that cannot be opened is worse than no hit.
- Note: `MachinePane`'s four `confirmationDialog`s (lines 31–67) are already right and stay exactly as they are. The About hero has no animation today; do not add one to satisfy the Reduce Motion ruling — there is nothing here to gate.

- [ ] **Step 1: Read** the craft floor and the critique's P2 "Copy that should not ship" plus the minor observations about About. Then read all five files.

- [ ] **Step 2: Machine.** In `Sources/Infinitus/MachinePane.swift`:
  - `header` (lines 72–93): the caption row becomes a footer. Replace the whole computed property with:

```swift
    private var header: some View {
        Section {
            Toggle("Watch this Mac", isOn: $model.enabled)
            Toggle("Notify about hooks (new, stuck, fanned out)", isOn: $model.notifyHooks)
            Toggle("Notify about the temp directory", isOn: $model.notifyTemp)
            HStack {
                Button("Sample Now") { Task { resultMessage = nil; await model.sample() } }
                    .disabled(model.sampling)
                if model.sampling { ProgressView().controlSize(.small) }
                Spacer()
                if let at = model.lastSampledAt {
                    Text("Sampled \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let resultMessage {
                Text(resultMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Watching")
        } footer: {
            Text("Watching costs one process listing a minute and one look "
                 + "at the temp directory every five.")
        }
        .id("Machine/Watching")
    }
```

  - line 125: `Text("listing timed out")` → `Text("Listing timed out")`
  - line 142: `Text("nothing to flag")` → `Text("Nothing to flag")`
  - line 207: `Text("no hook registrations")` → `Text("No hook registrations")`
  - line 254: `Text("nothing flagged")` → `Text("Nothing flagged")`
  - line 310: `Text("no sessions")` → `Text("No sessions")`
  - line 226: `Text("managed by Claude Code")` → `Text("Managed by Claude Code")`
  - line 229: `Button("Restore")` → `Button("Restore Hooks")` (bare "Restore" beside "Disable…" reads as an undo of the last thing you did, not as "put this owner's hooks back").
  - line 232: `Button("Disable…")` stays; line 224 `Button("Kill instances…")` → `Button("Kill Instances…")`; line 264 `Button("Kill…")` stays; line 297 `Button("Reclaim…")` stays.
  - line 235: add `.accessibilityElement(children: .combine)` to `hookRow`'s outer `VStack`; same for `runawayRow`'s `VStack` (line 262) and `sessionRow`'s `HStack` (line 315).
  - Add `.id("Machine/Summary")` to `Section("Summary")` (line 99) and `.id("Machine/Sessions")` to `Section("Sessions")` (line 306).

- [ ] **Step 3: Activity.** In `Sources/Infinitus/ActivityPane.swift`, replace the body's two sections (lines 10–32) with:

```swift
        Form {
            Section {
                SwitchHistoryView(cli: model.cswap, names: accountNames)
            } header: {
                Text("Switch history")
            } footer: {
                Text("Every account change Infinitus made, newest first.")
            }
            .id("Activity/Switch history")
            Section {
                if model.eventLog.isEmpty {
                    Text("No events yet this session").foregroundStyle(.secondary)
                } else {
                    ForEach(model.eventLog.suffix(30).reversed()) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.icon)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(entry.text)
                            Spacer()
                            Text(entry.at, format: .dateTime.hour().minute())
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Engine events")
            } footer: {
                Text("The last thirty events since this launch; the list "
                     + "starts fresh each time Infinitus opens.")
            }
            .id("Activity/Engine events")
        }
        .formStyle(.grouped)
```

- [ ] **Step 4: Lock.** In `Sources/Infinitus/LockPane.swift`, replace the `Form` (lines 21–46) with:

```swift
        Form {
            Section {
                Toggle("Unlock with \(BiometricLock.methodName)",
                       isOn: Binding(get: { lock.enabled }, set: toggle))
                    .disabled(busy)
                Picker("Re-lock", selection: Binding(get: { lock.relock }, set: { lock.relock = $0 })) {
                    ForEach(LockPolicy.Relock.allCases, id: \.self) {
                        Text(Self.relockLabels[$0] ?? $0.label).tag($0)
                    }
                }
                .disabled(!lock.enabled)
                if lock.enabled {
                    Button("Lock Now") { lock.lockNow() }
                }
                if let err = lock.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                        .accessibilityLabel("Error. \(err)")
                }
            } header: {
                Text("Unlocking")
            } footer: {
                Text("The pop-out and this window show a locked state until "
                     + "you unlock; biometrics fall back to your password, as "
                     + "the system does. A timed re-lock settles on your next "
                     + "interaction or when the Mac wakes — nothing ticks "
                     + "while the Mac is idle. Teams need this on: creating a "
                     + "team, accepting an invite and requesting to join stay "
                     + "unavailable until it is.")
            }
            .id("Lock/Unlocking")
        }
        .formStyle(.grouped)
```

The `confirmationDialog` below (lines 48–57) is unchanged — "Turn Off" / "Keep On" are commands and are correctly Title Case.

- [ ] **Step 5: About — Software Update becomes its own group, and the notification wording stops leaking a tool name.** In `Sources/Infinitus/AboutPane.swift`, replace lines 401–461 (`Section("Updates")` and `Section("Notifications")`) with:

```swift
            Section {
                LabeledContent {
                    HStack {
                        if appRelease.updateAvailable, BrewUpdater.channel == .stable {
                            Button("Update via Homebrew") { brew.upgrade() }
                                .disabled(brew.running)
                                .buttonStyle(.borderedProminent)
                        } else if BrewUpdater.channel == .nightly {
                            Button("Reinstall the Latest Nightly") { brew.upgrade() }
                                .disabled(brew.running)
                        }
                        Button(appRelease.status == nil ? "Check for Updates…" : "Check Again") {
                            Task { await appRelease.check() }
                        }
                    }
                } label: {
                    Text("Infinitus \(appVersion) · \(brew.channelLabel)")
                    if let s = brew.status ?? appRelease.status {
                        Text(s).font(.caption)
                            .foregroundStyle(appRelease.updateAvailable ? Color.orange : .secondary)
                    }
                }
                Picker("Channel", selection: $updateChannel) {
                    Text("Stable").tag("stable")
                    Text("Nightly").tag("nightly")
                }
                .pickerStyle(.segmented)
                .onChange(of: updateChannel) { Task { await appRelease.check() } }
                if BrewUpdater.channel == .stable, updateChannel == "nightly" {
                    Button("Switch the Install to Nightly") {
                        brew.move(toNightly: true)
                    }
                    .disabled(brew.running)
                } else if BrewUpdater.channel == .nightly, updateChannel == "stable" {
                    Button("Switch the Install Back to Stable") {
                        brew.move(toNightly: false)
                    }
                    .disabled(brew.running)
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text("A Homebrew install updates through Homebrew — Infinitus "
                     + "never replaces itself. Builds from source and zip "
                     + "installs get the release check only.")
            }
            .id("About/Software Update")

            Section {
                LabeledContent("Delivery") {
                    Text(Notifier.lastAuthError == nil
                         ? "Notification Center"
                         : "Scripted (Notification Center unavailable)")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(Notifier.lastAuthError == nil
                     ? "Alerts arrive as system notifications, so Notification "
                       + "Center's own settings decide how they look."
                     : "Notification Center turned this build down, so alerts "
                       + "are delivered as scripted pop-ups instead — they "
                       + "still arrive. A Developer ID signature, or one Xcode "
                       + "run with automatic signing, restores system "
                       + "notifications.")
            }
            .id("About/Notifications")
```

Three things this changes and why: "(CodexBar does the same)" is gone (a competitor's name in About); the raw `Notifier.lastAuthError` string no longer renders (it was a debug string in a user-facing row — the footer says the same thing in a sentence, and the raw value is still available in the log); "osascript fallback" becomes "Scripted (Notification Center unavailable)", which names the state rather than the tool.

- [ ] **Step 6: About's remaining rows.** Same file:
  - line 463: `Section("Links")` → add `.id("About/Links")` after its closing brace.
  - `linkRow` (line 536): add, after `.buttonStyle(.plain)` (line 551):

```swift
        .accessibilityAddTraits(.isLink)
        .accessibilityHint("Opens in your browser.")
```

  - line 472: `Text("Infinitus by deathemperor · MIT License")` stays.

- [ ] **Step 7: Animations (debug pane).** In `Sources/Infinitus/AnimationsDebugPane.swift`:
  - lines 20–27: the first section's caption becomes a footer:

```swift
            Section {
                Button("Open Playground") {
                    Playground.show(usage: usage)
                }
            } footer: {
                Text("A resizable window with the self-contained demos — "
                     + "burn styles side by side, the drop, refills — at a "
                     + "size you can actually see.")
            }
```

  - lines 29–62: the Launch intro section becomes:

```swift
            Section {
                Picker("Content entrance", selection: $model.introStyle) {
                    Text("Slide from top").tag("top")
                    Text("Slide from bottom").tag("bottom")
                    Text("Fade in").tag("fade")
                    Text("Rows slide from right").tag("rows")
                }
                Picker("Title flourish", selection: $model.introTitle) {
                    Text("Zoom bounce").tag("zoom")
                    Text("Stamp slam").tag("slam")
                    Text("Spin up").tag("spin")
                    Text("Off").tag("off")
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $model.introSpeed, in: 0.4...2)
                            .frame(width: 180)
                        Text(String(format: "%.1fx", model.introSpeed))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Replay Intro") { model.replayIntro() }
                    Button("Restart App") { model.relaunchApp() }
                }
            } header: {
                Text("Launch intro")
            } footer: {
                Text("Open the popup, then Replay to audition; Restart runs "
                     + "the real thing — controls slide in from their sides, "
                     + "content enters per the picker, bars fill up with the "
                     + "active-row flash, and the title lands with the chosen "
                     + "flourish.")
            }
```

  - Leave every other section of this debug pane alone (the "Live popup" section and everything below it keep their caption rows: this pane only exists behind the `debug_menu` default and is not part of the shipped surface).

- [ ] **Step 8: Search entries.** Append at the end of the respective files:

```swift
extension MachinePane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Machine", section: "Watching", label: "Watch this Mac",
                            keywords: ["watch", "health", "monitor", "guardian"], anchor: "Machine/Watching"),
        SettingsSearchEntry(pane: "Machine", section: "Watching", label: "Notify about hooks (new, stuck, fanned out)",
                            keywords: ["hooks", "notify", "stuck", "runaway"], anchor: "Machine/Watching"),
        SettingsSearchEntry(pane: "Machine", section: "Watching", label: "Notify about the temp directory",
                            keywords: ["temp", "residue", "disk"], anchor: "Machine/Watching"),
        SettingsSearchEntry(pane: "Machine", section: "Sessions", label: "Notify when a session is idle",
                            keywords: ["idle", "sessions", "hours"], anchor: "Machine/Sessions"),
    ]
}
```

```swift
extension ActivityPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Activity", section: "Switch history", label: "Switch history",
                            keywords: ["switches", "history", "log"], anchor: "Activity/Switch history"),
        SettingsSearchEntry(pane: "Activity", section: "Engine events", label: "Engine events",
                            keywords: ["events", "log", "engine"], anchor: "Activity/Engine events"),
    ]
}
```

```swift
extension LockPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: LockModel.paneTitle, section: "Unlocking",
                            label: "Unlock with \(BiometricLock.methodName)",
                            keywords: ["biometric", "touch id", "face id", "password", "unlock", "privacy"],
                            anchor: "Lock/Unlocking"),
        SettingsSearchEntry(pane: LockModel.paneTitle, section: "Unlocking", label: "Re-lock",
                            keywords: ["re-lock", "relock", "timeout", "sleep"], anchor: "Lock/Unlocking"),
    ]
}
```

```swift
extension AboutPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "About", section: "Software Update", label: "Channel",
                            keywords: ["update", "channel", "stable", "nightly", "homebrew", "upgrade"],
                            anchor: "About/Software Update"),
        SettingsSearchEntry(pane: "About", section: "Notifications", label: "Delivery",
                            keywords: ["notification", "delivery", "banner", "alerts"],
                            anchor: "About/Notifications"),
        SettingsSearchEntry(pane: "About", section: "Links", label: "Links",
                            keywords: ["github", "website", "project", "license", "version"],
                            anchor: "About/Links"),
    ]
}
```

- [ ] **Step 9: Verify.** `swift build --product Infinitus` → succeeds. `grep -rn '"\\(error)"' Sources/Infinitus/MachinePane.swift Sources/Infinitus/LockPane.swift Sources/Infinitus/AboutPane.swift Sources/Infinitus/ActivityPane.swift` → no hits. `grep -rn 'CodexBar\|osascript' Sources/Infinitus/AboutPane.swift` → no hits.

- [ ] **Step 10: Commit.**

```sh
git add Sources/Infinitus/MachinePane.swift Sources/Infinitus/ActivityPane.swift \
        Sources/Infinitus/LockPane.swift Sources/Infinitus/AboutPane.swift \
        Sources/Infinitus/AnimationsDebugPane.swift
git commit -m "settings: Software Update is its own group, statuses are Title Case, and no pane names a tool at the user

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The sidebar is a real List, grouped, and the window is called Settings

**Files:**
- Create: `Sources/Infinitus/SettingsSidebar.swift`
- Modify: `Sources/Infinitus/InfinitusApp.swift` (`SettingsRoot`, lines 308–476)
- Modify: `Sources/Infinitus/StatusItemController.swift` (inside `showSettingsWindow()` only: line 641 and two added lines near 655)
- Do not touch: `struct SettingsTab` (StatusItemController.swift:20–34) and everything else in that file; `AccountsPane.swift`, `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift`, `MirrorServer.swift`, `Sources/InfinitusCore/`, `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/`.

**Interfaces:**
- Produces:

```swift
enum SettingsGroup: String, CaseIterable, Identifiable { case general, accounts, dashboards, engines, app }
extension SettingsGroup { static func of(_ tab: SettingsTab) -> SettingsGroup; var title: String?; var contentWidth: CGFloat }
struct SettingsSidebar: View { let tabs: [SettingsTab]; @Binding var selection: String? ; … }
```

- Keeps working, byte-identically: the `infinitus.selectPane` notification (`InfinitusApp.swift:348–355`), posted by `AppModel.swift:2448`, `LockModel.swift:127`, `TeamModel.swift:660` and `PlaygroundWindow.swift:133` with a pane TITLE as the object. Selection by title must keep selecting that pane.
- This task keeps the existing title+keyword `filtered` for the search field. Task 7 replaces it with the index. Do not build the index here.

- [ ] **Step 1: Read** the craft floor and the critique's P0 "The Mac app has no accessibility labels and no keyboard path" and P1 "The shell". Then read `SettingsRoot` (`InfinitusApp.swift:308–476`) in full, including the doc comment above it — it records the 2026-08-30 `NavigationSplitView` freeze. The ruling for this round: a plain `List(selection:)` inside the existing `HStack` is not a `NavigationSplitView` and does not take the split view's selection→detail hop, so it is allowed and required. Update that comment as part of Step 4.

- [ ] **Step 2: The groups and the sidebar.** New file `Sources/Infinitus/SettingsSidebar.swift`:

```swift
import SwiftUI
import InfinitusCore

/// How the sidebar's destinations are grouped. System Settings puts a
/// header over every run of related panes; ours were eighteen flat rows
/// ordered by how often each was reached (critique P1: "a frequency
/// list, not an information architecture").
///
/// The group is derived from the pane's title rather than stored on
/// `SettingsTab` — that type lives in StatusItemController.swift and is
/// shared with the settings scene; nothing about grouping belongs there.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case general = "General"
    case accounts = "Accounts"
    case dashboards = "Dashboards"
    case engines = "Engines"
    /// About and the debug Animations pane: last, and under no header —
    /// a header of one word over the app's own two rows adds nothing.
    case app = ""

    var id: String { rawValue }
    var title: String? { rawValue.isEmpty ? nil : rawValue }

    /// How wide the pane's content is allowed to get. A grouped Form
    /// self-limits around 700pt and looked marooned in a 1800pt window;
    /// the dashboards are tables and charts and earn more (critique P1).
    var contentWidth: CGFloat { self == .dashboards ? 1100 : 760 }

    static func of(_ tab: SettingsTab) -> SettingsGroup {
        if tab.provider != nil { return .engines }
        switch tab.title {
        case "Accounts", TeamModel.paneTitle: return .accounts
        case "Usage", "Utilization", "Stats", "Machine", "Activity": return .dashboards
        case "About", "Animations": return .app
        default: return .general
        }
    }
}

/// The Settings sidebar: a real `List(selection:)`, which is where the
/// arrow keys, type-select, the focus ring and the accessibility rows
/// come from (critique P0 — every row used to announce as "button").
/// A plain List inside our own HStack is NOT the NavigationSplitView
/// whose selection→detail hop froze under synthetic clicks in 2026-08-30.
struct SettingsSidebar: View {
    let tabs: [SettingsTab]
    /// Search hits, grouped by pane; empty while not searching.
    let results: [(pane: String, entries: [SettingsSearchEntry])]
    let searching: Bool
    let query: String
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if searching {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(results, id: \.pane) { group in
                        Section(group.pane) {
                            ForEach(group.entries) { entry in
                                resultRow(entry)
                            }
                        }
                    }
                }
            } else {
                ForEach(SettingsGroup.allCases) { group in
                    let rows = tabs.filter { SettingsGroup.of($0) == group }
                    if !rows.isEmpty {
                        if let title = group.title {
                            Section {
                                ForEach(rows, id: \.title) { row($0) }
                            } header: {
                                header(title, rows: rows)
                            }
                        } else {
                            Section {
                                ForEach(rows, id: \.title) { row($0) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// "Engines · 2 on" — the live count the old hand-rolled header
    /// carried, kept where it was.
    @ViewBuilder private func header(_ title: String, rows: [SettingsTab]) -> some View {
        let live = rows.filter { $0.provider?.live == true }.count
        HStack {
            Text(title)
            if rows.contains(where: { $0.provider != nil }) {
                Spacer()
                Text("\(live) on")
            }
        }
    }

    @ViewBuilder private func row(_ tab: SettingsTab) -> some View {
        if tab.provider == nil {
            Label {
                Text(tab.title)
            } icon: {
                tile(tab)
            }
            .accessibilityLabel(tab.title)
            .tag(tab.title)
        } else {
            let badge = tab.provider ?? ProviderBadge()
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .frame(width: 18)
                Text(tab.title)
                Spacer()
                if badge.live {
                    Circle().fill(.green).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(badge.placeholder ? AnyShapeStyle(.tertiary)
                                               : AnyShapeStyle(.primary))
            .accessibilityLabel(badge.placeholder
                                ? "\(tab.title), not available yet"
                                : "\(tab.title), \(badge.live ? "running" : "not running")")
            // selectionDisabled, not .disabled: a disabled row still
            // takes keyboard focus and then does nothing.
            .selectionDisabled(badge.placeholder)
            .tag(tab.title)
        }
    }

    @ViewBuilder private func tile(_ tab: SettingsTab) -> some View {
        if let image = tab.image {
            Image(nsImage: image)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: tab.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(tab.tint.gradient))
        }
    }

    @ViewBuilder private func resultRow(_ entry: SettingsSearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.label)
            if let section = entry.section {
                Text(section).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.section.map { "\(entry.label), in \($0)" } ?? entry.label)
        .tag(entry.id)
    }
}
```

Note: `results` and `SettingsSearchEntry` are used here already so Task 7 has nothing to restructure; this task always passes `searching: false` and `results: []`.

- [ ] **Step 3: The window names itself.** Add to the bottom of `Sources/Infinitus/SettingsSidebar.swift`:

```swift
/// Sets the enclosing window's title and subtitle from SwiftUI. The
/// window is created by StatusItemController, which cannot see which
/// pane is showing; System Settings titles by pane and so do we
/// (critique P1: "the window is titled Infinitus, never Settings").
struct WindowTitler: NSViewRepresentable {
    let title: String
    let subtitle: String

    final class Titled: NSView {
        var apply: (NSWindow) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { apply(window) }
        }
    }

    func makeNSView(context: Context) -> Titled { Titled(frame: .zero) }

    func updateNSView(_ view: Titled, context: Context) {
        let title = title, subtitle = subtitle
        // viewDidMoveToWindow covers the first pass, where the view has
        // no window yet; updateNSView covers every pane change after.
        view.apply = { window in
            window.title = title
            window.subtitle = subtitle
        }
        if let window = view.window { view.apply(window) }
    }
}
```

- [ ] **Step 4: `SettingsRoot` uses them.** In `Sources/Infinitus/InfinitusApp.swift`, replace the doc comment and the struct (lines 302–476, from `/// CodexBar-style settings shell:` through the closing brace of `providerRow`) with:

```swift
/// The settings shell: a searchable, grouped sidebar on the left and
/// the selected pane on the right. The sidebar is a `List(selection:)`
/// (arrow keys, type-select, focus ring and accessible rows, all free)
/// inside our own HStack — NOT a NavigationSplitView, whose
/// List-selection → detail hop froze under synthetic clicks
/// (2026-08-30). The plain-Button sidebar that replaced it back then
/// had none of those affordances and announced every row as "button"
/// (design critique 2026-09-06, P0); a bare List does not take the
/// split view's hop and restores them.
struct SettingsRoot: View {
    let tabs: [SettingsTab]
    @State private var selection: String?
    /// The pane actually on screen. Usually the selection; a search hit
    /// selects a ROW and opens the pane that row lives on.
    @State private var pane: String?
    @State private var query = ""

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var current: SettingsTab? {
        tabs.first { $0.title == pane } ?? tabs.first
    }
    private var group: SettingsGroup {
        current.map { SettingsGroup.of($0) } ?? .general
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.top, 14)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                SettingsSidebar(tabs: tabs, results: [], searching: false,
                                query: query, selection: $selection)
            }
            .frame(width: 215)
            Divider()
            Group {
                if let tab = current {
                    tab.view
                        .frame(maxWidth: group.contentWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 480, idealHeight: 640)
        .background(WindowTitler(title: "Settings", subtitle: current?.title ?? ""))
        .onAppear {
            if selection == nil {
                selection = tabs.first?.title
                pane = tabs.first?.title
            }
        }
        .onChange(of: selection) { _, new in
            if let new, tabs.contains(where: { $0.title == new }) { pane = new }
        }
        // Dev harness: `playctl settings <Title>` lands on a named pane
        // (pane screenshots without synthetic sidebar clicks).
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("infinitus.selectPane"))) { note in
            if let title = note.object as? String,
               tabs.contains(where: { $0.title == title }) {
                query = ""
                selection = title
                pane = title
            }
        }
        .reloadOnInjection()
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.secondary.opacity(0.25)))
    }
}
```

Everything the old `generalRow` / `providerRow` did now lives in `SettingsSidebar`; delete both functions with the struct. The hard-coded 11pt/12pt font sizes go with them (critique's minor observation) — `.caption` and `.callout` are the text styles that match them.

- [ ] **Step 5: The window is titled and capped.** In `Sources/Infinitus/StatusItemController.swift`, inside `showSettingsWindow()`:
  - line 641: `w.title = "Infinitus"` → `w.title = "Settings"` (the pane name arrives as the subtitle from `WindowTitler`).
  - after line 640 (`w.contentMinSize = …`) add:

```swift
            // System Settings is not freely widenable, and for the same
            // reason: a grouped Form self-limits to ~700pt, so every
            // extra pixel of window became empty grey (design critique
            // 2026-09-06, P1 — a 700pt column in an 1800pt window).
            w.contentMaxSize = NSSize(width: 1200, height: .greatestFiniteMagnitude)
```

  - after line 655 (`w.setFrameAutosaveName("InfinitusSettings")`) add:

```swift
            // An autosaved frame from before the cap is restored as-is.
            if w.frame.width > 1200 {
                w.setContentSize(NSSize(width: 1200, height: w.contentLayoutRect.height))
            }
```

- [ ] **Step 6: Verify.** `swift build --product Infinitus` → succeeds. Then, in a dev instance (`INFINITUS_CONTROL_SOCKET=/tmp/s-shell.sock`), confirm by hand:
  - the sidebar shows General / Accounts / Dashboards / Engines and then About (+ Animations with the debug default set);
  - ↑/↓ move the selection and the pane follows; typing "th" jumps to Themes; the focused row has a focus ring;
  - the title bar reads "Settings" with the pane name under it;
  - dragging the window wider stops at 1200pt;
  - `infinitusctl` (or the popup's Settings… button) still lands on a named pane — the `infinitus.selectPane` path is unchanged.

- [ ] **Step 7: Commit.**

```sh
git add Sources/Infinitus/SettingsSidebar.swift Sources/Infinitus/InfinitusApp.swift \
        Sources/Infinitus/StatusItemController.swift
git commit -m "settings: a real grouped sidebar with arrow keys and VoiceOver rows, in a window that says Settings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Search that finds settings, opens the pane and flashes the row

**Files:**
- Create: `Sources/Infinitus/SettingsSearch.swift`
- Modify: `Sources/Infinitus/InfinitusApp.swift` (`SettingsRoot` only)
- Modify: `Sources/Infinitus/DisplayPane.swift`, `ThemesPane.swift`, `UtilizationPane.swift`, `StatsPane.swift`, `UsagePane.swift`, `MachinePane.swift`, `ActivityPane.swift`, `LockPane.swift`, `AboutPane.swift` — ONLY to swap each Section's `.id("…")` for `.settingsAnchor("…")`
- Do not touch: `AccountsPane.swift`, `NotifyPane.swift`, `ProfilesPane.swift`, `SyncPane.swift`, `EnginesPane.swift`, `SettingsPane.swift`, `AppModel.swift`, `Sources/Infinitus/Team*.swift`, `MirrorServer.swift`, `StatusItemController.swift`, `Sources/InfinitusCore/`, `ios/`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusUI/`.

**Interfaces:**
- Produces:

```swift
enum SettingsSearchCatalog { static func index(tabs: [SettingsTab]) -> SettingsSearchIndex }
extension EnvironmentValues { var settingsHighlight: String? }
extension View { func settingsAnchor(_ id: String) -> some View }
```

- Consumes: every pane's `static let searchEntries` from Tasks 2–5, and `SettingsSearchIndex` from Task 1.

- [ ] **Step 1: Read** the craft floor, then `Sources/InfinitusCore/SettingsSearchIndex.swift` and the current `SettingsRoot`.

- [ ] **Step 2: The catalogue, the environment value and the anchor.** New file `Sources/Infinitus/SettingsSearch.swift`:

```swift
import SwiftUI
import InfinitusCore

/// Everything Settings search can find. Panes this app owns publish
/// their own rows as `searchEntries`; every pane, owned or not, also
/// contributes its title and the keywords already declared on its
/// `SettingsTab`, so nothing becomes unfindable while the other panes
/// catch up (add one `case` below when they do).
enum SettingsSearchCatalog {
    @MainActor
    static func index(tabs: [SettingsTab]) -> SettingsSearchIndex {
        var entries: [SettingsSearchEntry] = []
        for tab in tabs {
            // The pane itself is always findable by name.
            entries.append(SettingsSearchEntry(pane: tab.title, label: tab.title,
                                               keywords: tab.keywords,
                                               anchor: "\(tab.title)/"))
            entries.append(contentsOf: rows(of: tab.title))
        }
        return SettingsSearchIndex(entries)
    }

    private static func rows(of pane: String) -> [SettingsSearchEntry] {
        switch pane {
        case "Display": return DisplayPane.searchEntries
        case "Themes": return ThemesPane.searchEntries
        case "Usage": return UsagePane.searchEntries
        case "Utilization": return UtilizationPane.searchEntries
        case "Stats": return StatsPane.searchEntries
        case "Machine": return MachinePane.searchEntries
        case "Activity": return ActivityPane.searchEntries
        case LockModel.paneTitle: return LockPane.searchEntries
        case "About": return AboutPane.searchEntries
        // Accounts, Push, Profiles, Devices, Team and the engine panes
        // carry their title and keywords only, until they publish their
        // own searchEntries.
        default: return []
        }
    }
}

/// The section a search hit asked for. A pane's Section reads it and
/// flashes once when it is the one; nothing else in the app reads it.
private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

extension View {
    /// Marks a Section as a search destination: `scrollTo` can find it
    /// by this id, and it flashes once when a search hit points at it.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchor(anchor: id))
    }
}

private struct SettingsAnchor: ViewModifier {
    let anchor: String
    @Environment(\.settingsHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lit: Bool { highlight == anchor }

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(lit ? 0.18 : 0))
            )
            // One shot, ~0.35s, cleared by the caller after 1.2s: no
            // repeatForever, no TimelineView, nothing ticking (repo
            // rule — idle CPU stays ~0%).
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: lit)
    }
}
```

- [ ] **Step 3: Swap `.id` for `.settingsAnchor` in every pane touched in Tasks 2–5.** Mechanical, one per section:

| File | `.id("…")` → `.settingsAnchor("…")` |
|---|---|
| `DisplayPane.swift` | `Display/Menu bar`, `Display/Popup`, `Display/Fleet wall`, `Display/Sessions`, `Display/Startup` |
| `ThemesPane.swift` | `Themes/Built-in`, `Themes/Your themes`, `Themes/Community` |
| `UtilizationPane.swift` | `Utilization/Forecast`, `Utilization/Run rate` |
| `StatsPane.swift` | `Stats/Period`, `Stats/Rhythm` |
| `UsagePane.swift` | `Usage/Estimate` |
| `MachinePane.swift` | `Machine/Watching`, `Machine/Summary`, `Machine/Sessions` |
| `ActivityPane.swift` | `Activity/Switch history`, `Activity/Engine events` |
| `LockPane.swift` | `Lock/Unlocking` |
| `AboutPane.swift` | `About/Software Update`, `About/Notifications`, `About/Links` |

When the step is done, this must come back empty — the nine files this stream owns, named one by one (never `*Pane.swift`: `AccountsPane`, `SyncPane` and the others belong to another stream and use `.id()` for their own list rows):

```sh
grep -rn '\.id("' Sources/Infinitus/DisplayPane.swift Sources/Infinitus/ThemesPane.swift \
    Sources/Infinitus/UtilizationPane.swift Sources/Infinitus/StatsPane.swift \
    Sources/Infinitus/UsagePane.swift Sources/Infinitus/MachinePane.swift \
    Sources/Infinitus/ActivityPane.swift Sources/Infinitus/LockPane.swift \
    Sources/Infinitus/AboutPane.swift
```

The `Display/Fleet wall` anchor is on the `WallSection(model:)` call inside `DisplayPane`, not in `WallWindow.swift`.

- [ ] **Step 4: `SettingsRoot` drives it.** In `Sources/Infinitus/InfinitusApp.swift`, replace the `SettingsRoot` written in Task 6 with:

```swift
struct SettingsRoot: View {
    let tabs: [SettingsTab]
    @State private var selection: String?
    @State private var pane: String?
    @State private var query = ""
    @State private var highlight: String?
    @State private var clearHighlight: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var index: SettingsSearchIndex { SettingsSearchCatalog.index(tabs: tabs) }
    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var results: [(pane: String, entries: [SettingsSearchEntry])] {
        searching ? index.grouped(query) : []
    }
    private var current: SettingsTab? {
        tabs.first { $0.title == pane } ?? tabs.first
    }
    private var group: SettingsGroup {
        current.map { SettingsGroup.of($0) } ?? .general
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.top, 14)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                SettingsSidebar(tabs: tabs, results: results,
                                searching: searching, query: query,
                                selection: $selection)
            }
            .frame(width: 215)
            Divider()
            detail
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 480, idealHeight: 640)
        .background(WindowTitler(title: "Settings", subtitle: current?.title ?? ""))
        // ⌘F puts the caret in the field; an accessory app has no menu
        // bar to hang the standard Find item off (critique: Alex "has
        // no ⌘F").
        .overlay {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            if selection == nil {
                selection = tabs.first?.title
                pane = tabs.first?.title
            }
        }
        .onChange(of: selection) { _, new in select(new) }
        .onChange(of: query) { _, _ in retargetForQuery() }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("infinitus.selectPane"))) { note in
            if let title = note.object as? String,
               tabs.contains(where: { $0.title == title }) {
                query = ""
                highlight = nil
                selection = title
                pane = title
            }
        }
        .reloadOnInjection()
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        ScrollViewReader { proxy in
            Group {
                if searching, results.isEmpty {
                    // Nothing stale left on screen: the old shell blanked
                    // the sidebar and kept the previous pane showing with
                    // nothing selected (critique P1).
                    ContentUnavailableView.search(text: query)
                } else if let tab = current {
                    tab.view
                        .frame(maxWidth: group.contentWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.settingsHighlight, highlight)
            .onChange(of: highlight) { _, anchor in
                guard let anchor else { return }
                // The pane has to render before its sections have ids.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if reduceMotion {
                        proxy.scrollTo(anchor, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(anchor, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: search field

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
            if searching {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.secondary.opacity(0.25)))
    }

    // MARK: selection

    /// A sidebar selection is either a pane title or a search hit's id.
    private func select(_ id: String?) {
        guard let id else { return }
        if tabs.contains(where: { $0.title == id }) {
            pane = id
            flash(nil)
        } else if let hit = index.entry(id: id) {
            pane = hit.pane
            flash(hit.anchor)
        }
    }

    /// Keeps the detail honest while the query changes: the selected
    /// pane stays if it still has hits, otherwise the first hit wins.
    private func retargetForQuery() {
        // Clearing the field: the sidebar goes back to pane rows, so a
        // selection still holding a search hit's id would highlight
        // nothing. Hand it back the pane that is showing.
        guard searching else { flash(nil); selection = pane; return }
        let groups = results
        guard !groups.isEmpty else { return }
        if let pane, groups.contains(where: { $0.pane == pane }) { return }
        if let first = groups.first?.entries.first {
            selection = first.id
        }
    }

    private func flash(_ anchor: String?) {
        clearHighlight?.cancel()
        highlight = anchor
        guard anchor != nil else { return }
        clearHighlight = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            highlight = nil
        }
    }
}
```

Two things to keep straight while implementing:
- `index` is rebuilt per access; the entry lists are `static let`s and the loop is over ~20 tabs, so this is a few hundred string copies on a keystroke and never on a timer. Do not cache it in `@State` — `tabs` is captured once per window and a stale cache would outlive a theme rename of the Lock/Team pane titles.
- The highlight is the primary affordance; `scrollTo` is best-effort. If a pane's section is already on screen, nothing scrolls and the flash still says which group answered.

- [ ] **Step 5: Verify by hand.** `swift build --product Infinitus` → succeeds. Then in a dev instance (`INFINITUS_CONTROL_SOCKET=/tmp/s-shell.sock`):
  - type "transparency" → the sidebar shows "Display ▸ Transparency"; select it → Display opens, scrolls to Popup, and the group flashes once and settles;
  - the three queries the old field could not answer — "keep awake", "start at login", "checkpoint" — all return rows;
  - "zzz" → the sidebar shows "No Results" and so does the detail (nothing stale);
  - the ✕ clears the field and the focus stays in it; ⌘F focuses it from anywhere in the window;
  - System Settings › Accessibility › Display › Reduce Motion on: the flash appears without animating and the scroll is instant.

- [ ] **Step 6: Commit.**

```sh
git add Sources/Infinitus/SettingsSearch.swift Sources/Infinitus/InfinitusApp.swift \
        Sources/Infinitus/DisplayPane.swift Sources/Infinitus/ThemesPane.swift \
        Sources/Infinitus/UtilizationPane.swift Sources/Infinitus/StatsPane.swift \
        Sources/Infinitus/UsagePane.swift Sources/Infinitus/MachinePane.swift \
        Sources/Infinitus/ActivityPane.swift Sources/Infinitus/LockPane.swift \
        Sources/Infinitus/AboutPane.swift
git commit -m "settings: search finds a setting by its own label, opens its pane and flashes the group it lives in

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: CHANGELOG and the full gate (last task)

**Files:**
- Modify: `CHANGELOG.md` (under `## 0.4.4 (unreleased)` → `### Mac`, line 30)
- Do not touch: everything in the forbidden list above, `site/`, `README.md`.

- [ ] **Step 1: The lines.** Insert at the TOP of the `### Mac` list (right after the `### Mac` header on line 30, before the existing "Machine: the pip retry-loop warning…" line), one short sentence each:

```
- Settings' sidebar is a real list: arrow keys, type-select, a focus ring and VoiceOver names, grouped into General, Accounts, Dashboards and Engines.
- Settings search finds a setting by its own label, opens its pane and flashes the group it lives in; ⌘F jumps to the field.
- The Settings window is called Settings and says which pane you're in.
- Display is five named groups — Menu bar, Popup, Fleet wall, Sessions, Startup — each with a footer that says what the setting costs.
- The popup's headroom sorting moved to Settings › Display, where the rest of the popup's appearance lives.
- Theme cards show the whole theme instead of hiding half of it in a sideways scroller, and name two accounts the way that theme would.
- Utilization says what its gauge glyphs mean, and its run-rate methodology moved under "How this is measured".
- The Stats tiles fill their last row instead of stranding one tile beside three empty cells.
- About has its own Software Update group, and says "Scripted (Notification Center unavailable)" instead of naming the tool it fell back to.
```

- [ ] **Step 2: The full gate**, in this order, each from the worktree root:

```sh
swift test
swift build --product Infinitus
```

Both must succeed. (`swift build` takes ONE `--product` per invocation — with two flags SwiftPM builds only the last.) `tools/e2e.sh` belongs to another round and was never touched by this stream.

- [ ] **Step 3: A last read-through against the rules**, all from the worktree root, all expected to come back empty:

```sh
grep -rn '"\\(error)"' Sources/Infinitus/DisplayPane.swift Sources/Infinitus/ThemesPane.swift \
    Sources/Infinitus/UsagePane.swift Sources/Infinitus/UtilizationPane.swift \
    Sources/Infinitus/StatsPane.swift Sources/Infinitus/MachinePane.swift \
    Sources/Infinitus/ActivityPane.swift Sources/Infinitus/LockPane.swift \
    Sources/Infinitus/AboutPane.swift
grep -rn 'CodexBar\|osascript\|PR #' Sources/Infinitus/AboutPane.swift Sources/Infinitus/DisplayPane.swift
grep -rn '\.help(' Sources/Infinitus/DisplayPane.swift Sources/Infinitus/LockPane.swift
grep -rn '\.\.\.' Sources/Infinitus/AboutPane.swift Sources/Infinitus/MachinePane.swift
```

- [ ] **Step 4: Commit.**

```sh
git add CHANGELOG.md
git commit -m "changelog: the Settings shell, Display, Themes and dashboard polish (0.4.4)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
