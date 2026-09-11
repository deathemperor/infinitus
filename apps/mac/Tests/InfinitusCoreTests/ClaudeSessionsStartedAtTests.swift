import XCTest
@testable import InfinitusCore

final class ClaudeSessionsStartedAtTests: XCTestCase {
    /// The record's `startedAt` is epoch milliseconds like `statusUpdatedAt`
    /// (#612); a record without it reads as nil and the status overlay keeps it.
    func testStartedAtIsReadFromTheRecordInEpochMilliseconds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = getpid()
        try Data(#"{"pid":\#(pid),"sessionId":"s1","cwd":"/tmp","kind":"interactive","startedAt":1700000000000}"#.utf8)
            .write(to: dir.appendingPathComponent("sessions/\(pid).json"))
        try Data(#"{"pid":\#(pid + 1),"sessionId":"s2","cwd":"/tmp","kind":"interactive"}"#.utf8)
            .write(to: dir.appendingPathComponent("sessions/\(pid + 1).json"))
        let records = ClaudeSessions.list(claudeDir: dir, alive: { _ in true })
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(records.first { $0.sessionId == "s1" }?.startedAt, started)
        XCTAssertNil(records.first { $0.sessionId == "s2" }?.startedAt)
        XCTAssertEqual(records.first { $0.sessionId == "s1" }?.with(status: "busy").startedAt, started)
    }
}
