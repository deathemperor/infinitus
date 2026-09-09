import XCTest
@testable import InfinitusCore

final class TimelineCacheTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tlcache-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ lines: [String], sessionId: String, cwd: String = "/Users/me/repo") throws -> URL {
        let url = Transcript.path(cwd: cwd, sessionId: sessionId, claudeDir: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private let prompt = #"{"type":"user","uuid":"u1","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":"hello"}}"#
    private let reply = #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-01T10:00:02.000Z","message":{"content":[{"type":"text","text":"hi"}]}}"#

    func testUnchangedTranscriptIsParsedOnce() throws {
        _ = try write([prompt, reply], sessionId: "s1")
        let record = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "idle")
        let cache = TimelineCache()
        let first = cache.timeline(record: record, claudeDir: root)
        let second = cache.timeline(record: record, claudeDir: root)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.turns.map(\.id), ["u1"])
        XCTAssertEqual(cache.parses, 1)
    }

    func testNarrowWindowSlotWidensOnceForAWatchedAsk() throws {
        _ = try write([prompt, reply], sessionId: "s1")
        let record = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "idle")
        let cache = TimelineCache()
        let narrow = SessionFeedReader.tailBytes, wide = SessionFeedReader.tailBytesMax
        XCTAssertNotNil(cache.timeline(record: record, claudeDir: root, maxBytes: narrow))
        XCTAssertNotNil(cache.timeline(record: record, claudeDir: root, maxBytes: narrow))
        XCTAssertEqual(cache.parses, 1, "a narrow ask reuses the narrow slot")
        XCTAssertNotNil(cache.timeline(record: record, claudeDir: root, maxBytes: wide))
        XCTAssertEqual(cache.parses, 2, "a wider ask rebuilds")
        XCTAssertNotNil(cache.timeline(record: record, claudeDir: root, maxBytes: narrow))
        XCTAssertEqual(cache.parses, 2, "the wide slot answers a narrow ask")
    }

    /// A wide (watched) slot keeps the reader's tail, so the rebuild after
    /// an append decodes only the new lines — and still yields what a
    /// fresh read of the whole transcript does (#346).
    func testAWideSlotRebuildsIncrementallyAfterAnAppend() throws {
        let url = try write([prompt, reply], sessionId: "s1")
        let record = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "idle")
        let cache = TimelineCache()
        XCTAssertEqual(cache.timeline(record: record, claudeDir: root)?.turns.map(\.id), ["u1"])
        let prompt2 = #"{"type":"user","uuid":"u2","timestamp":"2026-09-01T10:00:10.000Z","message":{"content":"more"}}"#
        let reply2 = #"{"type":"assistant","uuid":"a2","timestamp":"2026-09-01T10:00:12.000Z","message":{"content":[{"type":"text","text":"sure"}]}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((prompt2 + "\n" + reply2 + "\n").utf8))
        try handle.close()
        let grown = cache.timeline(record: record, claudeDir: root)
        XCTAssertEqual(grown?.turns.map(\.id), ["u1", "u2"])
        XCTAssertEqual(cache.parses, 2)
        XCTAssertEqual(grown, TimelineCache().timeline(record: record, claudeDir: root))
    }

    func testChangedTranscriptOrStatusReparses() throws {
        let url = try write([prompt], sessionId: "s1")
        let busy = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "busy")
        let cache = TimelineCache()
        XCTAssertEqual(cache.timeline(record: busy, claudeDir: root)?.latestTurn?.state, .running)
        try (prompt + "\n" + reply + "\n").write(to: url, atomically: true, encoding: .utf8)
        let idle = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "idle")
        XCTAssertEqual(cache.timeline(record: idle, claudeDir: root)?.latestTurn?.state, .completed)
        XCTAssertEqual(cache.parses, 2)
    }

    func testFactsCoverEveryRecordAndAppendOwnedPending() throws {
        _ = try write([prompt, reply], sessionId: "s1")
        _ = try write([prompt], sessionId: "s2", cwd: "/Users/me/other")
        let records = [ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "idle"),
                       ClaudeSessionRecord(pid: 42, sessionId: "s2", cwd: "/Users/me/other", status: "busy")]
        let store = AttentionStore(url: root.appendingPathComponent("attention.json"))
        store.apply(.pin, sessionId: "s1", until: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
        let pending = PendingRequest(requestId: "req-1", toolName: "Bash", toolUseId: nil, description: nil,
                                     inputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil, questions: [],
                                     receivedAt: Date())
        let cache = TimelineCache()
        let facts = cache.facts(records: records, claudeDir: root, attention: store) { $0 == 42 ? [pending] : [] }
        XCTAssertEqual(facts[41]?.status, .ready)
        XCTAssertNotNil(facts[41]?.pinnedAt)
        XCTAssertEqual(facts[42]?.status, .running)
        XCTAssertEqual(facts[42]?.hasPendingApprovals, true)
        // The cached timeline is the transcript's; pending rows are appended per call, never cached.
        XCTAssertEqual(cache.timeline(record: records[1], claudeDir: root)?.activities.isEmpty, true)
        XCTAssertEqual(cache.parses, 2)
    }

    func testFactsEvictSessionsThatLeft() throws {
        _ = try write([prompt], sessionId: "s1")
        let r1 = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "busy")
        let store = AttentionStore(url: root.appendingPathComponent("attention.json"))
        let cache = TimelineCache()
        _ = cache.facts(records: [r1], claudeDir: root, attention: store) { _ in [] }
        _ = cache.facts(records: [], claudeDir: root, attention: store) { _ in [] }
        _ = cache.timeline(record: r1, claudeDir: root)
        XCTAssertEqual(cache.parses, 2)
    }

    func testRebuildsAndFactsFlowIntoTheSequenceLog() throws {
        let url = try write([prompt], sessionId: "s1")
        let busy = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "busy")
        let log = SequenceLog(epoch: "e1")
        let cache = TimelineCache(log: log)
        let store = AttentionStore(url: root.appendingPathComponent("attention.json"))
        _ = cache.facts(records: [busy], claudeDir: root, attention: store) { _ in [] }
        let first = log.current
        XCTAssertEqual(log.events(pid: 41, after: 0)?.map(\.entity).suffix(1), [.facts])
        XCTAssertGreaterThan(first, 1)
        // Unchanged: nothing appended.
        _ = cache.facts(records: [busy], claudeDir: root, attention: store) { _ in [] }
        XCTAssertEqual(log.current, first)
        // Transcript grows and the turn closes: turn upsert, message upsert, facts.
        try (prompt + "\n" + reply + "\n").write(to: url, atomically: true, encoding: .utf8)
        let idle = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "idle")
        _ = cache.facts(records: [idle], claudeDir: root, attention: store) { _ in [] }
        XCTAssertEqual(log.events(pid: 41, after: first)?.map(\.entity), [.turn, .message, .facts])
        // Gone: dropped from the ring.
        _ = cache.facts(records: [], claudeDir: root, attention: store) { _ in [] }
        XCTAssertNil(log.events(pid: 41, after: 0))
    }

    func testAResumedPidStartsItsRingOver() throws {
        _ = try write([prompt], sessionId: "s1")
        _ = try write([prompt, reply], sessionId: "s2")
        let log = SequenceLog(epoch: "e1")
        let cache = TimelineCache(log: log)
        _ = cache.timeline(record: ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "busy"), claudeDir: root)
        let before = log.current
        _ = cache.timeline(record: ClaudeSessionRecord(pid: 41, sessionId: "s2", cwd: "/Users/me/repo", status: "idle"), claudeDir: root)
        // Only s2's fresh upserts remain reachable; s1's are gone with the drop.
        XCTAssertNil(log.events(pid: 41, after: 0))
        XCTAssertEqual(log.events(pid: 41, after: before)?.map(\.entity), [.turn, .message, .message])
    }

    func testFactsForASubsetKeepsTheRosterCached() throws {
        // Lease gating (#223 phase 5) computes facts for a subset; the
        // other sessions are still on the roster, so their slots and
        // rings stay — eviction is for sessions that LEFT.
        _ = try write([prompt], sessionId: "s1")
        _ = try write([prompt, reply], sessionId: "s2", cwd: "/Users/me/other")
        let r1 = ClaudeSessionRecord(pid: 41, sessionId: "s1", cwd: "/Users/me/repo", status: "busy")
        let r2 = ClaudeSessionRecord(pid: 42, sessionId: "s2", cwd: "/Users/me/other", status: "idle")
        let log = SequenceLog(epoch: "e1")
        let cache = TimelineCache(log: log)
        let store = AttentionStore(url: root.appendingPathComponent("attention.json"))
        _ = cache.facts(records: [r1, r2], claudeDir: root, attention: store) { _ in [] }
        let parsed = cache.parses
        let facts = cache.facts(records: [r1], claudeDir: root, attention: store, roster: [r1, r2]) { _ in [] }
        XCTAssertEqual(Array(facts.keys), [41])
        XCTAssertNotNil(log.events(pid: 42, after: 0))
        _ = cache.timeline(record: r2, claudeDir: root)
        XCTAssertEqual(cache.parses, parsed)
    }
}
