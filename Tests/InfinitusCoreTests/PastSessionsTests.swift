import XCTest
@testable import InfinitusCore

/// `PastSessions.scan` (#164): every transcript under projects/, newest
/// first, cwd and opening prompt off the head only.
final class PastSessionsTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-past-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func user(_ text: String, cwd: String? = nil) -> String {
        let cwdField = cwd.map { #","cwd":"\#($0)""# } ?? ""
        return #"{"type":"user","message":{"role":"user","content":"\#(text)"}\#(cwdField),"uuid":"u"}"#
    }

    @discardableResult
    private func write(cwd: String, id: String, lines: [String], age: TimeInterval) throws -> URL {
        let url = Transcript.path(cwd: cwd, sessionId: id, claudeDir: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testNewestFirstWithCwdFromAnyHeadEntryAndSubagentsSkipped() throws {
        // The cwd rides a later entry, not the first line — the first
        // lines of a real transcript are prompt/mode bookkeeping.
        try write(cwd: "/Users/x/alpha", id: "old", lines: [#"{"type":"last-prompt","lastPrompt":"x"}"#,
                                                            user("Fix the crash", cwd: "/Users/x/alpha")], age: 3600)
        let newer = try write(cwd: "/Users/x/beta", id: "new",
                              lines: [user("Write the docs", cwd: "/Users/x/beta")], age: 60)
        let subagents = newer.deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try user("sub-agent brief", cwd: "/Users/x/beta")
            .write(to: subagents.appendingPathComponent("agent-a.jsonl"), atomically: true, encoding: .utf8)

        let sessions = PastSessions.scan(claudeDir: dir, liveIds: ["new"])
        XCTAssertEqual(sessions.map(\.sessionId), ["new", "old"])
        XCTAssertEqual(sessions[0].cwd, "/Users/x/beta")
        XCTAssertEqual(sessions[0].repo, "beta")
        XCTAssertEqual(sessions[0].firstMessage, "Write the docs")
        XCTAssertTrue(sessions[0].live)
        XCTAssertFalse(sessions[1].live)
        XCTAssertEqual(sessions[1].firstMessage, "Fix the crash")
        XCTAssertGreaterThan(sessions[1].bytes, 0)
    }

    func testFirstCwdWinsOverALaterMove() throws {
        try write(cwd: "/Users/x/repo", id: "s", lines: [user("Start here", cwd: "/Users/x/repo"),
                                                         user("moved", cwd: "/Users/x/repo-worktree")], age: 10)
        XCTAssertEqual(PastSessions.scan(claudeDir: dir).first?.cwd, "/Users/x/repo")
    }

    func testEmptySessionIsDroppedAndLimitAndSearchApply() throws {
        try write(cwd: "/p", id: "empty", lines: [#"{"type":"last-prompt","lastPrompt":"x","cwd":"/p"}"#], age: 1)
        try write(cwd: "/p", id: "a", lines: [user("Alpha task", cwd: "/p/alpha")], age: 100)
        try write(cwd: "/p", id: "b", lines: [user("Beta task", cwd: "/p/beta")], age: 200)
        try write(cwd: "/p", id: "c", lines: [user("Gamma task", cwd: "/p/gamma")], age: 300)

        XCTAssertEqual(PastSessions.scan(claudeDir: dir).map(\.sessionId), ["a", "b", "c"])
        // limit counts transcripts looked at, the empty newest one included.
        XCTAssertEqual(PastSessions.scan(claudeDir: dir, limit: 2).map(\.sessionId), ["a"])
        XCTAssertEqual(PastSessions.scan(claudeDir: dir, search: "BETA").map(\.sessionId), ["b"])
        XCTAssertEqual(PastSessions.scan(claudeDir: dir, search: "/p/gamma").map(\.sessionId), ["c"])
        XCTAssertNil(PastSessions.find(sessionId: "nope", claudeDir: dir))
    }

    func testFindReachesPastTheNewestFilesByName() throws {
        for i in 0..<6 {
            try write(cwd: "/p", id: "s\(i)", lines: [user("Task \(i)", cwd: "/p/repo\(i)")], age: Double(i) * 100)
        }
        let oldest = PastSessions.find(sessionId: "s5", claudeDir: dir, liveIds: ["s5"])
        XCTAssertEqual(oldest?.cwd, "/p/repo5")
        XCTAssertEqual(oldest?.firstMessage, "Task 5")
        XCTAssertTrue(oldest?.live ?? false)
    }

    func testListMarksLiveFromTheSessionRecords() throws {
        try write(cwd: "/p", id: "a", lines: [user("Alpha", cwd: "/p/alpha")], age: 10)
        try write(cwd: "/p", id: "b", lines: [user("Beta", cwd: "/p/beta")], age: 20)
        let records = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try #"{"pid":4242,"sessionId":"a","cwd":"/p/alpha","kind":"interactive"}"#
            .write(to: records.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        let sessions = PastSessions.list(claudeDir: dir, alive: { _ in true })
        XCTAssertEqual(sessions.map { ($0.sessionId, $0.live) }.map { "\($0.0):\($0.1)" }, ["a:true", "b:false"])
        XCTAssertEqual(PastSessions.list(claudeDir: dir, alive: { _ in false }).map(\.live), [false, false])
    }

    func testInfinitusOwnHeadlessRunsAreHidden() throws {
        try write(cwd: "/p", id: "namer", lines: [user("[Infinitus] Title this coding session in 3 to 6 words", cwd: "/p/namer")], age: 1)
        try write(cwd: "/p", id: "real", lines: [user("Fix the tests", cwd: "/p/real")], age: 2)
        XCTAssertEqual(PastSessions.scan(claudeDir: dir).map(\.sessionId), ["real"])
    }

    /// The head cache (#346): a scan re-reads a head only while the file
    /// is short enough for appends to still reach it; what changes per
    /// scan — mtime, size, liveness — comes from the listing, not the cache.
    func testRescansReuseTheHeadButRefreshMtimeSizeAndLiveness() throws {
        let pad = #"{"type":"progress","filler":""# + String(repeating: "x", count: 4096) + #""}"#
        let big = [user("Long session", cwd: "/p/big")] + Array(repeating: pad, count: 20)
        try write(cwd: "/p", id: "a", lines: big, age: 100)
        let first = try XCTUnwrap(PastSessions.scan(claudeDir: dir, liveIds: ["a"]).first)
        XCTAssertGreaterThan(first.bytes, PastSessions.headBytes)
        XCTAssertTrue(first.live)

        // Past headBytes the head is frozen: a rewrite the picker would
        // never see (transcripts are append-only) keeps the cached prompt,
        // while the newer mtime, size and the ended session come through.
        try write(cwd: "/p", id: "a", lines: [user("Rewritten", cwd: "/p/big")] + big.dropFirst() + [pad], age: 1)
        let again = try XCTUnwrap(PastSessions.scan(claudeDir: dir).first)
        XCTAssertEqual(again.firstMessage, "Long session")
        XCTAssertGreaterThan(again.lastActivityAt, first.lastActivityAt)
        XCTAssertGreaterThan(again.bytes, first.bytes)
        XCTAssertFalse(again.live)
    }

    func testShortTranscriptsRereadOnMtimeAndGoneOnesLeaveTheCache() throws {
        try write(cwd: "/p", id: "s", lines: [#"{"type":"last-prompt","lastPrompt":"x","cwd":"/p/s"}"#], age: 50)
        XCTAssertEqual(PastSessions.scan(claudeDir: dir), [])
        // The prompt lands later, with a newer mtime — the empty head is
        // not what a short transcript keeps.
        try write(cwd: "/p", id: "s", lines: [user("Now started", cwd: "/p/s")], age: 1)
        XCTAssertEqual(PastSessions.scan(claudeDir: dir).map(\.firstMessage), ["Now started"])
        let held = PastSessions.heads.count
        try FileManager.default.removeItem(at: Transcript.path(cwd: "/p", sessionId: "s", claudeDir: dir))
        XCTAssertEqual(PastSessions.scan(claudeDir: dir), [])
        XCTAssertEqual(PastSessions.heads.count, held - 1)
    }

    func testMissingProjectsDirIsEmpty() {
        XCTAssertEqual(PastSessions.scan(claudeDir: dir.appendingPathComponent("none")), [])
    }

    /// #346: the fingerprint moves when a transcript is created in a
    /// project dir and holds while an existing one only grows.
    func testFingerprintTracksCreationsNotAppends() throws {
        XCTAssertEqual(PastSessions.fingerprint(claudeDir: dir), "")
        let url = try write(cwd: "/w/a", id: "s1", lines: [user("hi")], age: 60)
        let first = PastSessions.fingerprint(claudeDir: dir)
        XCTAssertFalse(first.isEmpty)
        try (user("more") + "\n").write(to: url, atomically: false, encoding: .utf8)
        // A rewrite in place keeps the directory entry; an append would too.
        XCTAssertEqual(PastSessions.fingerprint(claudeDir: dir), first)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)],
                                              ofItemAtPath: url.deletingLastPathComponent().path)
        let moved = PastSessions.fingerprint(claudeDir: dir)
        XCTAssertNotEqual(moved, first)
        try write(cwd: "/w/b", id: "s2", lines: [user("hey")], age: 10)
        XCTAssertNotEqual(PastSessions.fingerprint(claudeDir: dir), moved)
    }
}
