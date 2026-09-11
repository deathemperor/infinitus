# Settings polish — the iPhone's Settings tab (stream `settings-phone`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone's Settings tab reaches Apple's level: every chooser SHOWS what it is choosing (thirteen-plus live theme rows, a tile per pace-fire / entrance / flourish option), the Mac connection leads the screen instead of cosmetics, the fleet's bearer token stops being readable over a shoulder, forgetting a Mac asks first, every explanation is a `Section(footer:)` instead of a caption row inside the group, updating the Mac reports progress and fails in a sentence with a next step, and the chat header scales with the reader's text size.

**Architecture:** `SettingsForm` (ios/InfinitusMobile/SettingsScreen.swift) stays one `Form`, re-ordered so the transport is first and the cosmetics follow, with one `Section(header:footer:)` per idea and no caption rows inside groups. Three new files hold the choosers: `ThemeSwatch.swift` (the four-colour chip the Theme row wears), `ThemeChooserScreen.swift` (a pushed `List` whose every row IS a theme preview — gauges, spend line, tab-bar mock, status word, name pool — plus the widened `ThemePreviewRow`), and `MotionChooser.swift` (one generic pushed chooser shell plus a pace-fire tile drawn by the real `GaugeBar` and two one-shot motion tiles). Nothing new is added to `InfinitusCore` or `InfinitusUI`: every field the previews read (`accountNames`, `cashIcon`, `creditLabel`, `scopedPrefix`, `modelName`, `sessionWord`, `tabLabel`, `tabIcon`) is already `public` on `RowTheme`, and `GaugeBar` / `ThemeColor` / `PopupGlyph` / `PopupFont` / `InfinitusGlyph` are already `public` in `InfinitusUI`.

**Tech Stack:** Swift 6 compiler in Swift 5 language mode (`swift-tools-version: 5.9`), SwiftUI on iOS 17 (deployment target in `ios/project.yml`), `InfinitusCore` + `InfinitusUI` as local SwiftPM products, XcodeGen for the (untracked) project file.

**Spec:** `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` — the design critique this plan implements; its iOS twin `.impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md` carries the same body under the iOS target's frontmatter. Task 1 copies both into this worktree so every later task can read them. The iOS-relevant parts are the "iOS Settings tab" score table, priority issues **[P0] The iOS theme chooser hides what is being chosen**, **[P1] Confirmation is inverted, and a credential is in the clear**, **[P2] Explanations live in three containers**, and the minor observations about endpoint rows and hard-coded font sizes.

## Global Constraints

- **File ownership (three streams in parallel, all merging into `main`).**
  - This stream MAY edit:
    - `ios/InfinitusMobile/SettingsScreen.swift`
    - `ios/InfinitusMobile/ChatHeader.swift` — ONLY the hard-coded font sizes and the two fixed frames they drive (`portraitSize`, the HUD bar height, the plan-tier disc); nothing about data, routing or effects.
    - New files under `ios/InfinitusMobile/`: `ThemeSwatch.swift`, `ThemeChooserScreen.swift`, `MotionChooser.swift`
    - `CHANGELOG.md` — lines under `## 0.4.4 (unreleased)` → `### Phone`, in the LAST task only
    - `.impeccable/critique/…` — the two snapshot copies, in Task 1 only
  - This stream MUST NOT edit: anything under `Sources/Infinitus/`, `Sources/InfinitusUI/`, `Sources/InfinitusCore/`, `Sources/InfinitusCLI/`; `ios/InfinitusMobile/RootView.swift`, `MobileLock.swift`, `ThemedPlaceholder.swift` (all three were surveyed and need no change — see the notes in Task 2 and Task 7); `ios/InfinitusMobile/TeamScreen.swift`, `TeamMemberScreen.swift` and any other `Team*` file; `SessionFeedScreen.swift`, `SessionsScreen.swift`, `SessionDetailScreen.swift`, `StatsScreen.swift`, `NativeFleetScreen.swift`, `FleetScreen.swift`, `MirrorModel.swift`; `Sources/Infinitus/MirrorServer.swift`; `tools/e2e.sh`; `site/`; `README.md`; the generated `ios/InfinitusMobile.xcodeproj` (untracked — never `git add` it).
  - Every task's **Files** block repeats the forbidden list as "Do not touch:".
- **Read the craft floor first.** Every task that edits a view opens `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md` and `/Users/deathemperor/.claude/skills/impeccable/reference/ios.md` before its first edit. This is written as Step 1 of every UI task; do not skip it.
- **Apple's containers.** A `Section` header NAMES the group (a noun phrase, never a sentence); a `Section(footer:)` EXPLAINS the consequence (full sentences) — every explanation is a footer, and a group with nothing to explain simply has none rather than filler. No `Text(...).font(.caption)` row inside a group standing in for a footer — the four that exist today are deleted, and no new one is added. Status (a live value) is a row, not a footer: `LabeledContent("Status", value: …)`.
- **Casing.** Sentence case for labels, toggles, footers and section headers ("Mac connection", "Reset and swap alerts", "Add address"). Title Case for buttons and menu items that are commands ("Scan the Mac's QR Code", "Replay Intro", "Make Primary", "Try Again", "Update"). Status VALUES in Title Case ("Not Connected", "Version Not Reported", "Looking for the Mac…" keeps its themed sentence). The ellipsis is the single character `…` and appears only when the action opens something else.
- **Copy.** No engine names for their own sake, no PR numbers, no competitor names, no backticked CLI in user-facing text, no `error.localizedDescription` and no `"\(error)"` on screen: every failure is a sentence naming the problem and the next step. The house voice is the Mac's Remove-account alert — "The Claude account itself is untouched — you can add it back any time."
- **Destructive actions confirm.** `confirmationDialog` naming the consequence, with `role: .destructive` on the confirming button. This round's one destructive action is Forget (a paired Mac).
- **Accessibility.** Every icon-only button gets an `.accessibilityLabel` naming its object; a tooltip's words become an `.accessibilityHint`. A custom row that draws a preview gets `.accessibilityElement(children: .ignore)` plus an explicit `.accessibilityLabel` that reads the theme's own vocabulary, and `.accessibilityAddTraits(.isSelected)` when it is the choice. Decorative previews are `.accessibilityHidden(true)` and `.allowsHitTesting(false)`. Every animation this plan touches or adds honours `@Environment(\.accessibilityReduceMotion)`.
- **Dynamic Type.** No new hard-coded `.font(.system(size:))`. Use text styles; where a drawn shape must track the text (an icon size, a portrait diameter, a bar height), use `@ScaledMetric(relativeTo:)`. `PopupFont.caption` (a fixed 10pt on iOS by design — it keeps the phone's gauges bit-matched to the Mac popup's) stays ONLY inside the gauge previews that already use it; never on new label text.
- **Performance (repo rule).** Idle CPU with any screen open stays ~0%. No `TimelineView`, no `repeatForever` `.animation`, no per-frame SwiftUI work. Continuous motion may only come from Core Animation, which in this repo means the `LayerEffect` host — reachable from here ONLY through the public `GaugeBar(burnStyle:burnHeat:)`, which drives `BurnOverlay` (a `LayerEffect`, `Sources/InfinitusUI/BurnEffect.swift`). Everything else this plan animates is ONE-SHOT (a spring that runs on a tap and stops), which costs nothing at idle.
- **Theme-aware.** Colours come from `ThemeColor.resolve(theme.…)` / `ThemeColor.flash(theme)` and words from the `RowTheme` accessors. Nothing hard-codes a theme's colour or word. Everything must read in light and dark: system colours (`Color.primary`, `.secondary`, `Color(.systemBackground)`) for chrome, theme colours for content.
- **Line numbers.** The critique's line numbers were taken at `bbacd2d`. They are re-verified at this worktree's HEAD (`5aa1c31`) throughout this plan: Forget is `SettingsScreen.swift:148`, the plain-text pairing token `:124–131`, the four caption rows `:36–39`, `:169–173`, `:177–181`, `:185–186`, the endpoint rows `:107–112`, and ChatHeader's hard-coded sizes `:320` (`nameFont`), `:351`, `:366`, `:415`, `:418`, `:428` (its `minWidth: 22` frame at `:430`). Re-read the file before each edit anyway; earlier tasks in this plan move code around.
- **Verification.** Every task builds the phone app:
  ```sh
  cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
      -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
      CODE_SIGNING_ALLOWED=NO build
  ```
  It must print no error and exit 0. `ios/InfinitusMobile.xcodeproj` is generated and untracked — never stage it. The last task additionally runs the full `swift test`.
- **CHANGELOG:** one feature = one short line under `## 0.4.4 (unreleased)` → `### Phone`, added in the LAST task only.
- Every commit carries the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Stage by explicit path. **Never push.** No subagents from implementers.
- Surgical changes, match the file's existing style and comment voice (a comment says WHY, and cites the user or the issue when there is one), no speculative abstractions, no new dependencies.

---

## File structure

| File | Responsibility |
|---|---|
| `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` (new copy) | The spec this plan implements. |
| `.impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md` (new copy) | The same body under the iOS target's frontmatter. |
| `ios/InfinitusMobile/SettingsScreen.swift` | `SettingsForm` re-ordered into twelve headed-and-footed sections; the pairing token as a revealable `SecureField`; labelled, editable addresses; a confirmed Forget; About with progress, a Title-Case status and a retryable failure sentence. |
| `ios/InfinitusMobile/ThemeSwatch.swift` (new) | `ThemeSwatch` — a theme's four colours as one small chip for the Settings row. |
| `ios/InfinitusMobile/ThemeChooserScreen.swift` (new) | `ThemeChooserScreen` — the pushed list of live theme rows; `ThemePreviewRow` (moved here and widened to gauges + spend + model + status + tab bar + name pool). |
| `ios/InfinitusMobile/MotionChooser.swift` (new) | `MotionChooserScreen` (the shell), `MotionOption`, `PaceFireTile` (the real `GaugeBar`), `EntranceTile`, `FlourishTile`, and the three concrete screens. |
| `ios/InfinitusMobile/ChatHeader.swift` | Six hard-coded font sizes become text styles; `portraitSize`, the HUD bar height and the plan-tier disc become `@ScaledMetric`; the unit frame clamps at `.accessibility2`. |
| `CHANGELOG.md` | Eight one-line notes under `### Phone`. |

## What this plan deliberately does NOT do

State these in the final report; they are decisions, not omissions.

- **No `.searchable` over Settings.** iOS Settings searches only at the top level of the Settings app; a per-screen search field over one app's twelve sections is not a platform pattern and would be the only one in the app. Brief item 8 asks for this call explicitly: skipped.
- **"Launch intro" is a section, not a fourth chooser.** Brief item 2 names four things; only three of them have option lists (pace fire, content entrance, title flourish). "Launch intro" was the *section header* over entrance + flourish + speed + replay. This plan folds all four controls into one section named **Motion** and gives the three option lists their own preview choosers.
- **No `RowTheme` change.** Every field the previews need is already `public`. `Sources/InfinitusCore/` is not touched, so the core test suite cannot regress.
- **No `RootView.swift` change.** The Settings tab already wraps `SettingsForm` in a `NavigationStack`, which is all the new pushed choosers need. The themed navigation title (`model.rowTheme.tabLabel("settings")` → "Saddlebag" under Wild West) is a deliberate, user-requested feature (2026-09-04, "themify ios: bottom bars: icons and names") and stays.
- **No `MobileLock.swift` or `ThemedPlaceholder.swift` change.** Both were read: `MobileLock` is model code with no UI, and `ThemedPlaceholder` already honours Reduce Motion (`ThemedPlaceholder.swift:14`) and already uses text styles. Nothing in the critique applies to either.

---

### Task 1: The spec snapshot lands in this worktree

**Files:**
- Create: `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md`
- Create: `.impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md`
- Do not touch: everything else.

- [ ] **Step 1: Copy both snapshots.** They live untracked in the sibling worktree (so `git show e2:…` does not find them — copy the files):

```sh
mkdir -p .impeccable/critique
cp /Users/deathemperor/death/limitless-e2/.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md \
   .impeccable/critique/
cp /Users/deathemperor/death/limitless-e2/.impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md \
   .impeccable/critique/
```

- [ ] **Step 2: Check they are not ignored, then read the iOS one.**

```sh
git check-ignore -v .impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md ; echo "check-ignore exit: $?"
```

Exit 1 with no output means nothing ignores them (this repo's `.gitignore` has no `.impeccable` rule) — proceed. If exit 0 (a rule matched), stop and report it instead of forcing the add.

Then read `.impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md` in full — it is the spec for every later task in this plan.

- [ ] **Step 3: Commit.**

```sh
git add .impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md \
        .impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md
git commit -m "settings: the design critique this round implements

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The Form's structure — order, headers, footers

The critique's [P2] ("explanations live in three containers"), the iOS heuristic-4 finding ("half the sections use a real footer, half fake it with a caption row inside the group … the first section has no header at all") and heuristic-8 ("4–6-line caption blocks sitting inside groups"), plus the hierarchy finding ("on a phone with nothing paired, the first screen is a theme picker").

This task moves and re-labels; the theme row and the three motion pickers keep their CURRENT controls here and are replaced by the pushed choosers in Tasks 3 and 4.

**Files:**
- Modify: `ios/InfinitusMobile/SettingsScreen.swift` (`SettingsForm` only — `ThemePreviewRow`, `DictationSettings`, `ScreenshotSettings` and `AboutSettings` are untouched by this task)
- Do not touch: `Sources/` (any target), `ios/InfinitusMobile/RootView.swift`, `MobileLock.swift`, `ThemedPlaceholder.swift`, `ChatHeader.swift`, `TeamScreen.swift`, `TeamMemberScreen.swift`, `SessionFeedScreen.swift`, `SessionsScreen.swift`, `SessionDetailScreen.swift`, `StatsScreen.swift`, `NativeFleetScreen.swift`, `FleetScreen.swift`, `MirrorModel.swift`, `Sources/Infinitus/MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `CHANGELOG.md`, `ios/InfinitusMobile.xcodeproj`.

**Interfaces:**
- Produces (all `private` inside `SettingsForm`):

```swift
private var isPaired: Bool
private var statusText: String
private var connectionSection: some View
private var addressesSection: some View
private var otherMacsSection: some View
private var appearanceSection: some View
private var themeSection: some View
private var motionSection: some View
private var chatHeaderSection: some View
private var notificationsSection: some View
private var teamSection: some View
private var scanButton: some View
```

- [ ] **Step 1: Read the craft floor.** Open `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md` and `/Users/deathemperor/.claude/skills/impeccable/reference/ios.md` before editing. Then read `ios/InfinitusMobile/SettingsScreen.swift` in full and `.impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md` (the iOS score table and the [P2] issue).

- [ ] **Step 2: Replace the whole `body` of `SettingsForm`.** Delete lines 32–212 (from `var body: some View {` through the closing brace of `body`, i.e. everything up to and including the `.confirmationDialog("Make primary", …)` block's closing `}`) and put this in its place. The property block above line 32 and the `otherCaption` helper below `body` both survive (Step 3 changes one string in the latter).

```swift
    var body: some View {
        Form {
            // The transport leads: with nothing paired the only thing
            // that makes this app work is the first thing on screen,
            // and the cosmetics wait below it (critique, iOS
            // hierarchy: "on a phone with nothing paired, the first
            // screen is a theme picker").
            connectionSection
            addressesSection
            if isPaired { otherMacsSection }
            appearanceSection
            if !model.followMac {
                themeSection
                motionSection
            }
            chatHeaderSection
            DictationSettings()
            ScreenshotSettings()
            notificationsSection
            teamSection
            AboutSettings(model: model)
        }
        .onChange(of: fleetAlarms) { _, on in
            if !on { FleetAlarmCenter.shared.clearPending() }
        }
        .sheet(isPresented: $scanning) {
            PairScannerSheet { payload in
                if model.applyPairing(payload) { paired = true }
            }
        }
        .alert("Paired", isPresented: $paired) {
            Button("OK") { model.requestedTab = "fleet" }
        } message: {
            Text("Paired with \(model.snapshot?.machineName ?? "the Mac"). Its accounts are on the Fleet tab.")
        }
        .sensoryFeedback(.success, trigger: paired)
        .confirmationDialog("Make Primary",
                            isPresented: Binding(get: { promoting != nil }, set: { if !$0 { promoting = nil } }),
                            presenting: promoting) { other in
            Button("Make Primary") { model.makePrimary(id: other.id) }
            Button("Cancel", role: .cancel) {}
        } message: { other in
            Text("Make \(other.pairing.name) the primary Mac? Chats, approvals, widgets and Live Activities follow it.")
        }
    }

    /// A token is what a pairing IS — with none, nothing this screen
    /// offers below the fold can work yet.
    private var isPaired: Bool { !model.pairToken.isEmpty }

    /// The transport's own words while it looks, or the theme's
    /// ("Scouting for the Mac…" under RPG) before it has any.
    private var statusText: String {
        model.transportStatus.isEmpty
            ? model.rowTheme.loadingWord("searching")
            : model.transportStatus
    }

    private var scanButton: some View {
        Button { scanning = true } label: {
            Label("Scan the Mac's QR Code", systemImage: "qrcode.viewfinder")
        }
    }

    // MARK: - the transport

    /// Which Mac is mirrored and the credential that reads it. Unpaired,
    /// the section IS the onboarding step and leads with the scan;
    /// paired, the status leads and the scan drops to a plain row.
    private var connectionSection: some View {
        Section {
            if !isPaired, PairScanner.isSupported {
                scanButton.font(.body.weight(.semibold))
            }
            LabeledContent("Status", value: statusText)
            if isPaired, PairScanner.isSupported { scanButton }
            LabeledContent("Pairing token") {
                TextField("Paste or scan", text: $model.pairToken)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text(isPaired ? "Mac connection" : "Pair with a Mac")
        } footer: {
            Text(connectionFooter)
        }
    }

    private var connectionFooter: String {
        let camera = PairScanner.isSupported
            ? "Open Settings › Devices on the Mac and scan the code it shows — it fills in the address and the token for you."
            : "This phone has no camera to scan with: copy the address and the token from Settings › Devices on the Mac."
        return isPaired
            ? camera + " On the same Wi-Fi the phone finds the Mac by itself."
            : camera
    }

    /// Where to reach the Mac when Bonjour can't: one row per address,
    /// deletable in edit mode or by a swipe.
    private var addressesSection: some View {
        Section {
            ForEach(model.manualEndpoints, id: \.self) { endpoint in
                Text(endpoint)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Address \(endpoint)")
            }
            .onDelete { model.removeManualEndpoint(at: $0) }
            LabeledContent("Add address") {
                TextField("host:port, or a tunnel's https:// URL", text: $newEndpoint)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit {
                        model.addManualEndpoint(newEndpoint)
                        newEndpoint = ""
                    }
            }
        } header: {
            HStack {
                Text("Addresses")
                Spacer()
                if !model.manualEndpoints.isEmpty {
                    EditButton()
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                }
            }
        } footer: {
            Text("The phone finds the Mac on this Wi-Fi by itself. Add an address to reach it from anywhere else — a tunnel's URL works from any network.")
        }
    }

    /// Every OTHER paired Mac (#144 phase 1): read-only fleets and
    /// sessions elsewhere in the app, forgettable or promotable here.
    private var otherMacsSection: some View {
        Section {
            ForEach(model.others) { other in
                VStack(alignment: .leading, spacing: 2) {
                    Text(other.pairing.name).fontWeight(.semibold)
                    Text(otherCaption(other)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .swipeActions {
                    Button("Forget", role: .destructive) {
                        model.forgetOther(id: other.id)
                    }
                }
                .contextMenu {
                    Button("Make Primary") { promoting = other }
                }
            }
        } header: {
            Text("Other Macs")
        } footer: {
            Text("Scan another Mac's QR code to add it. Only the primary Mac gets chats, approvals, widgets and Live Activities in this version.")
        }
    }

    // MARK: - what the app looks like

    private var appearanceSection: some View {
        Section {
            Toggle("Follow Mac", isOn: $model.followMac)
            Toggle("Show as Mac popup", isOn: $model.macPopupView)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Follow Mac renders exactly what the Mac popup shows — its theme, rows, pace fire and intro; turn it off to choose your own here. Show as Mac popup renders the popup itself instead of the iPhone layout: portrait stacks the cards, landscape shows the wide rows.")
        }
    }

    private var themeSection: some View {
        Section {
            Picker("Theme", selection: $model.localThemeID) {
                ForEach(model.availableThemes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            .pickerStyle(.navigationLink)
            Toggle("Compact rows", isOn: $model.localCompactRows)
        } header: {
            Text("Theme")
        } footer: {
            Text("A theme renames the tabs, the gauges, the status words and the fleet's own names, and gives them its colours. Compact rows put one account on a line.")
        }
    }

    private var motionSection: some View {
        Section {
            Picker("Pace fire", selection: $model.localBurnStyle) {
                Text("Off").tag("off")
                Text("Ember glow").tag("ember")
                Text("Flame licks").tag("flame")
                Text("Limit break").tag("limit")
            }
            Picker("Content entrance", selection: $model.localIntroStyle) {
                Text("Slide from top").tag("top")
                Text("Slide from bottom").tag("bottom")
                Text("Fade in").tag("fade")
                Text("Rows slide from right").tag("rows")
            }
            Picker("Title flourish", selection: $model.localIntroTitle) {
                Text("Zoom bounce").tag("zoom")
                Text("Stamp slam").tag("slam")
                Text("Spin up").tag("spin")
                Text("Off").tag("off")
            }
            LabeledContent("Speed") {
                HStack(spacing: 8) {
                    Slider(value: $model.localIntroSpeed, in: 0.4...2)
                        .accessibilityLabel("Intro speed")
                    Text(String(format: "%.1f×", model.localIntroSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Button("Replay Intro") { model.replayIntro() }
        } header: {
            Text("Motion")
        } footer: {
            Text("Pace fire sets the weekly and model bars alight when an account spends faster than the clock. The intro plays once when the app opens: the content enters, the bars fill, then the title lands.")
        }
    }

    private var chatHeaderSection: some View {
        Section {
            ChatHeaderPicker(selection: $chatHeader, theme: model.rowTheme)
        } header: {
            Text("Chat header")
        } footer: {
            Text("What a session's chat wears above the transcript.")
        }
    }

    // MARK: - the rest

    private var notificationsSection: some View {
        Section {
            Toggle("Reset and swap alerts", isOn: $fleetAlarms)
        } header: {
            Text("Notifications")
        } footer: {
            Text("The phone raises these itself from the last snapshot, with nothing needed on the Mac: an exhausted account's limit lifting in ten minutes, and the account the fleet has just swapped to.")
        }
    }

    private var teamSection: some View {
        Section {
            Toggle("Lock the Team tab with \(lock.methodName)", isOn: $lock.enabled)
        } header: {
            Text("Team")
        } footer: {
            Text("Joining a team from this phone needs the lock on; the Mac has the same rule.")
        }
    }
```

Notes on what changed and why, for the reviewer of this diff:

* **Order.** Connection → Addresses → Other Macs → Appearance → (Theme, Motion) → Chat header → Dictation → Screenshots → Notifications → Team → About. Cosmetics no longer open the screen.
* **Every section has a header, and every explanation is a footer.** The four caption rows inside groups (old `:36–39` Follow Mac, `:169–173` Appearance, `:177–181` Notifications, `:185–186` Team) are gone; their content is now footer prose. The old no-camera caption row (`:100–101`) and the old status caption row (`:103–106`) are gone too — the first is a footer clause, the second is a `LabeledContent("Status", …)` row, because a live value is status, not explanation.
* **Addresses moved out of "Mac connection".** They were unlabeled monospaced strings with an invisible delete; they are now their own named group with an `EditButton` in the header and an `.accessibilityLabel` per row.
* **Other Macs is hidden until something is paired** — with no primary Mac it is an empty group of noise standing between the reader and the scan button.
* **Parentheticals left the labels.** "Compact rows (one line per account)" → "Compact rows" plus a footer clause. "Pace fire (7d & model bars)" was a section header carrying a sentence fragment → the Motion footer says it in English. "Launch intro" as a header disappears: entrance, flourish, speed and replay are Motion.
* **Casing.** "Scan the Mac's QR Code", "Replay Intro", "Make Primary" are commands → Title Case; every label, toggle and header is sentence case.
* **The speed readout** dropped `.frame(width: 36)` (which clips at large text sizes) for `.fixedSize()`, and `x` became the multiplication sign `×`.

- [ ] **Step 3: One status string in `otherCaption`.** That helper (directly under `body`) is kept as it is except for its fallback, which is a status VALUE and so takes Title Case like "Not Connected":

```swift
            return other.status.isEmpty ? "Looking for this Mac…" : other.status
```

Nothing else in `otherCaption` changes.

- [ ] **Step 4: The Make-primary dialog keeps its state; nothing new is needed here.** Confirm the `@State` block at lines 14–30 still reads exactly:

```swift
    @AppStorage("chat_header") private var chatHeader = "compact"
    @AppStorage(FleetAlarmCenter.enabledKey) private var fleetAlarms = true

    @ObservedObject var model: MirrorModel
    @ObservedObject private var lock = MobileLock.shared
    @State private var scanning = false
    @State private var newEndpoint = ""
    @State private var paired = false
    @State private var promoting: MirrorModel.OtherMac?
```

(with their existing doc comments). Task 5 adds two more `@State`s here.

- [ ] **Step 5: Build.**

```sh
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
    -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
```

Must exit 0. If `EditButton()` in a `Section` header fails to compile, it is because the header builder needs an explicit `HStack` — it is already one above; do not fall back yet.

- [ ] **Step 6: Commit.**

```sh
git add ios/InfinitusMobile/SettingsScreen.swift
git commit -m "phone settings: the Mac connection leads, and every group explains itself in a footer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: The theme chooser shows the themes

The critique's [P0] for iOS: "`Picker(\"Theme\")` with `.pickerStyle(.navigationLink)` pushes thirteen `Text(theme.name)` rows … A theme changes labels, four colours, the cash icon, model aliases, status words, placeholder copy and motion, and the tab bar's names and icons." The Mac already solved this (`ThemesPane` renders every theme as a live row); so does this app's own `ChatHeaderPicker` (`ChatHeader.swift:469`), which is the in-repo pattern to copy: a `Button` per option whose label is the live preview plus a checkmark.

**Files:**
- Create: `ios/InfinitusMobile/ThemeSwatch.swift`
- Create: `ios/InfinitusMobile/ThemeChooserScreen.swift`
- Modify: `ios/InfinitusMobile/SettingsScreen.swift` (`themeSection`; delete `ThemePreviewRow` from this file — it moves to the new one)
- Do not touch: `Sources/` (any target — every field used here is already `public`), `ios/InfinitusMobile/RootView.swift`, `MobileLock.swift`, `ThemedPlaceholder.swift`, `ChatHeader.swift`, `TeamScreen.swift`, `TeamMemberScreen.swift`, `SessionFeedScreen.swift`, `SessionsScreen.swift`, `SessionDetailScreen.swift`, `StatsScreen.swift`, `NativeFleetScreen.swift`, `FleetScreen.swift`, `MirrorModel.swift`, `Sources/Infinitus/MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `CHANGELOG.md`, `ios/InfinitusMobile.xcodeproj`.

**Interfaces:**
- Produces:

```swift
struct ThemeSwatch: View { let theme: RowTheme }
struct ThemeChooserScreen: View { @Binding var selection: String; let themes: [RowTheme] }
struct ThemePreviewRow: View { let theme: RowTheme; var selected: Bool = false }
```

- Consumes (all already `public`): `RowTheme.{id,name,plain,sessionLabel,sessionColor,weeklyLabel,weeklyColor,scopedPrefix,scopedColor,creditColor,cashIcon,accountNames}`, `RowTheme.{modelName(_:),sessionWord(_:),tabLabel(_:),tabIcon(_:)}`, `ThemeColor.{resolve(_:),flash(_:)}`, `PopupGlyph.text(_:)`, `PopupFont.caption`, `GaugeBar`.

- [ ] **Step 1: Read the craft floor.** `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md` and `ios.md`, then `.impeccable/critique/2026-09-06T08-58-14Z__ios-infinitusmobile.md` ([P0], iOS). Then read `ios/InfinitusMobile/ChatHeader.swift` lines 469–504 (`ChatHeaderPicker`) — the pattern this task follows — and the current `ThemePreviewRow` in `ios/InfinitusMobile/SettingsScreen.swift`.

- [ ] **Step 2: Create `ios/InfinitusMobile/ThemeSwatch.swift`** with exactly this content:

```swift
import SwiftUI
import InfinitusCore
import InfinitusUI

/// A theme's four colours — session, weekly, model, credit — as one
/// small chip. The Settings row wears it beside the theme's name so the
/// name is not the only thing the reader has to go on before opening
/// the chooser (critique, iOS heuristic 6).
struct ThemeSwatch: View {
    let theme: RowTheme
    /// Tracks the row's text so the chip grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var height = 15

    private var colors: [Color] {
        [theme.sessionColor, theme.weeklyColor, theme.scopedColor, theme.creditColor]
            .map(ThemeColor.resolve)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: height * 0.55, height: height)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(Color.primary.opacity(0.12))
                .frame(width: height * 0.55 * 4 + 6, height: height)
        )
        // The name beside it says everything a reader needs; the chip is
        // the same fact in colour.
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 3: Create `ios/InfinitusMobile/ThemeChooserScreen.swift`** with exactly this content. `ThemePreviewRow` moves here from `SettingsScreen.swift` and grows from two gauges to the six things a theme actually changes on this phone:

```swift
import SwiftUI
import InfinitusCore
import InfinitusUI

/// Every theme as a live row, the way the Mac's Themes pane and this
/// app's own chat-header picker already do it (critique [P0], iOS: the
/// old pushed picker was thirteen plain names, and the single preview
/// appeared only after committing). Tapping a row selects it — no Done,
/// no second step — and the current one scrolls into view on arrival.
struct ThemeChooserScreen: View {
    @Binding var selection: String
    let themes: [RowTheme]

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(themes) { theme in
                        Button {
                            selection = theme.id
                        } label: {
                            ThemePreviewRow(theme: theme, selected: theme.id == selection)
                        }
                        .buttonStyle(.plain)
                        .id(theme.id)
                        // Room for the tab-bar mock: the Form's default
                        // insets clip its outer two items.
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    }
                } footer: {
                    Text("Tap a theme to use it — the change is immediate, here and on every other tab.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // A scrollTo inside onAppear lands before the list has
                // laid out and does nothing; one runloop later it works.
                let current = selection
                DispatchQueue.main.async {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
    }
}

/// What a theme looks like once it is on: the two window gauges with
/// its labels and colours, the spend and model line with its cash icon,
/// its word for a working session, a mock of the four tab-bar items it
/// renames, and two of the names it draws account aliases from.
struct ThemePreviewRow: View {
    let theme: RowTheme
    var selected = false
    @ScaledMetric(relativeTo: .caption) private var tabIcon = 15.0

    private static let tabs = ["sessions", "fleet", "team", "settings"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.name)
                    .font(.headline)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            HStack(spacing: 12) {
                gauge(label: theme.sessionLabel, color: theme.sessionColor,
                      remaining: 62, dividers: (1..<5).map { Double($0) * 20 })
                gauge(label: theme.weeklyLabel, color: theme.weeklyColor,
                      remaining: 38, dividers: (1..<7).map { Double($0) * 100 / 7 })
                Spacer(minLength: 0)
            }
            spendLine
            tabBar
            if let names = nameLine {
                Text(names)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // One announcement in the theme's own words, instead of nine
        // decorative fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The credit and model cells the fleet rows draw, in miniature.
    private var spendLine: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(PopupGlyph.text(theme.cashIcon))1,131")
                .foregroundStyle(ThemeColor.resolve(theme.creditColor))
            Text(PopupGlyph.text(theme.scopedPrefix) + theme.modelName("Fable"))
                .foregroundStyle(ThemeColor.resolve(theme.scopedColor))
            Text(theme.sessionWord("busy"))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    /// The most visible thing a theme changes and the one the old picker
    /// never showed: the bottom bar's four names and icons.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.self) { tab in
                VStack(spacing: 2) {
                    icon(theme.tabIcon(tab))
                    Text(theme.tabLabel(tab))
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(tab == "sessions" ? ThemeColor.flash(theme) : Color.secondary)
            }
        }
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func icon(_ name: String) -> some View {
        if name.hasPrefix("sf:") {
            Image(systemName: String(name.dropFirst(3)))
                .font(.system(size: tabIcon))
        } else {
            Text(PopupGlyph.text(name))
                .font(.system(size: tabIcon))
        }
    }

    /// The pool "Randomize names" draws from — omitted for Off and for a
    /// custom theme with no pool of its own (those fall back to every
    /// built-in's, which is not this theme's fact to state).
    private var nameLine: String? {
        let names = theme.accountNames.prefix(2)
        guard names.count == 2 else { return nil }
        return "Names like: " + names.joined(separator: ", ")
    }

    private var voiceOverLabel: String {
        var parts = [theme.name,
                     "Gauges \(theme.sessionLabel) and \(theme.weeklyLabel)",
                     "A working session is “\(theme.sessionWord("busy"))”",
                     "Tabs " + Self.tabs.map(theme.tabLabel).joined(separator: ", ")]
        if let names = nameLine { parts.append(names) }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private func gauge(label: String, color: String, remaining: Double,
                       dividers: [Double]) -> some View {
        HStack(spacing: 3) {
            Text(PopupGlyph.text(label))
                .font(PopupFont.caption).bold()
                .foregroundStyle(ThemeColor.resolve(color))
            if theme.plain {
                Text("\(Int(100 - remaining))%")
                    .font(PopupFont.caption).monospacedDigit()
            } else {
                GaugeBar(remaining: remaining, color: ThemeColor.resolve(color),
                         dividers: dividers, animated: false)
            }
        }
    }
}
```

- [ ] **Step 4: Delete the old `ThemePreviewRow` from `SettingsScreen.swift`.** Remove the whole declaration — its doc comment ("What a themed row will look like: …") through the closing brace of the struct, and the two blank lines that follow it. Nothing else in that file references it once Step 5 lands.

- [ ] **Step 5: Point the Theme section at the chooser.** In `SettingsScreen.swift`, replace the `Picker("Theme", …)` / `.pickerStyle(.navigationLink)` pair inside `themeSection` (added in Task 2) with the navigation row, and add the helper below it:

```swift
    private var themeSection: some View {
        Section {
            NavigationLink {
                ThemeChooserScreen(selection: $model.localThemeID,
                                   themes: model.availableThemes)
            } label: {
                LabeledContent("Theme") {
                    HStack(spacing: 8) {
                        ThemeSwatch(theme: localTheme)
                        Text(localTheme.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Toggle("Compact rows", isOn: $model.localCompactRows)
        } header: {
            Text("Theme")
        } footer: {
            Text("A theme renames the tabs, the gauges, the status words and the fleet's own names, and gives them its colours. Compact rows put one account on a line.")
        }
    }

    /// The theme this PHONE is set to. `model.rowTheme` answers with the
    /// Mac's while Follow Mac is on; this section only shows with it off,
    /// but the row must never read from the Mac's choice.
    private var localTheme: RowTheme {
        model.availableThemes.first { $0.id == model.localThemeID } ?? .off
    }
```

- [ ] **Step 6: Build.**

```sh
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
    -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
```

Must exit 0. `SettingsScreen.swift` already imports `InfinitusCore` and `InfinitusUI`, so `RowTheme` and `ThemeColor` resolve there; the two new files import all three modules themselves.

- [ ] **Step 7: Commit.**

```sh
git add ios/InfinitusMobile/ThemeSwatch.swift ios/InfinitusMobile/ThemeChooserScreen.swift \
        ios/InfinitusMobile/SettingsScreen.swift
git commit -m "phone settings: the theme chooser shows every theme, gauges to tab bar

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Pace fire, content entrance and title flourish get tiles

Same [P0] rule, applied to the three motion menus: "Ember glow" vs "Flame licks" vs "Limit break" is unknowable from text.

**How each preview is drawn — decided per option, as the brief asks:**

* **Pace fire → the REAL renderer.** `GaugeBar` is `public` and already takes `burnStyle:` / `burnHeat:`; its fire is `BurnOverlay`, which is "pure Core Animation on a `LayerEffect` host … nothing per frame in-process" (`Sources/InfinitusUI/BurnEffect.swift`, header comment). So the tile is an actual burning bar and still costs ~0% idle CPU. Two behaviours to know and to state in the footer: `BurnRules.weekly` (`Sources/InfinitusUI/GaugeBar.swift:424–437`, `weekly` at `:427`) downgrades "limit" to "ember" on every theme but RPG, and the overlay is gated on `animated` (`GaugeBar.swift:227`), so under Reduce Motion the tiles show still bars. The tile passes the RAW tag so each option shows ITS OWN effect regardless of the current theme; the footer says where each one actually plays.
* **Content entrance and title flourish → a drawn frame plus a one-shot replay.** The real renderers (`IntroContentReveal`, `IntroRowSlide`, `IntroTitleFlourish` in `Sources/InfinitusUI/Animations.swift`) are `ViewModifier`s over a `FleetModel` and fire only on `introTick`; they cannot be hosted in a settings row. The tiles therefore draw a miniature of the thing that moves and replay the real transform on tap, with the exact numbers copied from `Animations.swift` (dy ∓44 → ∓18 at tile scale, dx 90 → 34, the 0.09 s per-row stagger, scale 0.1 / 3.4, rotation −12° / −720°, and each style's spring). A one-shot spring is not continuous motion: nothing ticks at idle. Reduce Motion keeps them still.

**Files:**
- Create: `ios/InfinitusMobile/MotionChooser.swift`
- Modify: `ios/InfinitusMobile/SettingsScreen.swift` (`motionSection`)
- Do not touch: `Sources/` (any target), `ios/InfinitusMobile/RootView.swift`, `MobileLock.swift`, `ThemedPlaceholder.swift`, `ChatHeader.swift`, `ThemeChooserScreen.swift`, `ThemeSwatch.swift`, `TeamScreen.swift`, `TeamMemberScreen.swift`, `SessionFeedScreen.swift`, `SessionsScreen.swift`, `SessionDetailScreen.swift`, `StatsScreen.swift`, `NativeFleetScreen.swift`, `FleetScreen.swift`, `MirrorModel.swift`, `Sources/Infinitus/MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `CHANGELOG.md`, `ios/InfinitusMobile.xcodeproj`.

**Interfaces:**
- Produces:

```swift
struct MotionOption: Identifiable { let id: String; let label: String; let caption: String }
struct MotionChooserScreen<Preview: View>: View {
    let title: String
    let footer: String
    let options: [MotionOption]
    @Binding var selection: String
    let preview: (MotionOption, Int) -> Preview   // (option, playTick)
}
struct PaceFireTile: View { let style: String; let theme: RowTheme }
struct EntranceTile: View { let style: String; var playTick: Int }
struct FlourishTile: View { let style: String; let theme: RowTheme; var playTick: Int }
struct PaceFireChooser: View { @Binding var selection: String; let theme: RowTheme }
struct ContentEntranceChooser: View { @Binding var selection: String }
struct TitleFlourishChooser: View { @Binding var selection: String; let theme: RowTheme }
```

- [ ] **Step 1: Read the craft floor.** `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md` and `ios.md`. Then read `Sources/InfinitusUI/Animations.swift` (the three intro modifiers — the numbers below are copied from it), `Sources/InfinitusUI/GaugeBar.swift` lines 90–130 and 216–252 (the burn gate and the overlay's `.bottom` alignment) and 420–440 (`BurnRules`), and `Sources/InfinitusUI/BurnEffect.swift` lines 1–55 (the `rise: 11` above the bar, which is why the tile pads its top).

- [ ] **Step 2: Create `ios/InfinitusMobile/MotionChooser.swift`** with exactly this content:

```swift
import SwiftUI
import InfinitusCore
import InfinitusUI

/// One motion option: the tag stored in defaults, the name, and the
/// sentence that says what it does where the drawing can't (what a bar
/// does when Reduce Motion is on, which theme a style needs).
struct MotionOption: Identifiable {
    let id: String
    let label: String
    let caption: String
}

/// The house rule for a chooser whose options can be SHOWN: a pushed
/// screen, one row per option, the row IS the option (the Mac's Themes
/// pane, this app's chat-header picker, and now these). Tapping selects
/// immediately and replays that row's preview; there is no Done.
struct MotionChooserScreen<Preview: View>: View {
    let title: String
    let footer: String
    let options: [MotionOption]
    @Binding var selection: String
    @ViewBuilder let preview: (MotionOption, Int) -> Preview

    /// Bumped on a tap; the tiles watch it and play once.
    @State private var playTick = 0

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option.id
                        playTick += 1
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                        .foregroundStyle(.primary)
                                    Text(option.caption)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: selection == option.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .imageScale(.large)
                                    .foregroundStyle(selection == option.id
                                                     ? Color.accentColor : Color.secondary)
                            }
                            preview(option, selection == option.id ? playTick : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(option.label). \(option.caption)")
                    .accessibilityAddTraits(selection == option.id
                                            ? [.isButton, .isSelected] : .isButton)
                }
            } footer: {
                Text(footer)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - pace fire

/// The real thing: `GaugeBar` draws the burn itself, on a Core
/// Animation `LayerEffect` host, so a screen of four burning bars costs
/// nothing at idle. The RAW style tag goes in, so each row shows its own
/// effect whatever theme is on (BurnRules would fold "limit" into
/// "ember" outside RPG — the footer says so instead of hiding it).
struct PaceFireTile: View {
    let style: String
    let theme: RowTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text(PopupGlyph.text(theme.weeklyLabel))
                .font(PopupFont.caption).bold()
                .foregroundStyle(ThemeColor.resolve(theme.weeklyColor))
            GaugeBar(remaining: 34,
                     color: ThemeColor.resolve(theme.weeklyColor),
                     paceRemaining: 59,
                     dividers: (1..<7).map { Double($0) * 100 / 7 },
                     animated: !reduceMotion,
                     burnStyle: style,
                     burnHeat: style == "off" ? 0 : 0.85)
            Spacer(minLength: 0)
        }
        .environment(\.gaugeScale, 1.6)
        // No fill-from-empty on a settings tile; the bar sits at its
        // value and burns.
        .environment(\.gaugeIntroOnAppear, false)
        // BurnOverlay rises 11pt above the capsule (BurnEffect.swift);
        // without the pad the list row clips the flames.
        .padding(.top, 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - launch intro

/// Three rows entering the way the content does at launch. The offsets
/// and the springs are IntroContentReveal / IntroRowSlide's own
/// (Animations.swift), scaled to the tile; the whole thing is one shot
/// on a tap, so nothing ticks while the screen sits open.
///
/// At REST the tile still has to tell the four options apart, or the
/// chooser is four identical pictures again: a ghost of where the rows
/// come FROM sits behind them at a quarter opacity (offset up, down or
/// staggered to the right; dashed outlines for the fade, which comes
/// from nowhere).
struct EntranceTile: View {
    let style: String
    var playTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = true

    private var dy: CGFloat {
        switch style {
        case "top": -18
        case "bottom": 18
        default: 0
        }
    }
    private var dx: CGFloat { style == "rows" ? 34 : 0 }
    /// Each row's own ghost offset — "rows" staggers, the others move as
    /// one, "fade" stays put and shows an outline instead.
    private func ghostOffset(_ row: Int) -> CGSize {
        style == "rows" ? CGSize(width: dx * Double(3 - row) / 3, height: 0)
                        : CGSize(width: 0, height: dy)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(height: 7)
                        .opacity(settled ? 1 : 0)
                        .offset(x: settled ? 0 : dx, y: settled ? 0 : dy)
                        .animation(.spring(duration: 0.55, bounce: 0.2)
                            .delay(style == "rows" ? Double(row) * 0.09 : 0),
                                   value: settled)
                        .background {
                            // Where this row starts from, drawn so the
                            // option reads without a tap.
                            if style == "fade" {
                                Capsule()
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .foregroundStyle(Color.accentColor.opacity(0.35))
                            } else {
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.25))
                                    .offset(ghostOffset(row))
                            }
                        }
                }
            }
            .padding(12)
        }
        .frame(height: 74)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: playTick) { _, tick in if tick > 0 { play() } }
    }

    private func play() {
        guard !reduceMotion else { return }
        // Reset without animating, then let the value-driven spring run
        // once. A repeatForever animation here would cost a CA
        // transaction per frame for as long as the screen is open.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { settled = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { settled = true }
    }
}

/// The title landing, with IntroTitleFlourish's own start transforms and
/// springs (Animations.swift) — the real glyph and wordmark, one shot.
/// At rest a ghost of the START transform sits behind it, so a dot (zoom
/// and spin), a big tilted stamp (slam) or nothing at all (off) tells
/// the four apart before anyone taps.
struct FlourishTile: View {
    let style: String
    let theme: RowTheme
    var playTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = true
    @State private var glow = 0.0

    private var startScale: CGFloat {
        switch style {
        case "slam": 3.4
        case "spin", "zoom": 0.1
        default: 1
        }
    }
    private var startRotation: Double {
        switch style {
        case "slam": -12
        case "spin": -720
        default: 0
        }
    }
    private var spring: Animation {
        switch style {
        case "slam": .spring(duration: 0.5, bounce: 0.35)
        case "spin": .spring(duration: 0.9, bounce: 0.3)
        default: .spring(duration: 0.7, bounce: 0.55)
        }
    }
    private var tint: Color {
        theme.plain ? .secondary : ThemeColor.flash(theme)
    }

    /// The wordmark, once as the ghost of where it starts and once live.
    private var wordmark: some View {
        HStack(spacing: 6) {
            InfinitusGlyph()
                .frame(width: 20, height: 20)
            Text("Infinitus")
                .font(.headline)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if style != "off" {
                wordmark
                    .foregroundStyle(tint.opacity(0.25))
                    .scaleEffect(startScale)
                    .rotationEffect(.degrees(startRotation))
            }
            wordmark
                .foregroundStyle(tint)
                .scaleEffect(settled ? 1 : startScale)
                .rotationEffect(.degrees(settled ? 0 : startRotation))
                .opacity(settled ? 1 : 0)
                .brightness(glow)
                .animation(spring, value: settled)
        }
        .frame(height: 74)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: playTick) { _, tick in if tick > 0 { play() } }
    }

    private func play() {
        guard !reduceMotion, style != "off" else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { settled = false; glow = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            settled = true
            // The impact flash, the way the real flourish does it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                glow = 0.8
                withAnimation(.easeOut(duration: 0.8)) { glow = 0 }
            }
        }
    }
}

// MARK: - the three screens

struct PaceFireChooser: View {
    @Binding var selection: String
    let theme: RowTheme

    private static let options = [
        MotionOption(id: "off", label: "Off", caption: "The bar just empties."),
        MotionOption(id: "ember", label: "Ember glow", caption: "Coals along the fill."),
        MotionOption(id: "flame", label: "Flame licks", caption: "Tongues above the bar."),
        MotionOption(id: "limit", label: "Limit break", caption: "A running rainbow marquee."),
    ]

    var body: some View {
        MotionChooserScreen(
            title: "Pace fire",
            footer: "A bar catches fire when its account is spending faster than the clock — the weekly bar and each model's. Limit break needs the RPG theme; under any other it burns like Ember glow. With Reduce Motion on, the bars stay still.",
            options: Self.options,
            selection: $selection
        ) { option, _ in
            PaceFireTile(style: option.id, theme: theme)
        }
    }
}

struct ContentEntranceChooser: View {
    @Binding var selection: String

    private static let options = [
        MotionOption(id: "top", label: "Slide from top", caption: "The accounts drop in together."),
        MotionOption(id: "bottom", label: "Slide from bottom", caption: "The accounts rise in together."),
        MotionOption(id: "fade", label: "Fade in", caption: "The accounts appear in place."),
        MotionOption(id: "rows", label: "Rows slide from right", caption: "One account after another."),
    ]

    var body: some View {
        MotionChooserScreen(
            title: "Content entrance",
            footer: "How the accounts arrive when the app opens; the faded rows behind each one show where they come from. Tap a row to see it. With Reduce Motion on, they arrive in place.",
            options: Self.options,
            selection: $selection
        ) { option, tick in
            EntranceTile(style: option.id, playTick: tick)
        }
    }
}

struct TitleFlourishChooser: View {
    @Binding var selection: String
    let theme: RowTheme

    private static let options = [
        MotionOption(id: "zoom", label: "Zoom bounce", caption: "Grows from a dot and overshoots."),
        MotionOption(id: "slam", label: "Stamp slam", caption: "Stamps down at a tilt."),
        MotionOption(id: "spin", label: "Spin up", caption: "Two turns on the way in."),
        MotionOption(id: "off", label: "Off", caption: "The title is simply there."),
    ]

    var body: some View {
        MotionChooserScreen(
            title: "Title flourish",
            footer: "How the Infinitus title lands, a beat after the bars have filled; the faded title behind each one shows where it starts. Tap a row to see it. With Reduce Motion on, it lands without the flourish.",
            options: Self.options,
            selection: $selection
        ) { option, tick in
            FlourishTile(style: option.id, theme: theme, playTick: tick)
        }
    }
}
```

- [ ] **Step 3: Point the Motion section at the three choosers.** In `SettingsScreen.swift`, replace the three `Picker`s inside `motionSection` with navigation rows; the `LabeledContent("Speed")` block and the `Button("Replay Intro")` stay exactly as Task 2 left them:

```swift
    private var motionSection: some View {
        Section {
            NavigationLink {
                PaceFireChooser(selection: $model.localBurnStyle, theme: localTheme)
            } label: {
                LabeledContent("Pace fire", value: Self.paceFireNames[model.localBurnStyle] ?? "Off")
            }
            NavigationLink {
                ContentEntranceChooser(selection: $model.localIntroStyle)
            } label: {
                LabeledContent("Content entrance", value: Self.entranceNames[model.localIntroStyle] ?? "Fade in")
            }
            NavigationLink {
                TitleFlourishChooser(selection: $model.localIntroTitle, theme: localTheme)
            } label: {
                LabeledContent("Title flourish", value: Self.flourishNames[model.localIntroTitle] ?? "Off")
            }
            LabeledContent("Speed") {
                HStack(spacing: 8) {
                    Slider(value: $model.localIntroSpeed, in: 0.4...2)
                        .accessibilityLabel("Intro speed")
                    Text(String(format: "%.1f×", model.localIntroSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Button("Replay Intro") { model.replayIntro() }
        } header: {
            Text("Motion")
        } footer: {
            Text("Pace fire sets the weekly and model bars alight when an account spends faster than the clock. The intro plays once when the app opens: the content enters, the bars fill, then the title lands.")
        }
    }

    /// The value each Motion row shows — the chooser's own names, so the
    /// row and the pushed screen never disagree.
    private static let paceFireNames = ["off": "Off", "ember": "Ember glow",
                                        "flame": "Flame licks", "limit": "Limit break"]
    private static let entranceNames = ["top": "Slide from top", "bottom": "Slide from bottom",
                                        "fade": "Fade in", "rows": "Rows slide from right"]
    private static let flourishNames = ["zoom": "Zoom bounce", "slam": "Stamp slam",
                                        "spin": "Spin up", "off": "Off"]
```

- [ ] **Step 4: Build.**

```sh
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
    -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
```

Must exit 0. If `MotionChooserScreen`'s trailing `@ViewBuilder let preview:` closure fails type inference at a call site, give the call an explicit closure signature (`{ (option: MotionOption, tick: Int) in … }`) rather than erasing the generic to `AnyView`.

- [ ] **Step 5: Commit.**

```sh
git add ios/InfinitusMobile/MotionChooser.swift ios/InfinitusMobile/SettingsScreen.swift
git commit -m "phone settings: pace fire, entrance and flourish are picked from tiles that show them

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The credential is covered, and Forget asks

The critique's [P1]: "the pairing token, a bearer credential for the whole fleet, is a plain `TextField` … Swipe-to-Forget a paired Mac is destructive with no confirmation and no undo — while the harmless 'Make primary' gets a full `confirmationDialog`. Risk is inverted."

**Files:**
- Modify: `ios/InfinitusMobile/SettingsScreen.swift` (`connectionSection`, `otherMacsSection`, the `@State` block, the `body`'s dialogs)
- Do not touch: `Sources/` (any target), `ios/InfinitusMobile/RootView.swift`, `MobileLock.swift`, `ThemedPlaceholder.swift`, `ChatHeader.swift`, `ThemeChooserScreen.swift`, `ThemeSwatch.swift`, `MotionChooser.swift`, `TeamScreen.swift`, `TeamMemberScreen.swift`, `SessionFeedScreen.swift`, `SessionsScreen.swift`, `SessionDetailScreen.swift`, `StatsScreen.swift`, `NativeFleetScreen.swift`, `FleetScreen.swift`, `MirrorModel.swift`, `Sources/Infinitus/MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `CHANGELOG.md`, `ios/InfinitusMobile.xcodeproj`.

- [ ] **Step 1: Read the craft floor.** `craft-floor.md` and `ios.md`, then the [P1] "Confirmation is inverted" section of the spec.

- [ ] **Step 2: Add the two new `@State`s** to `SettingsForm`, directly after `@State private var promoting: MirrorModel.OtherMac?`:

```swift
    /// The Mac a swipe is asking to forget (critique [P1]: the
    /// destructive action was the unconfirmed one).
    @State private var forgetting: MirrorModel.OtherMac?
    /// The pairing token is a bearer credential for the whole fleet, so
    /// it is covered until its owner asks to see it.
    @State private var tokenShown = false
```

- [ ] **Step 3: Cover the token.** Replace the `LabeledContent("Pairing token") { TextField(…) }` block inside `connectionSection` with:

```swift
            LabeledContent("Pairing token") {
                HStack(spacing: 8) {
                    Group {
                        if tokenShown {
                            TextField("Paste or scan", text: $model.pairToken)
                        } else {
                            SecureField("Paste or scan", text: $model.pairToken)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    Button {
                        tokenShown.toggle()
                    } label: {
                        Image(systemName: tokenShown ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(tokenShown ? "Hide the pairing token" : "Show the pairing token")
                    .accessibilityHint("The token lets this phone read the Mac's fleet.")
                }
            }
```

- [ ] **Step 4: Make Forget ask.** In `otherMacsSection`, change the swipe action to stage the Mac instead of forgetting it:

```swift
                .swipeActions {
                    Button("Forget", role: .destructive) { forgetting = other }
                }
```

and add the dialog to the `body`'s modifier chain, directly after the existing `.confirmationDialog("Make Primary", …)` block:

```swift
        .confirmationDialog("Forget This Mac?",
                            isPresented: Binding(get: { forgetting != nil },
                                                 set: { if !$0 { forgetting = nil } }),
                            presenting: forgetting) { other in
            Button("Forget \(other.pairing.name)", role: .destructive) {
                model.forgetOther(id: other.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { other in
            Text("This phone stops seeing \(other.pairing.name)'s fleet and sessions. The Mac itself is untouched — scan its QR code again to add it back.")
        }
```

- [ ] **Step 5: Build.**

```sh
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
    -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
```

Must exit 0.

- [ ] **Step 6: Fallback, only if Step 5's build or a read of the diff shows the header `EditButton` from Task 2 cannot work.** `EditButton` needs the `editMode` environment a `List`/`Form` inside a `NavigationStack` provides; both shells here (`RootView`'s tab and `SettingsScreen`'s sheet) supply one, so it should stand. If it does not compile, replace the header's `EditButton()` with a visible per-row delete affordance instead of removing the affordance entirely — in `addressesSection`'s `ForEach`, wrap the row:

```swift
                HStack {
                    Text(endpoint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(role: .destructive) {
                        model.manualEndpoints.removeAll { $0 == endpoint }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Remove address \(endpoint)")
                }
                .accessibilityElement(children: .combine)
```

and drop the `EditButton()` from the header. Report which of the two shipped.

- [ ] **Step 7: Commit.**

```sh
git add ios/InfinitusMobile/SettingsScreen.swift
git commit -m "phone settings: the pairing token is covered, and forgetting a Mac asks first

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: About — progress, Title-Case status, and a failure you can act on

The critique's iOS heuristics 1 and 9: "no progress while 'Update the Mac' runs", "`result = error.localizedDescription` with no retry affordance". Plus this section's three caption rows inside the group and its lowercase status values.

**Files:**
- Modify: `ios/InfinitusMobile/SettingsScreen.swift` (`AboutSettings` only — the `private struct` at the bottom of the file)
- Do not touch: `Sources/` (any target), every other `ios/InfinitusMobile/` file, `Sources/Infinitus/MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `CHANGELOG.md`, `ios/InfinitusMobile.xcodeproj`.

- [ ] **Step 1: Read the craft floor.** `craft-floor.md` ("Copy: … errors name the problem and the recovery") and `ios.md`.

- [ ] **Step 2: Replace the whole `AboutSettings` struct** — from its doc comment through its closing brace — with:

```swift
/// Both apps' versions, and the Mac's own update — one tap from the
/// phone, Homebrew doing the actual upgrade (#121). What the section
/// KNOWS is a row; what it EXPLAINS is the footer; a failure is a
/// sentence with a next step, never the error's own words.
private struct AboutSettings: View {
    @ObservedObject var model: MirrorModel
    @State private var confirming = false
    @State private var updating = false
    /// What the Mac reported back on a successful update.
    @State private var outcome: String?
    /// Set when the call failed; drives the Try Again row.
    @State private var failed = false

    private var phoneVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var phoneBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        Section {
            LabeledContent("This iPhone", value: "Infinitus \(phoneVersion) (\(phoneBuild))")
            if let snapshot = model.snapshot {
                if let app = snapshot.app {
                    LabeledContent(snapshot.machineName,
                                   value: "Infinitus \(app.version) · \(app.sha.prefix(7))")
                    if app.updateChannel != "source", let updateVersion = app.updateVersion {
                        LabeledContent("Mac update available: \(updateVersion)") {
                            if updating {
                                ProgressView()
                                    .accessibilityLabel("Updating the Mac")
                            } else {
                                Button("Update the Mac") { confirming = true }
                            }
                        }
                        .confirmationDialog("Update the Mac to \(updateVersion)?",
                                            isPresented: $confirming, titleVisibility: .visible) {
                            Button("Update") { update() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Homebrew upgrades Infinitus on \(snapshot.machineName) and relaunches it.")
                        }
                    }
                    if failed {
                        Button("Try Again") { update() }
                    }
                } else {
                    LabeledContent(snapshot.machineName, value: "Version Not Reported")
                }
            } else {
                LabeledContent("Mac", value: "Not Connected")
            }
        } header: {
            Text("About")
        } footer: {
            // Nothing to explain, no footer — filler prose under a
            // group is the caption row's sin in a different container.
            if !footer.isEmpty { Text(footer) }
        }
    }

    /// Everything this section EXPLAINS, in one footer: how the update
    /// went, why a source build has no button, and when the phone app
    /// itself is behind. Empty when there is nothing to say.
    private var footer: String {
        var lines: [String] = []
        if failed {
            lines.append("The Mac didn't take the update. Check that the Status line under Mac connection says it's reachable, then try again.")
        } else if let outcome {
            lines.append(outcome)
        }
        if let app = model.snapshot?.app {
            if app.updateChannel == "source" {
                lines.append("This Mac runs a build from the repository, so it updates from there rather than from here.")
            }
            if let phoneLatest = app.phoneLatest,
               let latest = PackageVersion(phoneLatest), let mine = PackageVersion(phoneVersion),
               mine < latest {
                lines.append("Infinitus \(phoneLatest) is out for the phone — rebuild this app from that release.")
            }
        }
        return lines.joined(separator: " ")
    }

    private func update() {
        updating = true
        outcome = nil
        failed = false
        Task {
            do {
                let reply = try await NetworkFleetMirror.shared.updateMac()
                outcome = reply.detail ?? reply.outcome
            } catch {
                // The error's own words are a debug string; the reader
                // needs the problem and the next step (critique,
                // heuristic 9). The Try Again row is that step.
                failed = true
            }
            updating = false
        }
    }
}
```

- [ ] **Step 3: Build.**

```sh
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
    -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
```

Must exit 0. If the compiler warns that `error` is unused in the `catch`, write `} catch {` with the body `failed = true` — the binding is implicit and unused on purpose; add `_ = error` only if the build treats it as an error.

- [ ] **Step 4: Commit.**

```sh
git add ios/InfinitusMobile/SettingsScreen.swift
git commit -m "phone settings: updating the Mac shows progress, and a failure says what to do next

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: The chat header scales with the reader's text size

The critique's minor observation: "`ChatHeader.swift` has 5 literal `.font(.system(size: N))` calls that won't scale with Dynamic Type." There are six at HEAD once `nameFont` (`:320`) is counted, and converting the fonts alone would overflow two fixed frames the same design pins — the portrait medallion (58pt) and the HUD bar (14pt). Both become `@ScaledMetric`, and the unit frame clamps at `.accessibility2` so a header that must fit above a transcript stays composed at the largest sizes.

**Files:**
- Modify: `ios/InfinitusMobile/ChatHeader.swift` — ONLY `ChatHeaderView`'s size constants and fonts (`:318–320`, `:351`, `:366`, `:415`, `:418`, `:428`, `:430`, `:462`) and the `hud` view's clamp
- Do not touch: `Sources/` (any target), every other `ios/InfinitusMobile/` file including `SettingsScreen.swift`, `Sources/Infinitus/MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `CHANGELOG.md`, `ios/InfinitusMobile.xcodeproj`. Nothing about `ChatHeaderData`, routing, `hudBar`'s gauge arguments, `ChatHeaderPicker` or any effect changes.

- [ ] **Step 1: Read the craft floor.** `craft-floor.md` and `ios.md` ("**Dynamic Type.** Use the system text styles … No hard-coded point sizes"). Then read `ios/InfinitusMobile/ChatHeader.swift` lines 100–120 (the `ChatHeaderView` declaration) and 310–470.

- [ ] **Step 2: Replace the three size constants.** At lines 318–320, `hudCorner`, `portraitSize` and `nameFont` currently read:

```swift
    private var hudCorner: CGFloat { 8 }
    private var portraitSize: CGFloat { 58 }
    private var nameFont: Font { .system(size: 14, weight: .heavy, design: .rounded) }
```

Replace with (note: `@ScaledMetric` must be a stored property, so these move from computed vars to wrapped stored ones; `hudCorner` stays a plain constant — a corner radius is not type):

```swift
    private var hudCorner: CGFloat { 8 }
    /// The medallion, the HUD bar and the tier disc are drawn shapes
    /// that sit beside text — they scale with it, or the frame bursts at
    /// the larger reading sizes (ios.md: no hard-coded point sizes).
    @ScaledMetric(relativeTo: .title2) private var portraitSize = 58.0
    @ScaledMetric(relativeTo: .caption2) private var hudBarHeight = 14.0
    @ScaledMetric(relativeTo: .caption2) private var tierDisc = 22.0
    private var nameFont: Font { .system(.subheadline, design: .rounded).weight(.heavy) }
```

- [ ] **Step 3: The five remaining fonts.** Each is a one-line replacement; keep every other modifier on the call.

  * `:351` (the status word beside the name): `.font(.system(size: 10, weight: .bold))` → `.font(.caption2.weight(.bold))`
  * `:366` (the account · Mac line): `.font(.system(size: 9, weight: .semibold))` → `.font(.caption2.weight(.semibold))`
  * `:415` (the medallion's initial when the theme has no glyph): `.font(.system(size: 24, weight: .heavy, design: .rounded))` → `.font(.system(.title2, design: .rounded).weight(.heavy))`
  * `:418` (the medallion's themed glyph): `Text(glyph).font(.system(size: 27))` → `Text(glyph).font(.title)`
  * `:428` (the plan tier on the ring): `.font(.system(size: 9, weight: .heavy, design: .rounded))` → `.font(.system(.caption2, design: .rounded).weight(.heavy))`

- [ ] **Step 4: The two frames the fonts drive.**

  * `:430` — the tier capsule's `.frame(minWidth: 22, minHeight: 22)` → `.frame(minWidth: tierDisc, minHeight: tierDisc)`
  * `:462` — `hudBar`'s `.frame(height: 14)` → `.frame(height: hudBarHeight)`

  `portraitSize` is already read everywhere it is needed (`:372`, `:393`, `:410`, `:421`) and now scales with them.

- [ ] **Step 5: Clamp the unit frame.** The Game HUD is a fixed-shape badge above a transcript; past `.accessibility2` it stops being a header and starts being the screen. Add the clamp as the LAST modifier on the `hud` view — the chain currently ends:

```swift
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 6)
    }
```

Make it:

```swift
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 6)
        // The medallion and its bars are one badge: they scale with the
        // reader's size up to accessibility2, past which the header
        // would push the transcript off the screen. Compact and Stat
        // strip, which are plain rows, keep scaling all the way.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
```

- [ ] **Step 6: Build.**

```sh
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
    -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
```

Must exit 0.

- [ ] **Step 7: Confirm nothing hard-coded is left in the file.**

```sh
grep -n "font(.system(size:" ios/InfinitusMobile/ChatHeader.swift
```

Must print nothing. (`PopupFont.caption`'s fixed 10pt lives in `Sources/InfinitusUI/PopupFont.swift` and is deliberate — it keeps the phone's gauges matched to the Mac popup's — and is not touched by this stream.)

- [ ] **Step 8: Commit.**

```sh
git add ios/InfinitusMobile/ChatHeader.swift
git commit -m "phone: the chat header scales with the reader's text size

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: CHANGELOG and the full gate (last task)

**Files:**
- Modify: `CHANGELOG.md` (under `## 0.4.4 (unreleased)` → `### Phone`)
- Do not touch: everything in the forbidden list above, plus `site/` and `README.md`.

- [ ] **Step 1: The lines.** Insert at the TOP of the `### Phone` list — immediately after the `### Phone` header line, before the existing "Parked sessions: …" line. One short sentence each; no `Phone:` prefix (the section names itself, and none of the existing lines carries one):

```
- Settings' theme chooser shows every theme as a live row — its gauges, spend line, status word and tab bar — and the Theme row carries its colours.
- Pace fire, content entrance and title flourish are picked from tiles that show the effect instead of a menu of words.
- The pairing token is covered until you tap to reveal it.
- Forgetting a paired Mac asks first and says what it costs.
- Settings leads with the Mac connection: with nothing paired, scanning the Mac's QR code is the first thing on screen.
- Every group in Settings explains itself in a footer, and the Mac's addresses are labelled and editable.
- Updating the Mac from the phone shows its progress and offers Try Again with a plain reason when it fails.
- The chat header scales with the phone's text size.
```

- [ ] **Step 2: The full gate**, in this order, from the worktree root:

```sh
cd ios && xcodegen generate && xcodebuild -quiet -project InfinitusMobile.xcodeproj \
    -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
cd .. && swift test
```

Both must succeed. `swift test` covers `InfinitusCore` and `InfinitusUI`, which this stream never edited — it is the proof that the phone-only work left the shared targets alone.

- [ ] **Step 3: Confirm the generated project is not staged.**

```sh
git status --short
```

`ios/InfinitusMobile.xcodeproj` must not appear as staged. If it is tracked from an earlier mistake, stop and report rather than committing it.

- [ ] **Step 4: Commit.**

```sh
git add CHANGELOG.md
git commit -m "changelog: the phone's Settings polish (0.4.4)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Coverage against the stream brief's nine items.** (1) Theme chooser as a pushed screen of live previews — gauges, credit/model line with the cash icon, four-item tab-bar mock, a status word, "Names like: …", a checkmark, immediate selection, scroll-into-view, plus the swatch on the Settings row: Task 3. (2) Pace fire / content entrance / title flourish tiles, with the per-option decision written out — pace fire uses the REAL `GaugeBar` + `BurnOverlay` CA path, the other two are drawn frames with one-shot replays because their renderers are `FleetModel` modifiers: Task 4. (3) `SecureField` with a reveal, labelled, placeholder rewritten to "Paste or scan" with the Mac's Devices settings moved into the footer: Task 5. (4) Forget's `confirmationDialog` naming the Mac and the consequence; endpoint rows labelled with an `EditButton` in the section header and a named fallback: Tasks 2 and 5. (5) Form consistency — twelve headed-and-footed sections, all four caption rows converted, the picker-style rule stated: Task 2, and the rule is written below. (6) The unpaired hierarchy — "Pair with a Mac" first with the prominent scan, Other Macs hidden, cosmetics below: Task 2. (7) Progress in the update row and a retryable failure sentence: Task 6. (8) Search skipped, with the reason: "What this plan deliberately does NOT do". (9) ChatHeader's hard-coded sizes: Task 7.
- **The picker-style rule, in one line:** options that can be SHOWN get a pushed screen whose rows are the previews (Theme, Pace fire, Content entrance, Title flourish, and the already-correct chat header); word-only short lists stay a menu (Non-English dictation, three options); a word-only list too long for a menu keeps `.pickerStyle(.navigationLink)` (Dictation Language). Dictation's two pickers are therefore correct as they stand and are not touched.
- **Performance.** The only continuous motion added is `BurnOverlay`, which is Core Animation on a `LayerEffect` host and exists only on the pace-fire chooser screen. Everything else is one-shot: `EntranceTile` and `FlourishTile` animate on a tap and stop. No `TimelineView`, no `repeatForever`, no `.contentTransition(.numericText)` on a ticking value — the theme previews pass `animated: false`, and the pace-fire tile's percent never changes.
- **Accessibility.** Every preview row is one `.accessibilityElement(children: .ignore)` with an explicit label in the theme's own words and `.isSelected` when chosen; the decorative tiles are `.accessibilityHidden(true)` and `.allowsHitTesting(false)`; the two icon-only buttons this round adds (the token's eye, the fallback address delete) carry labels and, for the eye, a hint; every animation checks `accessibilityReduceMotion`; every hard-coded font size in the touched files is gone.
- **Ownership.** No edit outside `ios/InfinitusMobile/{SettingsScreen,ChatHeader,ThemeSwatch,ThemeChooserScreen,MotionChooser}.swift`, `.impeccable/critique/` and `CHANGELOG.md`. `Sources/InfinitusCore/RowTheme.swift` needed no accessor (every field was already public), so the core suite cannot regress; `RootView.swift`, `MobileLock.swift` and `ThemedPlaceholder.swift` were read and need no change. Nothing under `Sources/Infinitus/`, `Sources/InfinitusUI/`, `Team*`, `MirrorServer.swift` or `tools/e2e.sh` is touched.
- **Type consistency.** The option tag strings are written identically in `MotionChooser.swift`'s three `options` arrays, in `SettingsScreen.swift`'s three `…Names` dictionaries and in the defaults `MirrorModel` reads (`burn_style` ember/flame/limit/off, `intro_style` top/bottom/fade/rows, `intro_title` zoom/slam/spin/off). `ThemePreviewRow`'s signature (`theme:` plus a defaulted `selected:`) keeps the one existing call site shape it had; that call site is deleted in the same task that moves the type.
