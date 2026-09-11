# Multi-Mac phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session under another paired Mac's section opens like any other, and its transcript, replies, keys, approvals, mode changes, checkpoints, images and queued messages go to THAT Mac.

**Architecture:** The session's Mac id rides on every navigation value pushed from an other-Mac feed (`OtherSessionRoute`, `SessionDetailRoute.macId`, `CheckpointsRoute.macId`); each pushed screen resolves its `NetworkFleetMirror` through `MirrorModel.mirror(for:)` and hands it to same-body children through one environment value. Per-Mac data (progress, account, AWS login, births, transport status) comes from `macId`-aware accessors on `MirrorModel`, and the outbox keys items per Mac and flushes each Mac on its own reachable edge.

**Tech Stack:** SwiftUI iOS app (`ios/`, xcodegen + xcodebuild, no unit-test target). InfinitusCore and the Mac app are untouched.

**Spec:** `docs/superpowers/specs/2026-09-06-multi-mac-phase2-design.md`

## Global Constraints

- Every commit ends with `Co-Authored-By: Claude Code <noreply@anthropic.com>` (the repo hook adds it; write it anyway).
- Stage by explicit path; never `git add -A`; never amend, stash or rebase.
- Surgical changes; match the surrounding style; no speculative abstractions; comments explain why, in the repo's voice.
- No engine internals; no `~/.claude-swap-backup/*`. Never `NetworkFleetMirror.shared` in the four session screens after Task 5.
- Every task ends with a green simulator build:
  `cd ios && xcodegen generate > /dev/null && xcodebuild -project InfinitusMobile.xcodeproj -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/infinitus-mm2-dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | head`
  Expected last line: `** BUILD SUCCEEDED **`. Run it from the repo root.
- `macId == nil` means the primary Mac and must behave exactly as today; every new accessor returns today's value for nil.
- A pushed destination gets the environment of where `.navigationDestination` is declared (SessionsScreen), not of the pusher — so `macId` travels in the route value, never only in the environment.
- Flush per Mac on that Mac's own reachable edge, never once per poll round.
- CHANGELOG: one feature, one line, under `## 0.4.4 (unreleased)` › `### Phone`. README: one bold-lead line.

---

### Task 1: `MirrorModel` per-Mac accessors, `parkedKey(token:)`, per-Mac reachable edge

**Files:**
- Modify: `ios/InfinitusMobile/MirrorModel.swift` (struct `OtherMac` ~line 52; `refreshOthers()` ~line 352; `otherMirror(for:)` ~line 395; `reachableAgain` ~line 46)
- Modify: `ios/InfinitusMobile/NetworkFleetMirror.swift` (`parkedKey(defaults:)` ~line 35)

**Interfaces:**
- Consumes: `MirrorModel.others: [OtherMac]`, `OtherMac.pairing: MacPairing` (`id`, `name`, `token`), `OtherMac.snapshot: MirrorSnapshot?` (`progressByPid: [Int: SessionProgress]?`, `awsLogins: [AwsLogin.Item]?`, `births: [Int: SessionBirth]?`), `OtherMac.fleets: [MirrorFleetModel]`, `OtherMac.status: String`, `Self.engineFleets(from:) -> [EngineFleet]?`, `SessionAccountLookup.summarize(pid:fleets:)`, `MirrorPairing.normalize(_:)`.
- Produces (all on `MirrorModel`, `@MainActor`):
  - `func other(_ macId: String) -> OtherMac?`
  - `func mirror(for macId: String?) -> NetworkFleetMirror`
  - `func progress(macId: String?, pid: Int) -> SessionProgress?`
  - `func accountSummary(macId: String?, pid: Int) -> SessionAccountSummary?`
  - `func fleets(macId: String?) -> [MirrorFleetModel]`
  - `func awsLogin(macId: String?, pid: Int) -> AwsLogin.Item?`
  - `func birth(macId: String?, pid: Int) -> SessionBirth?`
  - `func transportStatus(macId: String?) -> String`
  - `func macName(_ macId: String?) -> String?`
  - `func refresh(macId: String?) async`
  - `var otherReachable: ((String) -> Void)?` — fired with a Mac id on that Mac's unreachable → reachable edge and on its first answered poll.
  - `NetworkFleetMirror.parkedKey(token:) -> String` (nonisolated static).

- [ ] **Step 1: `parkedKey(token:)`**

In `NetworkFleetMirror.swift` replace the body of `parkedKey(defaults:)` so it delegates:

```swift
    nonisolated static func parkedKey(defaults: UserDefaults = .standard) -> String {
        parkedKey(token: defaults.string(forKey: tokenKey) ?? "")
    }

    /// #144 phase 2: the same key for any Mac's token — the outbox files
    /// one queue per Mac under it. Normalized exactly as `pairToken()`
    /// normalizes the primary's, so both spellings of one token agree.
    nonisolated static func parkedKey(token raw: String) -> String {
        let token = MirrorPairing.normalize(raw)
        guard !token.isEmpty else { return "local" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
```

- [ ] **Step 2: accessors on `MirrorModel`**

Directly below `private var otherMirrors: [String: NetworkFleetMirror] = [:]` add:

```swift
    /// Runs with a Mac's id when that Mac answers after not answering
    /// (or on its first answered poll) — the per-Mac outbox flush (#144
    /// phase 2). Per Mac, not per round: a Mac that stays down must not
    /// re-flush every other Mac's queue every poll.
    var otherReachable: ((String) -> Void)?
    private var othersReachable: Set<String> = []

    // MARK: per-Mac reads (#144 phase 2) — `nil` is the primary and
    // returns exactly what the screens read before other Macs opened.

    func other(_ macId: String) -> OtherMac? { others.first { $0.id == macId } }

    /// The mirror a session's screens talk to: the primary's, or the
    /// cached one for its Mac. An unknown id (forgotten while a feed
    /// was open) falls back to the primary rather than a dead actor.
    func mirror(for macId: String?) -> NetworkFleetMirror {
        guard let macId, let pairing = other(macId)?.pairing else { return .shared }
        return otherMirror(for: pairing)
    }

    func progress(macId: String?, pid: Int) -> SessionProgress? {
        guard let macId else { return sessionProgress.byPid[pid] }
        return other(macId)?.snapshot?.progressByPid?[pid]
    }

    func accountSummary(macId: String?, pid: Int) -> SessionAccountSummary? {
        guard let macId else { return accountSummary(forSessionPid: pid) }
        guard let snapshot = other(macId)?.snapshot,
              let fleets = Self.engineFleets(from: snapshot) else { return nil }
        return SessionAccountLookup.summarize(pid: pid, fleets: fleets)
    }

    func fleets(macId: String?) -> [MirrorFleetModel] {
        guard let macId else { return fleets }
        return other(macId)?.fleets ?? []
    }

    func awsLogin(macId: String?, pid: Int) -> AwsLogin.Item? {
        guard let macId else { return awsLogin(for: pid) }
        return other(macId)?.snapshot?.awsLogins?.first { $0.pid == pid }
    }

    func birth(macId: String?, pid: Int) -> SessionBirth? {
        guard let macId else { return snapshot?.births?[pid] }
        return other(macId)?.snapshot?.births?[pid]
    }

    func transportStatus(macId: String?) -> String {
        guard let macId else { return transportStatus }
        return other(macId)?.status ?? ""
    }

    func macName(_ macId: String?) -> String? {
        macId.flatMap { other($0)?.pairing.name }
    }

    /// Pull-to-refresh and post-action refresh for a session's own Mac.
    func refresh(macId: String?) async {
        if macId == nil { await refresh() } else { await refreshOthers() }
    }
```

`accountSummary(forSessionPid:)` is defined in `extension MirrorModel` in `MirrorFleetModel.swift` line 179; the nil branch calls it as-is.

- [ ] **Step 3: the per-Mac edge in `refreshOthers()`**

`refreshOthers()` is `private`; keep it private (Step 2's `refresh(macId:)` is inside the class). At its end, after `others = pairings.map { … }`, add:

```swift
        // Per-Mac reachable edge: newly answering ids fire once; a Mac
        // still down stays out of the set and fires nothing.
        let answered = Set(others.compactMap { $0.snapshot == nil ? nil : $0.id })
        let newlyReachable = answered.subtracting(othersReachable)
        othersReachable = answered
        for id in newlyReachable { otherReachable?(id) }
```

Note `othersReachable` starts empty, so the first completed round fires for every Mac that answered (the "first load" case). A Mac forgotten from pairings drops out of `answered`, so it fires again if re-paired and answering.

- [ ] **Step 4: build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/InfinitusMobile/MirrorModel.swift ios/InfinitusMobile/NetworkFleetMirror.swift
git commit -m "phone: MirrorModel reads per Mac — mirror, progress, account, births, status keyed by macId; per-Mac reachable edge (#144)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: Routes carry `macId`; one environment mirror; other Macs' rows open

**Files:**
- Create: `ios/InfinitusMobile/SessionMirror.swift`
- Modify: `ios/InfinitusMobile/SessionDetailScreen.swift` (`struct SessionDetailRoute` line 8; `struct SessionDetailScreen` line 87)
- Modify: `ios/InfinitusMobile/CheckpointsScreen.swift` (`struct CheckpointsRoute` line 5; `struct CheckpointsScreen` line 14)
- Modify: `ios/InfinitusMobile/SessionFeedScreen.swift` (`struct SessionFeedScreen` line 12)
- Modify: `ios/InfinitusMobile/SessionsScreen.swift` (destinations lines 38–52; `otherMacSections` ~line 173; `row(_:)` ~line 218, `title(_:)` ~line 310, `metadata(_:)` ~line 325)

**Interfaces:**
- Consumes: Task 1's `model.mirror(for:)`, `model.progress(macId:pid:)`, `model.awsLogin(macId:pid:)`, `model.birth(macId:pid:)`.
- Produces: `struct OtherSessionRoute: Hashable { let macId: String; let session: SessionDetail }`; `EnvironmentValues.sessionMirror: NetworkFleetMirror` (default `.shared`); `SessionDetailRoute(session:macId:)` and `CheckpointsRoute(session:macId:)` with `macId: String? = nil`; `SessionFeedScreen(model:session:macId:)`, `SessionDetailScreen(model:progress:session:macId:)`, `CheckpointsScreen(session:macId:)` each with `let macId: String?` defaulting to nil (behaviour wired in Tasks 4–5; this task only threads the value and keeps the build green).

- [ ] **Step 1: the environment key and the route**

Create `ios/InfinitusMobile/SessionMirror.swift`:

```swift
import SwiftUI

/// #144 phase 2: the mirror a session's screens talk to. Screens reached
/// from another Mac's section set it to that Mac's mirror; everything
/// else inherits the primary. Same-body children only — a pushed
/// destination gets the environment of where its
/// `.navigationDestination` is declared, so a route carries `macId`
/// and the destination sets this itself.
private struct SessionMirrorKey: EnvironmentKey {
    static let defaultValue: NetworkFleetMirror = .shared
}

extension EnvironmentValues {
    var sessionMirror: NetworkFleetMirror {
        get { self[SessionMirrorKey.self] }
        set { self[SessionMirrorKey.self] = newValue }
    }
}

/// A session under another paired Mac's section: the Mac travels with
/// the navigation value so two Macs' feeds can sit on one stack.
struct OtherSessionRoute: Hashable {
    let macId: String
    let session: SessionDetail
}
```

- [ ] **Step 2: `macId` on the two existing routes and three screens**

`SessionDetailScreen.swift` line 8:

```swift
struct SessionDetailRoute: Hashable {
    let session: SessionDetail
    /// The session's Mac when it isn't the primary (#144 phase 2).
    var macId: String? = nil
}
```

`CheckpointsScreen.swift` line 5, the same shape:

```swift
struct CheckpointsRoute: Hashable {
    let session: SessionDetail
    var macId: String? = nil
}
```

Add a stored property to each screen, right after its `let session: SessionDetail`:

```swift
    /// `nil` is the primary Mac (#144 phase 2).
    var macId: String? = nil
```

in `SessionFeedScreen` (line ~14), `SessionDetailScreen` (line ~90) and `CheckpointsScreen` (line ~15). Memberwise inits keep every existing call site compiling.

- [ ] **Step 3: SessionsScreen destinations and rows**

In `SessionsScreen.body`, replace the two destinations at lines 46–52 with:

```swift
                .navigationDestination(for: SessionDetailRoute.self) { route in
                    SessionDetailScreen(model: model, progress: progress, session: route.session, macId: route.macId)
                }
                .navigationDestination(for: CheckpointsRoute.self) { route in
                    CheckpointsScreen(session: route.session, macId: route.macId)
                }
                // Another Mac's session (#144 phase 2): its own feed, its
                // own Mac. Sits beside the primary's destination so both
                // can stack.
                .navigationDestination(for: OtherSessionRoute.self) { route in
                    SessionFeedScreen(model: model, session: route.session, macId: route.macId)
                }
```

Replace `otherMacSections` with:

```swift
    private var otherMacSections: some View {
        ForEach(othersWithSessions) { other in
            let sessions = waitingFirst(other.fleets.flatMap { $0.liveSessions?.sessions ?? [] })
            Section {
                ForEach(sessions, id: \.pid) { session in
                    NavigationLink(value: OtherSessionRoute(macId: other.id, session: session)) {
                        row(session, macId: other.id)
                    }
                }
            } header: {
                Text(other.pairing.name)
            }
        }
    }
```

Give `row`, `title` and `metadata` a `macId: String? = nil` parameter and read per Mac:

```swift
    private func row(_ session: SessionDetail, macId: String? = nil) -> some View {
```
- `model.awsLogin(for: session.pid)` → `model.awsLogin(macId: macId, pid: session.pid)`
- `title(session)` → `title(session, macId: macId)`; `metadata(session)` → `metadata(session, macId: macId)`
- `if let p = progress.byPid[session.pid], p.hasProgressSignal` → `if let p = model.progress(macId: macId, pid: session.pid), p.hasProgressSignal`

```swift
    private func title(_ session: SessionDetail, macId: String? = nil) -> String {
        let repo = repoName(session.cwd)
        let p = model.progress(macId: macId, pid: session.pid)
```

```swift
    private func metadata(_ session: SessionDetail, macId: String? = nil) -> String {
        let p = model.progress(macId: macId, pid: session.pid)
        var parts: [String] = []
        // Born from a profile / in a permission mode (#163/#165) leads.
        if let chip = model.birth(macId: macId, pid: session.pid)?.chip { parts.append(chip) }
```

Leave the primary call sites (`primarySections`, the context menu) as `row(session)` — they pass nil. If `row`'s context menu or any other line in it reads `progress.byPid[...]` or `model.snapshot?.births`, route those through the same two accessors with `macId`.

- [ ] **Step 4: build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/InfinitusMobile/SessionMirror.swift ios/InfinitusMobile/SessionDetailScreen.swift ios/InfinitusMobile/CheckpointsScreen.swift ios/InfinitusMobile/SessionFeedScreen.swift ios/InfinitusMobile/SessionsScreen.swift
git commit -m "phone: other Macs' sessions open — the Mac rides every pushed route, one environment mirror per screen (#144)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: Outbox per Mac

**Files:**
- Modify: `ios/InfinitusMobile/OutboxDelivery.swift` (whole file, ~70 lines)
- Modify: `ios/InfinitusMobile/MirrorModel.swift` (`init`, the line `reachableAgain = { Task { await OutboxDelivery.flush() } }` ~line 150)

**Interfaces:**
- Consumes: Task 1's `model.mirror(for:)`, `model.other(_:)`, `otherReachable`, `NetworkFleetMirror.parkedKey(token:)`; `Outbox.items(macKey:)`, `Outbox.flush(macKey:deliver:)`, `OutboxItem.macKey/pid/request/sessionName/id`.
- Produces: `OutboxDelivery.macKey(for macId: String?, model: MirrorModel) -> String` (`@MainActor`); `OutboxDelivery.flush(macId: String?) async`; `OutboxDelivery.deliver(_:through:)`. The old `static var macKey` and `flush()` stay as the primary shorthand (`macKey` = `parkedKey()`, `flush()` = `flush(macId: nil)`).

- [ ] **Step 1: rewrite `OutboxDelivery`**

```swift
import Foundation
import InfinitusCore
import UIKit
import UserNotifications

/// #168: the phone side of the outbox — where it lives on disk, how an
/// item is sent, and the notification when one lands while the app is
/// not on screen (the Mac pushes its own when the app is closed).
/// #144 phase 2: one queue per Mac, keyed by that Mac's token hash, each
/// flushed through its own mirror on its own reachable edge.
enum OutboxDelivery {
    static let outbox: Outbox = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Outbox(root: support.appendingPathComponent("outbox"))
    }()

    /// The primary Mac's key.
    static var macKey: String { NetworkFleetMirror.parkedKey() }

    /// The key a session's queue files under: the primary's, or the
    /// hash of its own Mac's token.
    @MainActor static func macKey(for macId: String?, model: MirrorModel) -> String {
        guard let macId, let pairing = model.other(macId)?.pairing else { return macKey }
        return NetworkFleetMirror.parkedKey(token: pairing.token)
    }

    /// `reachableAgain` and the first-successful-load trigger can fire
    /// within moments of each other — single-flight PER KEY so a second
    /// call doesn't re-send an item the first call already marked in
    /// flight, while two Macs' flushes may run side by side.
    @MainActor private static var flushing: Set<String> = []

    static func flush() async { await flush(macId: nil) }

    static func flush(macId: String?) async {
        let model = MirrorModel.shared
        let (key, mirror) = await MainActor.run { (macKey(for: macId, model: model), model.mirror(for: macId)) }
        let canRun = await MainActor.run { flushing.insert(key).inserted }
        guard canRun else { return }
        defer { Task { @MainActor in flushing.remove(key) } }

        // Names and text by id, captured before the flush — a delivered
        // item's file is gone by the time `results` comes back.
        let items = outbox.items(macKey: key)
        let names = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.sessionName) })
        let texts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.request.text) })
        let results = await outbox.flush(macKey: key) { item in await deliver(item, through: mirror) }
        let delivered = results.filter { $0.delivery == .delivered }
        guard !delivered.isEmpty else { return }
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        if !active {
            for result in delivered {
                let content = UNMutableNotificationContent()
                content.title = names[result.id].map { "Delivered to \($0)" } ?? "Delivered"
                content.body = texts[result.id].map { String($0.prefix(80)) } ?? "Your queued message reached the session."
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "outbox-\(result.id.uuidString)", content: content, trigger: nil))
            }
        }
    }

    static func deliver(_ item: OutboxItem, through mirror: NetworkFleetMirror) async -> Outbox.Delivery {
        do {
            let reply = try await mirror.sessionInput(pid: item.pid, request: item.request)
            switch reply.outcome {
            case "delivered", "running", "captured": return .delivered
            case "rejected" where reply.detail == "session ended": return .ended
            default: return .refused(reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome)
            }
        } catch MirrorTransportError.http(let code) {
            // The Mac answered — a rotated pairing token, most likely. Not
            // "gone", so the item must not retry forever as queued.
            return .refused("HTTP \(code)")
        } catch {
            return .transport
        }
    }
}
```

Nothing outside this file calls `deliver`; `Outbox.flush(macKey:now:deliver:)` takes `deliver: (OutboxItem) async -> Delivery` (InfinitusCore `Outbox.swift` line 145), so the trailing closure above is its exact type.

- [ ] **Step 2: wire the per-Mac edge in `MirrorModel.init`**

After `reachableAgain = { Task { await OutboxDelivery.flush() } }` add:

```swift
        otherReachable = { id in Task { await OutboxDelivery.flush(macId: id) } }
```

- [ ] **Step 3: build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/InfinitusMobile/OutboxDelivery.swift ios/InfinitusMobile/MirrorModel.swift
git commit -m "phone: one outbox queue per Mac, flushed through its own mirror on its own reachable edge (#144)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: `SessionFeedScreen` talks to the session's Mac

**Files:**
- Modify: `ios/InfinitusMobile/SessionFeedScreen.swift` (property block ~line 12–30; header inset ~line 218–232; `reloadQueued` ~line 389; `headerAccount` ~line 393; `headerData` ~line 403; `load` ~line 519–550; `takeStagedCapture` ~line 927; `continueSession` ~line 990; enqueue ~line 1074; checkpoints call ~line 1100; `dictationHints` ~line 1168; `send` ~line 1200; every `NetworkFleetMirror.shared`)
- Modify: `ios/InfinitusMobile/ChatHeader.swift` (`struct ChatHeaderData` line 9; the status/account `HStack` ~line 165 in `ChatHeaderView`)

**Interfaces:**
- Consumes: Task 1 accessors; Task 2's `macId`, `sessionMirror`, `SessionDetailRoute(session:macId:)`, `CheckpointsRoute(session:macId:)`; Task 3's `OutboxDelivery.macKey(for:model:)`.
- Produces: `ChatHeaderData.macName: String?` (default nil), rendered after the status word.

- [ ] **Step 1: the mirror**

In the property block add:

```swift
    /// The Mac this session lives on — the primary's mirror, or its own
    /// Mac's (#144 phase 2). Same-body children read it from the
    /// environment (`.environment(\.sessionMirror, mirror)` below).
    private var mirror: NetworkFleetMirror { model.mirror(for: macId) }
```

On the root of `body` (the `ScrollViewReader`), alongside the existing modifiers, add `.environment(\.sessionMirror, mirror)`.

Replace every `NetworkFleetMirror.shared.` in the file with `mirror.` — the seven sites: `sessionTail` ×2 and `parkedTail` in `load`, `sessionInput` in `continueSession`, `checkpoints` (~line 1100), `sessionInput` in `send`, plus any other. After the edit `grep -c "NetworkFleetMirror.shared" ios/InfinitusMobile/SessionFeedScreen.swift` prints 0.

- [ ] **Step 2: per-Mac model reads**

- `awsLoginBar` (~line 100): `model.awsLogin(for: session.pid)` → `model.awsLogin(macId: macId, pid: session.pid)`.
- `headerAccount`:

```swift
    private var headerAccount: (account: Account, fleet: MirrorFleetModel)? {
        guard let summary = model.accountSummary(macId: macId, pid: session.pid),
              let account = summary.account,
              let fleet = model.fleets(macId: macId).first(where: { $0.engineID == summary.engineID }) else { return nil }
        return (account, fleet)
    }
```

- `dictationHints`: both `model.sessionProgress.byPid[session.pid]?` → `model.progress(macId: macId, pid: session.pid)?`.
- `takeStagedCapture`: first line becomes

```swift
        // The share extension and the shake stage for the primary Mac
        // only; another Mac's feed sharing the pid must not swallow it.
        guard macId == nil, let staged = model.stagedCapture, staged.pid == session.pid else { return }
```

- The header's route: `route: SessionDetailRoute(session: session)` → `route: SessionDetailRoute(session: session, macId: macId)`. Every `CheckpointsRoute(session: session)` in the file → `CheckpointsRoute(session: session, macId: macId)`.
- Error copy in `load`: `"couldn't reach the Mac: …"` → `"couldn't reach \(model.macName(macId) ?? "the Mac"): …"`. Leave every other "the Mac" string alone.

- [ ] **Step 3: outbox key**

Add a computed property next to `mirror`:

```swift
    private var outboxKey: String { OutboxDelivery.macKey(for: macId, model: model) }
```

Replace both `OutboxDelivery.macKey` uses (`reloadQueued`, the `enqueue(macKey:` call) with `outboxKey`.

- [ ] **Step 4: the header caption**

`ChatHeaderData` gains `var macName: String? = nil` (after `plan`). In `ChatHeaderView`'s status line (the `HStack(spacing: 4)` holding `Text(statusWord)`), after the account block's closing brace add:

```swift
                            if let mac = data.macName {
                                Text("·").foregroundStyle(.tertiary)
                                Text(mac).lineLimit(1).foregroundStyle(.secondary)
                            }
```

If the file has more than one status `HStack` (the grep shows `data.accountName` at three places, ~lines 167, 238, 347 — three header styles), add the same three lines in each.

In `SessionFeedScreen.headerData`, after `var data = ChatHeaderData(...)`: `data.macName = model.macName(macId)`.

- [ ] **Step 5: build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`, and `grep -c "NetworkFleetMirror.shared" ios/InfinitusMobile/SessionFeedScreen.swift` prints 0.

- [ ] **Step 6: Commit**

```bash
git add ios/InfinitusMobile/SessionFeedScreen.swift ios/InfinitusMobile/ChatHeader.swift
git commit -m "phone: the chat talks to the session's own Mac — tail, replies, keys, checkpoints and the queue go where the session lives (#144)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: Detail, Checkpoints and thumbnails follow the Mac; release notes

**Files:**
- Modify: `ios/InfinitusMobile/SessionDetailScreen.swift` (`p`/`summary` ~line 94–95; Connection section ~line 156; `permissionsRow` ~line 180; mode send ~line 200–210)
- Modify: `ios/InfinitusMobile/CheckpointsScreen.swift` (`CheckpointsScreen` ~lines 14–115; `CheckpointDiffScreen` ~lines 135–265)
- Modify: `ios/InfinitusMobile/FeedThumbnail.swift` (`load` ~line 55–62)
- Modify: `CHANGELOG.md` (`### Phone` under `## 0.4.4 (unreleased)`, line ~15)
- Modify: `README.md` (after the `- **Parked** —` line, ~line 136)

**Interfaces:**
- Consumes: Task 1 accessors, Task 2's `macId` on the two screens and `sessionMirror`.

- [ ] **Step 1: SessionDetailScreen**

```swift
    private var p: SessionProgress? { model.progress(macId: macId, pid: session.pid) }
    private var summary: SessionAccountSummary? { model.accountSummary(macId: macId, pid: session.pid) }
    private var mirror: NetworkFleetMirror { model.mirror(for: macId) }
```

(`progress` stays a parameter so SessionsScreen's call keeps compiling; it is simply no longer read here.)

- Connection section: `model.transportStatus.isEmpty ? … : model.transportStatus` → `model.transportStatus(macId: macId).isEmpty ? model.rowTheme.loadingWord("searching") : model.transportStatus(macId: macId)`.
- `permissionsRow`: `let birth = model.snapshot?.births?[session.pid]` → `let birth = model.birth(macId: macId, pid: session.pid)`.
- Mode send: `NetworkFleetMirror.shared.sessionInput(` → `mirror.sessionInput(`; `await model.refresh()` → `await model.refresh(macId: macId)`; the catch copy `"couldn't reach the Mac"` → `"couldn't reach \(model.macName(macId) ?? "the Mac")"`.
- Add `.environment(\.sessionMirror, mirror)` on the root `List` (checkpoint links from here, if any, are pushed and carry `macId` in their route — grep `CheckpointsRoute(` in the file and add `macId: macId`).

- [ ] **Step 2: CheckpointsScreen and CheckpointDiffScreen**

`CheckpointsScreen` is pushed by a route, so it resolves the mirror itself (it has no `model` today):

```swift
    @ObservedObject private var model = MirrorModel.shared
    private var mirror: NetworkFleetMirror { model.mirror(for: macId) }
```

Replace its three `NetworkFleetMirror.shared.` with `mirror.`; set `.environment(\.sessionMirror, mirror)` on its root `List`. `CheckpointDiffScreen` is pushed with `NavigationLink { CheckpointDiffScreen(pid:checkpoint:) }` (line ~41), a destination closure built in this body, so it inherits the environment and reads:

```swift
    @Environment(\.sessionMirror) private var mirror
```

and its `NetworkFleetMirror.shared.sessionInput(` becomes `mirror.sessionInput(`, `.checkpointDiff(` likewise.

- [ ] **Step 3: FeedThumbnail**

```swift
    @Environment(\.sessionMirror) private var mirror
```

and in `load`: `try await mirror.sessionImage(pid: pid, id: id)`. Make the cache key per Mac so two Macs sharing a pid never swap pictures: `let key = "\(ObjectIdentifier(mirror).hashValue)/\(pid)/\(id)" as NSString`.

- [ ] **Step 4: sweep**

`grep -n "NetworkFleetMirror.shared" ios/InfinitusMobile/{SessionFeedScreen,SessionDetailScreen,CheckpointsScreen,FeedThumbnail}.swift` prints nothing.

- [ ] **Step 5: release notes**

CHANGELOG, directly under the "pairs with more than one Mac" line in `### Phone`:

```
- Other Macs' sessions open like the primary's: transcript, replies, approvals, checkpoints and queued messages go to the Mac the session lives on (#144).
```

README, after the `- **Parked** —` line:

```
- **Every Mac's chats** — a session under another paired Mac opens like any other; what you send goes to that Mac, and waits for it if it's away.
```

- [ ] **Step 6: build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add ios/InfinitusMobile/SessionDetailScreen.swift ios/InfinitusMobile/CheckpointsScreen.swift ios/InfinitusMobile/FeedThumbnail.swift CHANGELOG.md README.md
git commit -m "phone: detail, checkpoints and images follow the session's Mac; release notes (#144)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```
