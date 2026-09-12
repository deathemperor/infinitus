import XCTest
@testable import InfinitusCore

/// #1002: a record file is empty between a writer's truncate and its
/// write, and a listing in that window must not lose the session.
final class ClaudeSessionsTornRecordTests: XCTestCase {
    private func sessionsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return dir
    }

    private func record(pid: Int32, id: String) -> Data {
        Data(#"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"/tmp","kind":"interactive","status":"busy"}"#.utf8)
    }

    func testAnEmptyRecordKeepsWhatItSaidLastForThePass() throws {
        let dir = try sessionsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = getpid()
        let file = dir.appendingPathComponent("sessions/\(pid).json")
        try record(pid: pid, id: "s1").write(to: file)
        XCTAssertEqual(ClaudeSessions.list(claudeDir: dir, alive: { _ in true }).map(\.sessionId), ["s1"])
        try Data().write(to: file)   // truncated, the write not landed yet
        let torn = ClaudeSessions.list(claudeDir: dir, alive: { _ in true }, rereadDelay: 0.001)
        XCTAssertEqual(torn.map(\.sessionId), ["s1"], "the last reading stands in for the record mid-rewrite")
        XCTAssertEqual(torn.first?.status, "busy")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(ClaudeSessions.list(claudeDir: dir, alive: { _ in true }, rereadDelay: 0.001).count, 0,
                       "a record that is gone is not served from memory")
    }

    func testARecordThatLandsWithinTheRereadIsRead() throws {
        let dir = try sessionsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = getpid()
        let file = dir.appendingPathComponent("sessions/\(pid).json")
        try Data().write(to: file)
        let payload = record(pid: pid, id: "fresh")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { try? payload.write(to: file) }
        let records = ClaudeSessions.list(claudeDir: dir, alive: { _ in true }, rereadDelay: 1)
        XCTAssertEqual(records.map(\.sessionId), ["fresh"])
    }

    func testAnUnreadableRecordWithNoLastReadingIsSkipped() throws {
        let dir = try sessionsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("sessions/\(getpid()).json"))
        try record(pid: getpid() + 1, id: "other").write(to: dir.appendingPathComponent("sessions/\(getpid() + 1).json"))
        XCTAssertEqual(ClaudeSessions.list(claudeDir: dir, alive: { _ in true }, rereadDelay: 0.001).map(\.sessionId), ["other"])
    }

    func testTheLastReadingIsDroppedWithItsProcess() throws {
        let dir = try sessionsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sessions/4242.json")
        try record(pid: 4242, id: "gone").write(to: file)
        XCTAssertEqual(ClaudeSessions.list(claudeDir: dir, alive: { _ in true }).count, 1)
        try Data().write(to: file)
        XCTAssertEqual(ClaudeSessions.list(claudeDir: dir, alive: { _ in false }, rereadDelay: 0.001).count, 0)
    }
}
