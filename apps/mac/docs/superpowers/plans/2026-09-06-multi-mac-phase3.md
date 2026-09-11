# Multi-Mac phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Other paired Macs keep an on-disk cache and show "parked" while away, and the "+" sheet / Past sessions can start a session on any paired Mac.

**Architecture:** `NetworkFleetMirror` resolves its `ParkedCache` root from its storage's token, so a `.pairing` instance caches under `parked/<token hash>/` exactly like the primary. `MirrorModel` gains per-Mac accessors on the phase 2 pattern (`nil` = primary) plus `requestedMacId`; the Sessions tab routes a requested pid to `OtherSessionRoute` when a Mac id is set. The two start surfaces get a Mac picker that swaps which snapshot and mirror they read.

**Tech Stack:** Swift 6, SwiftUI (iOS), InfinitusCore (`ParkedCache`, `Outbox`, `MacPairing`). Verification is a simulator build per task (no phone unit-test target).

**Spec:** `docs/superpowers/specs/2026-09-06-multi-mac-phase3-design.md`

## Global Constraints

- Surgical changes; match existing style; no speculative abstractions.
- Nothing inside the `// MARK: team` block of `ios/InfinitusMobile/NetworkFleetMirror.swift` (another stream owns it).
- Any reachable/answered decision keys on `lastServedFromCache` / `OtherMac.parked`, never on `snapshot != nil`.
- `StartSessionIntent`, the share extension, widgets and Live Activities stay primary-only.
- No continuous SwiftUI motion; idle CPU ~0%.
- Commit by explicit path only (never `git add -A`); every commit ends with `Co-Authored-By: Claude Code <noreply@anthropic.com>`.
- CHANGELOG: one feature, one line, under `## 0.4.4 (unreleased)` › `### Phone`. README feature: one line.
- Build check after every task: `cd ios && xcodegen generate > /dev/null && xcodebuild -project InfinitusMobile.xcodeproj -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/infinitus-mm3-dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | head` → expects `** BUILD SUCCEEDED **` and no `error:` lines.

---

### Task 1: Per-Mac disk cache and forget cleanup

**Files:**
- Modify: `ios/InfinitusMobile/NetworkFleetMirror.swift` (lines ~49-53 `parkedCache`, ~110-141 `init`s and `forgetCached`)
- Modify: `ios/InfinitusMobile/MirrorModel.swift` (`forgetOther(id:)`, ~line 247)

**Interfaces:**
- Consumes: `ParkedCache(root:)`, `.clear()` (InfinitusCore); `Outbox.items(macKey:)`, `.remove(id:)`; `OutboxDelivery.outbox`; `NetworkFleetMirror.parkedKey(token:)`.
- Produces: `nonisolated static func parkedCache(key: String) -> ParkedCache` on `NetworkFleetMirror`; the existing `parkedCache` property now delegates to it.

- [ ] **Step 1: Cache root per key**

In `NetworkFleetMirror.swift` replace the `parkedCache` property:

```swift
    /// The disk cache root for one Mac's key — `parked/<token hash>/`
    /// under App Support, the primary's and every other Mac's alike
    /// (#144 phase 3).
    nonisolated static func parkedCache(key: String) -> ParkedCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ParkedCache(root: support.appendingPathComponent("parked").appendingPathComponent(key))
    }

    /// The primary Mac's cache.
    nonisolated static var parkedCache: ParkedCache { parkedCache(key: parkedKey()) }
```

- [ ] **Step 2: A pairing instance gets its own cache**

In `init(pairing:onLastGood:)` replace `parked = nil` with:

```swift
        parked = Self.parkedCache(key: Self.parkedKey(token: pairing.token))
        cached = parked?.loadSnapshot()
```

Update the doc comment on `private var parked` — replace the sentence "other Macs stay read-only in phase 1 (`nil`)" with "each other Mac's instance holds its own (#144 phase 3)".

- [ ] **Step 3: `forgetCached()` follows the storage**

Replace the body's `parked = Self.parkedCache` line and its comment with:

```swift
        // The pairing changed underneath this instance — re-resolve the
        // cache from what this instance authenticates as, never the
        // primary's key on a per-Mac instance.
        switch storage {
        case .defaults: parked = Self.parkedCache
        case .pairing(let pairing): parked = Self.parkedCache(key: Self.parkedKey(token: pairing.token))
        }
```

- [ ] **Step 4: Forgetting a Mac drops its cache and queue**

In `MirrorModel.forgetOther(id:)`, before `var list = MacPairing.load(defaults)`, add:

```swift
        // Its parked cache and queued messages go with it — nothing would
        // flush them once the pairing is gone (#144 phase 3).
        if let token = other(id)?.pairing.token {
            let key = NetworkFleetMirror.parkedKey(token: token)
            NetworkFleetMirror.parkedCache(key: key).clear()
            for item in OutboxDelivery.outbox.items(macKey: key) { OutboxDelivery.outbox.remove(id: item.id) }
        }
```

- [ ] **Step 5: Build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/InfinitusMobile/NetworkFleetMirror.swift ios/InfinitusMobile/MirrorModel.swift
git commit -m "phone: every other Mac keeps its own parked cache; forgetting a Mac drops its cache and queue

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: "parked" beside an other Mac's name

**Files:**
- Modify: `ios/InfinitusMobile/SessionsScreen.swift` (`otherMacSections`, ~line 180)
- Modify: `ios/InfinitusMobile/FleetScreen.swift` (`otherMacsArea`, ~line 122)
- Modify: `ios/InfinitusMobile/SettingsScreen.swift` (`otherCaption`, ~line 216; Other Macs footer, ~line 158)

**Interfaces:**
- Consumes: `MirrorModel.OtherMac.parked: Bool` (present on this branch), `OtherMac.snapshot?.capturedAt`.

- [ ] **Step 1: Sessions section header**

Replace the header `Text(other.pairing.name)` in `otherMacSections` with:

```swift
            } header: {
                HStack(spacing: 6) {
                    Text(other.pairing.name)
                    if other.parked {
                        Label("parked", systemImage: "moon.zzz").labelStyle(.titleAndIcon)
                    }
                }
            }
```

- [ ] **Step 2: Fleet title**

In `FleetScreen.otherMacsArea` replace the `Text(other.pairing.name)` block (three lines through `.foregroundStyle(.secondary)`) with:

```swift
                    HStack(spacing: 6) {
                        Text(other.pairing.name)
                        if other.parked {
                            Label("parked", systemImage: "moon.zzz")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
```

- [ ] **Step 3: Settings caption and footer**

In `otherCaption(_:)`, after the `guard other.snapshot != nil else { … }` block, add:

```swift
        if other.parked, let seen = other.snapshot?.capturedAt {
            return "parked — last seen \(seen.formatted(.relative(presentation: .named)))"
        }
```

Replace the Other Macs section footer text with:

```swift
                Text("Scan another Mac's QR to add it; widgets and Live Activities follow the primary Mac.")
```

- [ ] **Step 4: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/InfinitusMobile/SessionsScreen.swift ios/InfinitusMobile/FleetScreen.swift ios/InfinitusMobile/SettingsScreen.swift
git commit -m "phone: an other Mac that is away says parked beside its name on Sessions, Fleet and Devices

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: Per-Mac start accessors and the requested-session hop

**Files:**
- Modify: `ios/InfinitusMobile/MirrorModel.swift` (accessor block after `macName(_:)`, ~line 121; `requestedPid` ~line 585)
- Modify: `ios/InfinitusMobile/SessionsScreen.swift` (`onChange` lines ~36-37; `openRequestedPid()` ~line 197)

**Interfaces:**
- Produces on `MirrorModel`: `func profiles(macId: String?) -> [SessionProfile]`, `func recentCwds(macId: String?) -> [String]`, `func machineName(macId: String?) -> String`, `@Published var requestedMacId: String?`.
- Contract for callers (Tasks 4, 5): set `requestedMacId` FIRST, then `requestedPid`, both synchronously on the main actor.

- [ ] **Step 1: Accessors**

In `MirrorModel`, directly after `func macName(_ macId: String?) -> String? { … }`, add:

```swift
    /// The Mac a session starts on (#144 phase 3): its profiles, its
    /// folders, its name. `nil` is the primary.
    func profiles(macId: String?) -> [SessionProfile] {
        guard let macId else { return snapshot?.profiles ?? [] }
        return other(macId)?.snapshot?.profiles ?? []
    }

    func recentCwds(macId: String?) -> [String] {
        guard let macId else { return recentCwds }
        return other(macId)?.snapshot?.recentCwds ?? []
    }

    func machineName(macId: String?) -> String {
        guard let macId else { return snapshot?.machineName ?? "the Mac" }
        return other(macId)?.pairing.name ?? "the Mac"
    }
```

- [ ] **Step 2: `requestedMacId`**

Directly after `@Published var requestedPid: Int?` add:

```swift
    /// The Mac `requestedPid` lives on (#144 phase 3); `nil` is the
    /// primary. Set BEFORE `requestedPid` so its observer sees both.
    @Published var requestedMacId: String?
```

- [ ] **Step 3: Route the hop**

Replace `openRequestedPid()` in `SessionsScreen`:

```swift
    /// A session started from the + sheet or Past sessions: its chat
    /// opens the moment its Mac's snapshot lists the pid — on the
    /// primary's route, or the other Mac's (#144 phase 3).
    private func openRequestedPid() {
        guard let pid = model.requestedPid else { return }
        if let macId = model.requestedMacId {
            guard let other = model.other(macId) else {
                // Forgotten while we waited — nothing to open.
                model.requestedMacId = nil
                model.requestedPid = nil
                return
            }
            guard let session = other.fleets.flatMap({ $0.liveSessions?.sessions ?? [] })
                .first(where: { $0.pid == pid }) else { return }
            model.requestedMacId = nil
            model.requestedPid = nil
            path = NavigationPath()
            path.append(OtherSessionRoute(macId: macId, session: session))
            return
        }
        guard let session = fleetsWithSessions.flatMap({ $0.liveSessions?.sessions ?? [] })
            .first(where: { $0.pid == pid }) else { return }
        model.requestedPid = nil
        path = NavigationPath()
        path.append(session)
    }
```

- [ ] **Step 4: Watch the other Macs' snapshots too**

After `.onChange(of: model.snapshot?.capturedAt) { _, _ in openRequestedPid() }` add:

```swift
                // The pid of a session started on another Mac shows up in
                // THAT Mac's snapshot, which never moves the primary's.
                .onChange(of: model.others.map { $0.snapshot?.capturedAt }) { _, _ in openRequestedPid() }
```

- [ ] **Step 5: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/InfinitusMobile/MirrorModel.swift ios/InfinitusMobile/SessionsScreen.swift
git commit -m "phone: a requested session opens on the Mac it started on

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: The "+" sheet picks a Mac

**Files:**
- Modify: `ios/InfinitusMobile/StartSessionSheet.swift`

**Interfaces:**
- Consumes: `model.profiles(macId:)`, `model.recentCwds(macId:)`, `model.machineName(macId:)`, `model.mirror(for:)`, `model.refresh(macId:)`, `model.others`, `model.requestedMacId` (Task 3 contract: set before `requestedPid`).

- [ ] **Step 1: State and the Mac section**

Add after `@State private var profile: SessionProfile?`:

```swift
    /// Which paired Mac starts it (#144 phase 3); `nil` is the primary.
    @State private var macId: String?
```

At the top of the `Form`, before the profiles `if`, add:

```swift
                if !model.others.isEmpty {
                    Section("Mac") {
                        Picker("Mac", selection: $macId) {
                            Text(model.machineName(macId: nil)).tag(String?.none)
                            ForEach(model.others) { other in
                                Text(other.pairing.name).tag(String?.some(other.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
```

- [ ] **Step 2: Read from the chosen Mac**

- `if let profiles = model.snapshot?.profiles, !profiles.isEmpty {` → `if !model.profiles(macId: macId).isEmpty {` and `ForEach(profiles)` → `ForEach(model.profiles(macId: macId))`.
- Both `model.recentCwds` in the Repository picker and `.onAppear` → `model.recentCwds(macId: macId)`.
- In `apply(_:)`: `model.recentCwds.contains(folder)` → `model.recentCwds(macId: macId).contains(folder)`.

- [ ] **Step 3: Reset on Mac change**

After `.onAppear { … }` add:

```swift
            .onChange(of: macId) { _, _ in
                // A different Mac: its own folders and profiles, the rest
                // of the form (engine, prompt, permissions) stays typed.
                profile = nil
                error = nil
                cwd = model.recentCwds(macId: macId).first ?? Self.other
            }
```

- [ ] **Step 4: Start through that Mac**

In `start()`:
- `NetworkFleetMirror.shared.startSession(request)` → `model.mirror(for: macId).startSession(request)`
- `if let pid = reply.pid { model.requestedPid = pid }` →
  ```swift
                if let pid = reply.pid {
                    model.requestedMacId = macId
                    model.requestedPid = pid
                }
  ```
- `await model.refresh()` → `await model.refresh(macId: macId)`

Update the type doc comment's first sentence to "Start a session on a Mac from the phone (#91; any paired Mac since #144 phase 3)".

- [ ] **Step 5: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/InfinitusMobile/StartSessionSheet.swift
git commit -m "phone: the + sheet starts a session on any paired Mac

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: Past sessions picks a Mac, and the notes

**Files:**
- Modify: `ios/InfinitusMobile/PastSessionsScreen.swift`
- Modify: `CHANGELOG.md` (under `## 0.4.4 (unreleased)` › `### Phone`, after the "Other Macs' sessions open like the primary's" line)
- Modify: `README.md` (after the "**Every Mac's chats**" line, ~137)

**Interfaces:**
- Consumes: same as Task 4.

- [ ] **Step 1: State and toolbar menu**

Add after `@State private var resuming: String?`:

```swift
    /// Which paired Mac's history (#144 phase 3); `nil` is the primary.
    @State private var macId: String?
```

After `.searchable(...)` add:

```swift
        .toolbar {
            if !model.others.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Mac", selection: $macId) {
                            Text(model.machineName(macId: nil)).tag(String?.none)
                            ForEach(model.others) { other in
                                Text(other.pairing.name).tag(String?.some(other.id))
                            }
                        }
                    } label: {
                        Label(model.machineName(macId: macId), systemImage: "desktopcomputer")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .onChange(of: macId) { _, _ in
            sessions = []
            Task { await load() }
        }
```

- [ ] **Step 2: Load and resume through that Mac**

- In `load()`: `NetworkFleetMirror.shared.pastSessions(` → `model.mirror(for: macId).pastSessions(`.
- In `resume(_:fork:)`: `NetworkFleetMirror.shared.startSession(request)` → `model.mirror(for: macId).startSession(request)`; `if let pid = reply.pid { model.requestedPid = pid }` →
  ```swift
                if let pid = reply.pid {
                    model.requestedMacId = macId
                    model.requestedPid = pid
                }
  ```
  and `await model.refresh()` → `await model.refresh(macId: macId)`.

- [ ] **Step 3: Notes**

CHANGELOG, one line after the phase 2 line:

```
- Other Macs park too: their fleets, sessions and transcripts stay on the phone while they're away, and the "+" sheet and Past sessions can start a session on any paired Mac (#144).
```

README, one line after "**Every Mac's chats**":

```
- **Start on any Mac** — the "+" sheet and Past sessions pick which paired Mac runs the session; a Mac that's away keeps its sessions on the phone, marked parked.
```

- [ ] **Step 4: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/InfinitusMobile/PastSessionsScreen.swift CHANGELOG.md README.md
git commit -m "phone: past sessions resume on any paired Mac; notes for phase 3

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```
