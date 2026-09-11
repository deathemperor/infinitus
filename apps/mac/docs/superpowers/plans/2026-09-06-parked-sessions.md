# Parked Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the Mac is unreachable the phone keeps showing the last snapshot and transcript tails ("Parked"), queues one message per session, and delivers it exactly once when the Mac is back, with a notification.

**Architecture:** Pure, testable pieces live in InfinitusCore (`ParkedCache`, `Outbox`, `InputDedup`, three optional wire fields on `SessionInput.Request`); the phone wires them into `NetworkFleetMirror`, `MirrorModel` and `SessionFeedScreen`; the Mac's input handler dedups by `requestId`, resolves a stale pid by `sessionId`, and pushes an alert when a queued request lands.

**Tech Stack:** Swift 6.1 SwiftPM (InfinitusCore, `swift test`), SwiftUI iOS app (`ios/`, xcodegen + xcodebuild, no unit-test target), macOS app (`Sources/Infinitus`).

**Spec:** `docs/superpowers/specs/2026-09-06-parked-sessions-design.md`

## Global Constraints

- Every commit ends with `Co-Authored-By: Claude Code <noreply@anthropic.com>` (the repo hook adds it; write it anyway).
- Stage by explicit path; never `git add -A`; never amend, stash or rebase.
- Surgical changes; match the surrounding style; no speculative abstractions; comments explain why, in the repo's voice.
- No engine internals; no `~/.claude-swap-backup/*`.
- All disk writes atomic (`Data.write(to:options: .atomic)`); nothing silently dropped.
- `swift build` and `swift test` must pass after every InfinitusCore/Mac task; the phone tasks end with a green `xcodebuild` (command in Task 6).
- Sending is queued ONLY on a transport error; any `SessionInput.Reply` is the Mac's answer.
- Phase 1 is primary-Mac only.
- CHANGELOG: one feature, one line, under `## 0.4.4 (unreleased)`.

---

### Task 1: Wire fields on `SessionInput.Request`

**Files:**
- Modify: `Sources/InfinitusCore/SessionInput.swift` (struct `Request`, lines ~9-30)
- Test: `Tests/InfinitusCoreTests/SessionInputWireTests.swift` (create)

**Interfaces:**
- Produces: `SessionInput.Request.requestId: String?`, `.queuedAt: Date?`, `.sessionId: String?`; `init(kind:text:attachments:requestId:queuedAt:sessionId:)` with all three defaulting to `nil`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinitusCore

final class SessionInputWireTests: XCTestCase {
    func testOldJSONWithoutTheNewKeysDecodes() throws {
        let json = #"{"kind":"message","text":"hi"}"#.data(using: .utf8)!
        let request = try JSONDecoder().decode(SessionInput.Request.self, from: json)
        XCTAssertEqual(request.text, "hi")
        XCTAssertNil(request.requestId)
        XCTAssertNil(request.queuedAt)
        XCTAssertNil(request.sessionId)
    }

    func testNewFieldsRoundTrip() throws {
        let queued = Date(timeIntervalSince1970: 1_700_000_000)
        let request = SessionInput.Request(kind: .message, text: "later", requestId: "r-1",
                                           queuedAt: queued, sessionId: "s-1")
        let data = try JSONEncoder().encode(request)
        let back = try JSONDecoder().decode(SessionInput.Request.self, from: data)
        XCTAssertEqual(back, request)
        XCTAssertEqual(back.requestId, "r-1")
        XCTAssertEqual(back.queuedAt, queued)
        XCTAssertEqual(back.sessionId, "s-1")
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter SessionInputWireTests`
Expected: compile error — `extra arguments` / `no member requestId`.

- [ ] **Step 3: Add the fields**

In `SessionInput.Request`, after `attachments`:

```swift
        /// #168: a client-minted id so a retried delivery (the phone died
        /// mid-flush, the reply was lost) is answered once — the Mac keeps
        /// the last few per session. `queuedAt` marks a request that
        /// waited in the phone's outbox; the Mac pushes an alert when it
        /// lands. `sessionId` lets the Mac find the session again when
        /// its pid changed under a reboot. All optional: old JSON decodes.
        public let requestId: String?
        public let queuedAt: Date?
        public let sessionId: String?

        public init(kind: Kind, text: String, attachments: [Attachment]? = nil,
                    requestId: String? = nil, queuedAt: Date? = nil, sessionId: String? = nil) {
            self.kind = kind
            self.text = text
            self.attachments = attachments
            self.requestId = requestId
            self.queuedAt = queuedAt
            self.sessionId = sessionId
        }
```

(Replace the existing `init(kind:text:attachments:)`; every existing call site still compiles because the new parameters default to nil.)

- [ ] **Step 4: Run the tests**

Run: `swift test --filter SessionInputWireTests`
Expected: 2 tests pass. Then `swift build` (whole package) passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/SessionInput.swift Tests/InfinitusCoreTests/SessionInputWireTests.swift
git commit -m "core: SessionInput.Request carries requestId, queuedAt and sessionId (#168)"
```

---

### Task 2: `InputDedup`

**Files:**
- Create: `Sources/InfinitusCore/InputDedup.swift`
- Test: `Tests/InfinitusCoreTests/InputDedupTests.swift`

**Interfaces:**
- Produces: `public struct InputDedup: Sendable { public init(capacity: Int = 64); public mutating func firstSight(pid: Int32, requestId: String) -> Bool }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinitusCore

final class InputDedupTests: XCTestCase {
    func testSecondSightIsFalse() {
        var dedup = InputDedup()
        XCTAssertTrue(dedup.firstSight(pid: 7, requestId: "a"))
        XCTAssertFalse(dedup.firstSight(pid: 7, requestId: "a"))
    }

    func testPidsAreIsolated() {
        var dedup = InputDedup()
        XCTAssertTrue(dedup.firstSight(pid: 7, requestId: "a"))
        XCTAssertTrue(dedup.firstSight(pid: 8, requestId: "a"))
    }

    func testRingEvictsTheOldest() {
        var dedup = InputDedup(capacity: 3)
        for id in ["a", "b", "c"] { XCTAssertTrue(dedup.firstSight(pid: 1, requestId: id)) }
        XCTAssertTrue(dedup.firstSight(pid: 1, requestId: "d"))   // evicts "a"
        XCTAssertTrue(dedup.firstSight(pid: 1, requestId: "a"))   // forgotten
        XCTAssertFalse(dedup.firstSight(pid: 1, requestId: "d"))
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter InputDedupTests` — expected: `cannot find 'InputDedup'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// #168: the phone's outbox may deliver a request twice (it died between
/// the send and the reply, or the reply was lost); the Mac answers the
/// repeat without touching the session. A short ring per pid is enough —
/// a phone never has more than one queued request per session, and a
/// hand-retried send reuses its id for a few seconds, not days.
public struct InputDedup: Sendable {
    private let capacity: Int
    private var seen: [Int32: [String]] = [:]

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// True the first time `(pid, requestId)` is seen; false on a repeat.
    public mutating func firstSight(pid: Int32, requestId: String) -> Bool {
        var ring = seen[pid] ?? []
        if ring.contains(requestId) { return false }
        ring.append(requestId)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        seen[pid] = ring
        return true
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter InputDedupTests` — expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/InputDedup.swift Tests/InfinitusCoreTests/InputDedupTests.swift
git commit -m "core: InputDedup — a per-session ring of recent request ids (#168)"
```

---

### Task 3: `ParkedCache`

**Files:**
- Create: `Sources/InfinitusCore/ParkedCache.swift`
- Test: `Tests/InfinitusCoreTests/ParkedCacheTests.swift`

**Interfaces:**
- Consumes: `MirrorSnapshot` (Codable; construct in tests with `MirrorSnapshot(capturedAt:machineName:listJSON:sessions:)` — check `Sources/InfinitusCore/FleetMirror.swift:~70` for the exact init and pass empty/placeholder values for anything required), `SessionFeed` (Codable, `Sources/InfinitusCore/SessionFeed.swift:93`; `items: [SessionFeedItem]`, `stamp: String?`).
- Produces: `public final class ParkedCache: @unchecked Sendable` with `init(root: URL)`, `saveSnapshot(_:) throws`, `loadSnapshot() -> MirrorSnapshot?`, `saveTail(_:pid:) throws`, `loadTail(pid:) -> SessionFeed?`, `clear()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinitusCore

final class ParkedCacheTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parked-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func snapshot(at seconds: TimeInterval) -> MirrorSnapshot {
        // Use the smallest valid init FleetMirror.swift offers; adjust the
        // argument list to the real signature (see Interfaces).
        MirrorSnapshot(capturedAt: Date(timeIntervalSince1970: seconds), machineName: "mac",
                       listJSON: "{}", sessions: [])
    }

    private func feed(stamp: String) -> SessionFeed {
        SessionFeed(pid: 4, sessionId: "s", cwd: "/w", status: "idle", waiting: false,
                    items: [], name: "w", stamp: stamp)
    }

    func testSnapshotRoundTrip() throws {
        let cache = ParkedCache(root: root)
        XCTAssertNil(cache.loadSnapshot())
        try cache.saveSnapshot(snapshot(at: 10))
        XCTAssertEqual(cache.loadSnapshot()?.capturedAt, Date(timeIntervalSince1970: 10))
    }

    func testUnchangedCapturedAtDoesNotRewrite() throws {
        let cache = ParkedCache(root: root)
        try cache.saveSnapshot(snapshot(at: 10))
        let file = root.appendingPathComponent("snapshot.json")
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try cache.saveSnapshot(snapshot(at: 10))
        let second = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(first, second)
        try cache.saveSnapshot(snapshot(at: 11))
        XCTAssertEqual(cache.loadSnapshot()?.capturedAt, Date(timeIntervalSince1970: 11))
    }

    func testTailRoundTripAndClear() throws {
        let cache = ParkedCache(root: root)
        XCTAssertNil(cache.loadTail(pid: 4))
        try cache.saveTail(feed(stamp: "a"), pid: 4)
        XCTAssertEqual(cache.loadTail(pid: 4)?.stamp, "a")
        try cache.saveTail(feed(stamp: "b"), pid: 4)
        XCTAssertEqual(cache.loadTail(pid: 4)?.stamp, "b")
        cache.clear()
        XCTAssertNil(cache.loadTail(pid: 4))
        XCTAssertNil(cache.loadSnapshot())
    }

    func testCorruptFileIsSkipped() throws {
        let cache = ParkedCache(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: root.appendingPathComponent("snapshot.json"))
        XCTAssertNil(cache.loadSnapshot())
    }
}
```

If `SessionFeed` has no public memberwise init, decode one from JSON in the test helper instead (`{"pid":4,"sessionId":"s","cwd":"/w","waiting":false,"items":[],"stamp":"a"}`) — do not add an init to production code for the test.

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter ParkedCacheTests` — expected: `cannot find 'ParkedCache'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// #168: what the phone keeps on disk so a Mac that is asleep, off Wi-Fi
/// or rebooting still leaves the fleet and the transcripts readable —
/// the last snapshot that answered and the last tail fetched per
/// session. Writes are atomic and skipped when nothing changed, so a
/// 10-second poll that returns the same snapshot never touches disk.
public final class ParkedCache: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var lastSavedCapturedAt: Date?
    private var lastSavedStamp: [Int32: String?] = [:]

    public init(root: URL) {
        self.root = root
    }

    private var snapshotURL: URL { root.appendingPathComponent("snapshot.json") }
    private func tailURL(_ pid: Int32) -> URL {
        root.appendingPathComponent("tails").appendingPathComponent("\(pid).json")
    }

    public func saveSnapshot(_ snapshot: MirrorSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if lastSavedCapturedAt == snapshot.capturedAt { return }
        try write(JSONEncoder().encode(snapshot), to: snapshotURL)
        lastSavedCapturedAt = snapshot.capturedAt
    }

    public func loadSnapshot() -> MirrorSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(MirrorSnapshot.self, from: data) else { return nil }
        lock.lock(); lastSavedCapturedAt = snapshot.capturedAt; lock.unlock()
        return snapshot
    }

    public func saveTail(_ feed: SessionFeed, pid: Int32) throws {
        lock.lock(); defer { lock.unlock() }
        if let known = lastSavedStamp[pid], known == feed.stamp, feed.stamp != nil { return }
        try write(JSONEncoder().encode(feed), to: tailURL(pid))
        lastSavedStamp[pid] = feed.stamp
    }

    public func loadTail(pid: Int32) -> SessionFeed? {
        guard let data = try? Data(contentsOf: tailURL(pid)) else { return nil }
        return try? JSONDecoder().decode(SessionFeed.self, from: data)
    }

    /// The primary Mac changed: nothing here belongs to the new one.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root)
        lastSavedCapturedAt = nil
        lastSavedStamp = [:]
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
```

Check whether `MirrorSnapshot`/`SessionFeed` encode dates with a custom strategy elsewhere (grep `dateEncodingStrategy` in `Sources/InfinitusCore/FleetMirror.swift` and `MirrorClient.swift`); if the wire uses one, use the same encoder/decoder here so `capturedAt` round-trips exactly.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ParkedCacheTests` — expected: 4 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/ParkedCache.swift Tests/InfinitusCoreTests/ParkedCacheTests.swift
git commit -m "core: ParkedCache — last snapshot and per-session tails on disk (#168)"
```

---

### Task 4: `Outbox`

**Files:**
- Create: `Sources/InfinitusCore/Outbox.swift`
- Test: `Tests/InfinitusCoreTests/OutboxTests.swift`

**Interfaces:**
- Consumes: `SessionInput.Request` with `requestId`/`queuedAt`/`sessionId` (Task 1).
- Produces: `public struct OutboxItem` and `public final class Outbox: @unchecked Sendable` with `init(root: URL)`, `items(macKey:) -> [OutboxItem]`, `enqueue(macKey:pid:sessionId:sessionName:request:now:) throws -> OutboxItem`, `replace(id:request:now:) throws`, `remove(id:)`, `flush(macKey:now:deliver:) async -> [FlushResult]`, `enum Delivery { delivered, transport, refused(String), ended }`, `struct FlushResult { id, delivery }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinitusCore

final class OutboxTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func request(_ text: String) -> SessionInput.Request {
        SessionInput.Request(kind: .message, text: text)
    }

    func testEnqueueMergesIntoOneItemPerSession() throws {
        let box = Outbox(root: root)
        let first = try box.enqueue(macKey: "m", pid: 4, sessionId: "s", sessionName: "repo",
                                    request: request("one"), now: t0)
        let second = try box.enqueue(macKey: "m", pid: 4, sessionId: "s", sessionName: "repo",
                                     request: request("two"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.request.text, "one\n\ntwo")
        XCTAssertNotEqual(first.request.requestId, second.request.requestId)
        XCTAssertEqual(second.request.sessionId, "s")
        XCTAssertEqual(second.updatedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(box.items(macKey: "m").count, 1)
        _ = try box.enqueue(macKey: "m", pid: 5, sessionId: nil, sessionName: "other",
                            request: request("x"), now: t0)
        XCTAssertEqual(box.items(macKey: "m").map(\.pid), [4, 5])
        XCTAssertEqual(box.items(macKey: "other-mac").count, 0)
    }

    func testReplaceAndRemove() throws {
        let box = Outbox(root: root)
        let item = try box.enqueue(macKey: "m", pid: 4, sessionId: "s", sessionName: "repo",
                                   request: request("one"), now: t0)
        try box.replace(id: item.id, request: request("edited"), now: t0.addingTimeInterval(1))
        XCTAssertEqual(box.items(macKey: "m").first?.request.text, "edited")
        XCTAssertNotNil(box.items(macKey: "m").first?.request.requestId)
        box.remove(id: item.id)
        XCTAssertEqual(box.items(macKey: "m").count, 0)
    }

    func testFlushStateMachine() async throws {
        let box = Outbox(root: root)
        let a = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("a"), now: t0)
        let b = try box.enqueue(macKey: "m", pid: 2, sessionId: nil, sessionName: "b", request: request("b"), now: t0.addingTimeInterval(1))
        let c = try box.enqueue(macKey: "m", pid: 3, sessionId: nil, sessionName: "c", request: request("c"), now: t0.addingTimeInterval(2))
        let d = try box.enqueue(macKey: "m", pid: 4, sessionId: nil, sessionName: "d", request: request("d"), now: t0.addingTimeInterval(3))
        var seenInFlight: [UUID] = []
        let results = await box.flush(macKey: "m", now: t0.addingTimeInterval(10)) { item in
            // inFlight must already be on disk when deliver runs
            if box.items(macKey: "m").first(where: { $0.id == item.id })?.state == .inFlight {
                seenInFlight.append(item.id)
            }
            switch item.pid {
            case 1: return .delivered
            case 2: return .refused("noSurface — no terminal")
            case 3: return .ended
            default: return .transport
            }
        }
        XCTAssertEqual(seenInFlight, [a.id, b.id, c.id, d.id])
        XCTAssertEqual(results.map(\.id), [a.id, b.id, c.id, d.id])
        let left = box.items(macKey: "m")
        XCTAssertEqual(left.map(\.pid), [2, 3, 4])                 // a removed
        XCTAssertEqual(left[0].state, .refused("noSurface — no terminal"))
        XCTAssertEqual(left[1].state, .ended)
        XCTAssertEqual(left[2].state, .queued)
        XCTAssertEqual(left[2].attempts, 1)
        XCTAssertEqual(left[2].request.queuedAt, t0.addingTimeInterval(3))   // updatedAt of d
    }

    func testTransportStopsThePass() async throws {
        let box = Outbox(root: root)
        _ = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("a"), now: t0)
        _ = try box.enqueue(macKey: "m", pid: 2, sessionId: nil, sessionName: "b", request: request("b"), now: t0.addingTimeInterval(1))
        var delivered: [Int32] = []
        _ = await box.flush(macKey: "m", now: t0) { item in delivered.append(item.pid); return .transport }
        XCTAssertEqual(delivered, [1])
        XCTAssertEqual(box.items(macKey: "m").map(\.state), [.queued, .queued])
    }

    func testRefusedAndEndedItemsAreSkippedAndInFlightRetriesSameId() async throws {
        let box = Outbox(root: root)
        let a = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("a"), now: t0)
        _ = await box.flush(macKey: "m", now: t0) { _ in .refused("no") }
        var calls = 0
        _ = await box.flush(macKey: "m", now: t0) { _ in calls += 1; return .delivered }
        XCTAssertEqual(calls, 0)
        // simulate a crash mid-send: an inFlight item on disk
        var stuck = box.items(macKey: "m")[0]
        stuck.state = .inFlight
        try box.save(stuck)
        let id = stuck.request.requestId
        var seen: String?
        _ = await box.flush(macKey: "m", now: t0) { item in seen = item.request.requestId; return .delivered }
        XCTAssertEqual(seen, id)
        XCTAssertEqual(box.items(macKey: "m").count, 0)
        _ = a
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter OutboxTests` — expected: `cannot find 'Outbox'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// #168: one queued request per session, kept on disk until the Mac takes
/// it. The phone delivers; the Mac dedups (`InputDedup`) — so an item is
/// marked in flight BEFORE the send, and a leftover in-flight item after
/// a crash is simply sent again with the same `requestId`.
public struct OutboxItem: Codable, Sendable, Equatable, Identifiable {
    public enum State: Codable, Sendable, Equatable {
        case queued
        case inFlight
        case refused(String)
        case ended
    }

    public let id: UUID
    public let macKey: String
    public var pid: Int32
    public let sessionId: String?
    public let sessionName: String
    public var request: SessionInput.Request
    public let createdAt: Date
    public var updatedAt: Date
    public var attempts: Int
    public var state: State
}

public final class Outbox: @unchecked Sendable {
    public enum Delivery: Sendable, Equatable {
        case delivered
        case transport
        case refused(String)
        case ended
    }

    public struct FlushResult: Sendable, Equatable {
        public let id: UUID
        public let delivery: Delivery
    }

    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    private func url(macKey: String, pid: Int32) -> URL {
        root.appendingPathComponent("\(macKey)-\(pid).json")
    }

    /// Every item for one Mac, oldest first.
    public func items(macKey: String) -> [OutboxItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { $0.hasPrefix("\(macKey)-") && $0.hasSuffix(".json") }
            .compactMap { name -> OutboxItem? in
                guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
                return try? JSONDecoder().decode(OutboxItem.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// One per session: a second message for the same session joins the
    /// first as a new paragraph and gets a fresh `requestId` — the old one
    /// was never sent, or was sent and refused.
    @discardableResult
    public func enqueue(macKey: String, pid: Int32, sessionId: String?, sessionName: String,
                        request: SessionInput.Request, now: Date = Date()) throws -> OutboxItem {
        lock.lock(); defer { lock.unlock() }
        var item: OutboxItem
        if let existing = load(macKey: macKey, pid: pid) {
            item = existing
            let text = existing.request.text.isEmpty ? request.text
                : (request.text.isEmpty ? existing.request.text : existing.request.text + "\n\n" + request.text)
            let attachments = (existing.request.attachments ?? []) + (request.attachments ?? [])
            item.request = SessionInput.Request(kind: request.kind, text: text,
                                                attachments: attachments.isEmpty ? nil : attachments,
                                                requestId: UUID().uuidString, sessionId: sessionId ?? existing.sessionId)
            item.updatedAt = now
            item.state = .queued
        } else {
            item = OutboxItem(id: UUID(), macKey: macKey, pid: pid, sessionId: sessionId,
                              sessionName: sessionName,
                              request: SessionInput.Request(kind: request.kind, text: request.text,
                                                            attachments: request.attachments,
                                                            requestId: UUID().uuidString, sessionId: sessionId),
                              createdAt: now, updatedAt: now, attempts: 0, state: .queued)
        }
        try save(item)
        return item
    }

    /// The Edit path: the whole request is replaced, id regenerated.
    public func replace(id: UUID, request: SessionInput.Request, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard var item = all().first(where: { $0.id == id }) else { return }
        item.request = SessionInput.Request(kind: request.kind, text: request.text, attachments: request.attachments,
                                            requestId: UUID().uuidString, sessionId: item.sessionId)
        item.updatedAt = now
        item.state = .queued
        try save(item)
    }

    public func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let item = all().first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(macKey: item.macKey, pid: item.pid))
    }

    /// Persists an item as-is (tests use it to plant an in-flight item).
    public func save(_ item: OutboxItem) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(item).write(to: url(macKey: item.macKey, pid: item.pid), options: .atomic)
    }

    /// Sends every queued (or stuck in-flight) item in order. A transport
    /// failure ends the pass — the Mac is gone again; a refusal or an
    /// ended session parks the item for the user and moves on.
    public func flush(macKey: String, now: Date = Date(),
                      deliver: (OutboxItem) async -> Delivery) async -> [FlushResult] {
        var results: [FlushResult] = []
        for var item in items(macKey: macKey) {
            switch item.state {
            case .refused, .ended: continue
            case .queued, .inFlight: break
            }
            item.state = .inFlight
            item.request = SessionInput.Request(kind: item.request.kind, text: item.request.text,
                                                attachments: item.request.attachments,
                                                requestId: item.request.requestId ?? UUID().uuidString,
                                                queuedAt: item.updatedAt, sessionId: item.sessionId)
            do { try save(item) } catch { continue }
            let delivery = await deliver(item)
            results.append(FlushResult(id: item.id, delivery: delivery))
            switch delivery {
            case .delivered:
                try? FileManager.default.removeItem(at: url(macKey: item.macKey, pid: item.pid))
            case .transport:
                item.state = .queued
                item.attempts += 1
                try? save(item)
                return results
            case .refused(let why):
                item.state = .refused(why)
                try? save(item)
            case .ended:
                item.state = .ended
                try? save(item)
            }
        }
        return results
    }

    private func all() -> [OutboxItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            (try? Data(contentsOf: root.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(OutboxItem.self, from: $0) }
        }
    }

    private func load(macKey: String, pid: Int32) -> OutboxItem? {
        guard let data = try? Data(contentsOf: url(macKey: macKey, pid: pid)) else { return nil }
        return try? JSONDecoder().decode(OutboxItem.self, from: data)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter OutboxTests` — expected: 5 pass. If `OutboxItem.State` with an associated value fails to synthesize `Codable`, it does on Swift 5.5+; keep it.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/Outbox.swift Tests/InfinitusCoreTests/OutboxTests.swift
git commit -m "core: Outbox — one queued request per session, in-flight before send (#168)"
```

---

### Task 5: Mac — dedup, sessionId fallback, push on a queued delivery

**Files:**
- Modify: `Sources/Infinitus/MirrorServer.swift` (`MirrorSessionInputBox`, ~line 203)
- Modify: `Sources/Infinitus/AppModel.swift` (the `mirrorServer.sessionInput.set` closure, ~line 1194-1224)

**Interfaces:**
- Consumes: `InputDedup` (Task 2), the new `Request` fields (Task 1), `liveActivityPusher.pushAlert(title:body:)` (`Sources/Infinitus/LiveActivityPusher.swift:~198`).

- [ ] **Step 1: Dedup inside the box**

`MirrorSessionInputBox` runs its provider on the serial `mirrorInputQueue`; keep the ring under the same lock:

```swift
final class MirrorSessionInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?)?
    /// #168: a request the phone's outbox sends twice (it died between
    /// send and reply) is answered once; the repeat is "delivered" again
    /// without touching the session.
    private var dedup = InputDedup()

    func set(_ new: @escaping @Sendable (Int32, SessionInput.Request) -> SessionInput.Reply?) {
        lock.lock(); provider = new; lock.unlock()
    }

    func call(_ pid: Int32, _ request: SessionInput.Request) -> SessionInput.Reply? {
        lock.lock()
        let current = provider
        let fresh = request.requestId.map { dedup.firstSight(pid: pid, requestId: $0) } ?? true
        lock.unlock()
        guard fresh else { return SessionInput.Reply(outcome: "delivered", detail: "duplicate") }
        return current?(pid, request)
    }
}
```

- [ ] **Step 2: sessionId fallback and the push in AppModel's closure**

Replace the record lookup at the top of the closure:

```swift
            let records = ClaudeSessions.list(claudeDir: claudeDir)
            // #168: a queued request may name a pid from before a reboot —
            // the session lives on under a new one; its id does not change.
            guard let record = records.first(where: { $0.pid == pid })
                    ?? request.sessionId.flatMap({ id in records.first { $0.sessionId == id } })
            else {
                Task { @MainActor in self?.logMirrorInput("⚠️", "phone input not delivered: unknown session") }
                return SessionInput.Reply(outcome: "rejected", detail: "session ended")
            }
```

(`return nil` used to become a 404; the phone now needs a reply it can classify.)

After the existing `if reply.outcome == "delivered" { … }` log branch, inside the same `Task { @MainActor in … }`, add:

```swift
                if request.queuedAt != nil, ["delivered", "running", "captured"].contains(reply.outcome) {
                    // The phone queued this while the Mac was away; the
                    // push reaches it even when the app is closed.
                    self?.liveActivityPusher.pushAlert(title: "Delivered to \(label)",
                                                       body: String(request.text.prefix(80)))
                }
```

Check `pushAlert`'s exact signature in `LiveActivityPusher.swift` and whether `label` is in scope there (it is computed before the `Task`); `request` is the `var request` (the approve rewrite keeps `queuedAt` nil, which is right).

- [ ] **Step 3: Build and test**

Run: `swift build --product Infinitus 2>&1 | tail -3` and `swift test 2>&1 | tail -3` — both green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Infinitus/MirrorServer.swift Sources/Infinitus/AppModel.swift
git commit -m "mac: phone input dedups by requestId, finds a rebooted session by sessionId, pushes when a queued message lands (#168)"
```

---

### Task 6: Phone — parked cache and the Parked banner

**Files:**
- Modify: `ios/InfinitusMobile/NetworkFleetMirror.swift` (init ~76-92, `latest()` ~164-266, `sessionTail` ~300-329, `forgetCached` ~97)
- Modify: `ios/InfinitusMobile/MirrorModel.swift` (`refresh()` ~246-292, `makePrimary` ~181, published vars ~37-50)
- Modify: `ios/InfinitusMobile/FleetScreen.swift` (`mirrorState` ~86-100)
- Modify: `ios/InfinitusMobile/NativeFleetScreen.swift` (the machine caption block ~180-194)

**Interfaces:**
- Consumes: `ParkedCache` (Task 3).
- Produces: `NetworkFleetMirror.parkedKey() -> String` (nonisolated static, from `UserDefaults.standard.string(forKey: tokenKey)`), `NetworkFleetMirror.parkedCache` (static, `ParkedCache` for the primary key), actor var `lastServedFromCache: Bool`; `MirrorModel.parked: Bool`, `MirrorModel.parkedSince: Date?`, `MirrorModel.reachableAgain: (() -> Void)?` hook Task 7 fills.

- [ ] **Step 1: Cache key and instance on NetworkFleetMirror**

At the top of `NetworkFleetMirror` (after `static let tokenKey`), add:

```swift
    /// #168: the primary Mac's identity for what the phone keeps on disk —
    /// twelve hex of the pairing token's hash, so a token never lands in a
    /// file name; "local" before the first pairing.
    nonisolated static func parkedKey(defaults: UserDefaults = .standard) -> String {
        let token = MirrorPairing.normalize(defaults.string(forKey: tokenKey) ?? "")
        guard !token.isEmpty else { return "local" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static var parkedCache: ParkedCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ParkedCache(root: support.appendingPathComponent("parked").appendingPathComponent(parkedKey()))
    }

    /// True when the last `latest()` answered from the cache because no
    /// route reached the Mac — the phone is "parked".
    private(set) var lastServedFromCache = false
```

Add `import CryptoKit` to the file. Note `ParkedCache` keeps an in-memory "last saved" marker, so the `.shared` actor must hold ONE instance: add `private let parked: ParkedCache? ` set in `init()` (the `.defaults` one) to `Self.parkedCache`, and `nil` in `init(pairing:)` (other Macs are read-only in phase 1). Seed the cache in `init()`: `cached = parked?.loadSnapshot()`.

- [ ] **Step 2: Save on success, flag on fallback**

In `latest()`: at each `cached = snapshot` success site (lines ~183, 218, 250) add `try? parked?.saveSnapshot(snapshot)` and `lastServedFromCache = false`. At each `return cached` fallback site (lines ~193, 234, 242, 256, 264) set `lastServedFromCache = cached != nil` before returning — EXCEPT the 401 branch (~193): the Mac answered, keep `lastServedFromCache = false` there. In `forgetCached()` also `parked?.clear()` and `lastServedFromCache = false`.

In `sessionTail(pid:limit:since:wait:)`: after a successful decode, `try? parked?.saveTail(feed, pid: pid)` (only when `since == nil` — the long-poll returns deltas). Add `func parkedTail(pid: Int32) -> SessionFeed? { parked?.loadTail(pid: pid) }`.

- [ ] **Step 3: MirrorModel flags**

Add next to `@Published var error`:

```swift
    /// #168: the snapshot on screen came from the phone's disk cache
    /// because no route reached the Mac. Connectivity, not age — the
    /// 180 s staleness banner stays for "reachable but old".
    @Published var parked = false
    @Published var parkedSince: Date?
    /// Runs on the parked → reachable edge (Task 7's outbox flush).
    var reachableAgain: (() -> Void)?
```

In `refresh()`, right after `self.snapshot = snapshot` in the success path:

```swift
            let fromCache = usesLAN ? await NetworkFleetMirror.shared.lastServedFromCache : false
            let wasParked = parked
            parked = fromCache
            parkedSince = fromCache ? snapshot.capturedAt : nil
            if wasParked, !fromCache { reachableAgain?() }
```

In the `guard let snapshot … else { … }` nil branch set `parked = false; parkedSince = nil`. In `makePrimary(id:)` the existing `forgetCached()` call now clears the cache too (Step 2) — verify it is awaited there.

- [ ] **Step 4: Banners**

`FleetScreen.mirrorState`: before the `StalenessBanner` block:

```swift
        if model.parked, let since = model.parkedSince {
            ParkedBanner(since: since)
        }
        if let snapshot = model.snapshot, !model.parked, isStale(snapshot.capturedAt) {
            StalenessBanner(capturedAt: snapshot.capturedAt)
        }
```

and next to `StalenessBanner`:

```swift
private struct ParkedBanner: View {
    let since: Date

    var body: some View {
        Label("parked — last seen \(since.formatted(.relative(presentation: .named))); messages you send wait for the Mac",
              systemImage: "moon.zzz")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
```

`NativeFleetScreen`: in the caption block, when `model.parked` show the same `Label` text (caption font, secondary) in place of the orange "is the Mac awake?" capsule, and gate that capsule with `!model.parked`.

- [ ] **Step 5: Build the phone**

```bash
cd ios && xcodegen generate > /dev/null && xcodebuild -project InfinitusMobile.xcodeproj -scheme InfinitusMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/infinitus-parked-dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | head
```

Expected: `** BUILD SUCCEEDED **`, no `error:` lines. Also `swift build` still green (no InfinitusCore change here, but check).

- [ ] **Step 6: Commit**

```bash
git add ios/InfinitusMobile/NetworkFleetMirror.swift ios/InfinitusMobile/MirrorModel.swift ios/InfinitusMobile/FleetScreen.swift ios/InfinitusMobile/NativeFleetScreen.swift
git commit -m "phone: parked — the last snapshot and tails come back from disk when no route reaches the Mac (#168)"
```

---

### Task 7: Phone — queue on transport failure, queued card, flush

**Files:**
- Create: `ios/InfinitusMobile/OutboxDelivery.swift`
- Modify: `ios/InfinitusMobile/SessionFeedScreen.swift` (`load` ~478-509, `sendMessage` ~959-1008, `send` ~1095-1106, the composer area in `body`, `PendingSent` ~83-89)
- Modify: `ios/InfinitusMobile/MirrorModel.swift` (`init` — set `reachableAgain`)
- Modify: `ios/InfinitusMobile/NetworkFleetMirror.swift` (`sessionInput` — `requestId` default)
- Modify: `ios/project.yml` only if a new file needs listing (xcodegen globs the folder; it should not).

**Interfaces:**
- Consumes: `Outbox`, `OutboxItem` (Task 4), `NetworkFleetMirror.parkedKey()`, `.parkedTail(pid:)`, `MirrorModel.reachableAgain` (Task 6).
- Produces: `enum OutboxDelivery { static let outbox: Outbox; static func flush() async; static func deliver(_ item: OutboxItem) async -> Outbox.Delivery }`.

- [ ] **Step 1: OutboxDelivery**

```swift
import Foundation
import InfinitusCore
import UIKit
import UserNotifications

/// #168: the phone side of the outbox — where it lives on disk, how an
/// item is sent, and the notification when one lands while the app is
/// not on screen (the Mac pushes its own when the app is closed).
enum OutboxDelivery {
    static let outbox: Outbox = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Outbox(root: support.appendingPathComponent("outbox"))
    }()

    static var macKey: String { NetworkFleetMirror.parkedKey() }

    static func flush() async {
        let results = await outbox.flush(macKey: macKey, deliver: deliver)
        let delivered = results.filter { $0.delivery == .delivered }
        guard !delivered.isEmpty else { return }
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        if !active {
            for result in delivered {
                let content = UNMutableNotificationContent()
                content.title = "Delivered"
                content.body = "Your queued message reached the session."
                _ = result
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "outbox-\(result.id.uuidString)", content: content, trigger: nil))
            }
        }
    }

    static func deliver(_ item: OutboxItem) async -> Outbox.Delivery {
        do {
            let reply = try await NetworkFleetMirror.shared.sessionInput(pid: item.pid, request: item.request)
            switch reply.outcome {
            case "delivered", "running", "captured": return .delivered
            case "rejected" where reply.detail == "session ended": return .ended
            default: return .refused(reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome)
            }
        } catch {
            return .transport
        }
    }
}
```

Use the item's `sessionName` in the notification body ("Delivered to \(name)") — `results` carry only ids, so look the name up from `outbox.items(macKey:)` BEFORE flushing (capture `let names = Dictionary(uniqueKeysWithValues: outbox.items(macKey: macKey).map { ($0.id, $0.sessionName) })`).

- [ ] **Step 2: Flush triggers**

In `MirrorModel.init` (after the existing setup) set `reachableAgain = { Task { await OutboxDelivery.flush() } }`. Also flush once on the first successful load: in `refresh()`, where `firstLoad` is computed, add `if firstLoad, !fromCache { reachableAgain?() }` (the app launched with the Mac reachable and may hold items from yesterday).

- [ ] **Step 3: `requestId` on every send**

In `NetworkFleetMirror.sessionInput(pid:request:)`, before encoding: if `request.requestId == nil`, encode a copy with `requestId: UUID().uuidString` (build via the full `SessionInput.Request(kind:text:attachments:requestId:queuedAt:sessionId:)` init). A hand-retried send after a timeout then reuses nothing — that is fine; the outbox path always carries its own id.

- [ ] **Step 4: SessionFeedScreen — parked tail**

In `load(longPoll:)`'s outer `catch`, before setting `errorText`:

```swift
            if feed == nil, let parked = await NetworkFleetMirror.shared.parkedTail(pid: Int32(session.pid)) {
                feed = parked
                errorText = "parked — showing the last transcript"
                return false
            }
```

- [ ] **Step 5: SessionFeedScreen — queue on transport failure**

Add state: `@State private var queued: OutboxItem?` and a loader `private func reloadQueued() { queued = OutboxDelivery.outbox.items(macKey: OutboxDelivery.macKey).first { $0.pid == Int32(session.pid) } }` called from the view's `.task`/`onAppear` (next to where `load()` is first called) and after every send.

Extend `PendingSent` with `var queued = false`. In `sendMessage()`'s `onFailure:` closure replace `messageResult = "couldn't reach the Mac"` with:

```swift
                let request = SessionInput.Request(kind: .message, text: text,
                                                   attachments: picked.isEmpty ? nil : picked,
                                                   sessionId: feed?.sessionId)
                if (try? OutboxDelivery.outbox.enqueue(
                        macKey: OutboxDelivery.macKey, pid: Int32(session.pid), sessionId: feed?.sessionId,
                        sessionName: feed?.name ?? repoName(session.cwd), request: request)) != nil {
                    pendingSent.append(PendingSent(text: text, images: attachments.compactMap(\.thumbnail),
                                                   files: attachments.filter { $0.thumbnail == nil }.map(\.name),
                                                   queued: true))
                    draft = ""; attachments = []; messageResult = nil
                    reloadQueued()
                } else {
                    messageResult = "couldn't reach the Mac"
                }
```

`sendKey`/`sendInput`/`continueSession` keep their current failure text — keys and resumes are not queued (a key pressed an hour later means nothing).

- [ ] **Step 6: SessionFeedScreen — the queued card**

Above the composer (find where the composer `HStack`/`TextField` is placed in `body` and insert directly before it):

```swift
                if let item = queued {
                    QueuedCard(item: item, onEdit: {
                        draft = item.request.text
                        OutboxDelivery.outbox.remove(id: item.id)
                        reloadQueued()
                    }, onDiscard: {
                        OutboxDelivery.outbox.remove(id: item.id)
                        reloadQueued()
                    })
                }
```

and a private view:

```swift
private struct QueuedCard: View {
    let item: OutboxItem
    let onEdit: () -> Void
    let onDiscard: () -> Void

    private var status: String {
        switch item.state {
        case .queued, .inFlight:
            let tries = item.attempts >= 3 ? " · \(item.attempts) tries" : ""
            return "queued for when the Mac is back · \(item.updatedAt.formatted(.relative(presentation: .named)))\(tries)"
        case .refused(let why): return "the Mac refused it — \(why)"
        case .ended: return "that session has ended"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(status, systemImage: "tray.and.arrow.up").font(.caption).foregroundStyle(.secondary)
            Text(item.request.text).font(.subheadline).lineLimit(3)
            HStack {
                if case .ended = item.state {} else { Button("Edit", action: onEdit) }
                Button("Discard", role: .destructive, action: onDiscard)
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}
```

Attachments on Edit: the composer's attachment model is view-local (`attachments` of a picker type with `thumbnail`); rebuilding it from `SessionInput.Attachment` data may need the picker item's init — if there is no cheap way, Edit moves the TEXT and the card notes "(attachments stay queued until sent)". Say which in the report.

Render a queued `PendingSent` echo with a small "queued" caption (find where `pendingSent` rows draw the text and add `if pending.queued { Text("queued").font(.caption2).foregroundStyle(.secondary) }`). When a queued item is delivered and the feed reloads, the Mac's own transcript shows the message; drop echoes older than the feed's newest item as the screen already does for delivered ones.

- [ ] **Step 7: Build the phone**

Same command as Task 6 Step 5 — `** BUILD SUCCEEDED **`, no `error:`.

- [ ] **Step 8: Commit**

```bash
git add ios/InfinitusMobile/OutboxDelivery.swift ios/InfinitusMobile/SessionFeedScreen.swift ios/InfinitusMobile/MirrorModel.swift ios/InfinitusMobile/NetworkFleetMirror.swift
git commit -m "phone: a message that can't reach the Mac waits in an outbox and goes out when it's back (#168)"
```

---

### Task 8: Notes

**Files:**
- Modify: `CHANGELOG.md` (under `## 0.4.4 (unreleased)`)
- Modify: `README.md` (the features list, one line, matching its neighbours' voice)

- [ ] **Step 1: CHANGELOG**

Add one bullet: `- Parked sessions: with the Mac unreachable the phone keeps the last fleet and transcripts, queues one message per session and delivers it once the Mac is back (#168).`

- [ ] **Step 2: README**

One feature line in the phone section, e.g. `- **Parked** — the Mac asleep or away, the phone still shows the fleet and every transcript, and a message you send waits and goes out when it's back.`

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "notes: parked sessions (#168)"
```
