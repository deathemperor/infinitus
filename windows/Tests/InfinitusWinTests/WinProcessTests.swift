import XCTest
@testable import InfinitusCore

/// W3: session JSON parsing (core, against checked-in synthetic records)
/// and the `sessions` subcommand's liveness filtering end to end. The
/// daemon runs as a subprocess — importing the executable's module kills
/// the test host (W2).
final class WinProcessTests: XCTestCase {
    /// Core's parse of the synthetic record pair, one good one garbage —
    /// the bad file must not take the listing down.
    func testCoreParsesSyntheticSessionRecords() throws {
        let records = ClaudeSessions.list(claudeDir: DaemonHarness.fixtures,
                                          alive: { _ in true })
        XCTAssertEqual(records.map(\.pid), [1111])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.sessionId, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(record.cwd, "D:\\w\\synthetic")
        XCTAssertEqual(record.kind, "interactive")
        XCTAssertEqual(record.status, "idle")
        XCTAssertEqual(record.name, "fixture-dead")
        XCTAssertEqual(record.messagingSocketPath,
                       "\\\\.\\pipe\\LOCAL\\cc-msg-00000000000000000000000000001111")
        XCTAssertEqual(record.peerProtocol, 1)
        XCTAssertEqual(record.statusUpdatedAt,
                       Date(timeIntervalSince1970: 1_788_495_080.643))
    }

    /// A record with no `procStart` (older builds) is listed on the
    /// pid-only check; the dead pid and the malformed record are not.
    func testSessionsSubcommandListsLivePidsWithoutProcStart() throws {
        try DaemonHarness.scratch { dir in
            try self.writeRecord(pid: SelfProcess.pid, procStart: nil, to: dir)
            self.copyFixture("1111.json", to: dir)
            self.copyFixture("2222.json", to: dir)
            let rows = try self.sessionRows(claudeDir: dir)
            XCTAssertEqual(rows.map(\.pid), [SelfProcess.pid])
            XCTAssertEqual(rows.first?.alive, true)
            XCTAssertEqual(rows.first?.pipe, false, "no server on a made-up pipe")
            XCTAssertEqual(rows.first?.kind, "interactive")
            XCTAssertEqual(rows.first?.name, "fixture-live")
        }
    }

    /// The pid-reuse guard: a live pid whose `procStart` matches
    /// `GetProcessTimes` is listed; one tick off and it is excluded.
    func testSessionsSubcommandDropsReusedPidOnFiletimeMismatch() throws {
        let actual = try XCTUnwrap(SelfProcess.procStart)
        try DaemonHarness.scratch { dir in
            try self.writeRecord(pid: SelfProcess.pid, procStart: actual, to: dir)
            XCTAssertEqual(try self.sessionRows(claudeDir: dir).map(\.pid), [SelfProcess.pid])
        }
        try DaemonHarness.scratch { dir in
            let stale = String((Int(actual) ?? 0) + 1)
            try self.writeRecord(pid: SelfProcess.pid, procStart: stale, to: dir)
            XCTAssertTrue(try self.sessionRows(claudeDir: dir).isEmpty,
                          "a reused pid must not come back as a session")
        }
    }

    // MARK: plumbing

    /// The daemon's JSON rows for a synthetic `~/.claude` dir.
    private func sessionRows(claudeDir: URL) throws -> [Row] {
        let (lines, error, status) = try DaemonHarness.run(
            ["sessions"],
            environment: ["CLAUDE_CONFIG_DIR": claudeDir.path])
        XCTAssertEqual(status, 0, error.joined(separator: "\n"))
        return try JSONDecoder().decode([Row].self, from: XCTUnwrap(
            lines.joined(separator: "\n").data(using: .utf8)))
    }

    /// Writes the record whose pid the daemon's own liveness checks.
    private func writeRecord(pid: Int32, procStart: String?, to dir: URL) throws {
        var record: [String: Any] = [
            "pid": pid,
            "sessionId": "99999999-8888-7777-6666-555555555555",
            "cwd": "D:\\w\\synthetic",
            "startedAt": 1_788_494_441_754,
            "peerProtocol": 1,
            "kind": "interactive",
            "pidDomain": "win32:fixture",
            "messagingSocketPath": "\\\\.\\pipe\\LOCAL\\cc-msg-9999999999999999",
            "name": "fixture-live",
            "nameSource": "derived",
            "updatedAt": 1_788_495_080_643,
            "status": "idle",
            "statusUpdatedAt": 1_788_495_080_643,
        ]
        if let procStart { record["procStart"] = procStart }
        try JSONSerialization.data(withJSONObject: record)
            .write(to: Self.sessionsDir(in: dir).appendingPathComponent("\(pid).json"))
    }

    private func copyFixture(_ name: String, to dir: URL) {
        let source = DaemonHarness.fixtures.appendingPathComponent("sessions")
            .appendingPathComponent(name)
        try? FileManager.default.copyItem(
            at: source, to: Self.sessionsDir(in: dir).appendingPathComponent(name))
    }

    /// Records live under `<claudeDir>/sessions`, the layout the daemon
    /// reads — a scratch dir starts empty, so create it on first use.
    private static func sessionsDir(in dir: URL) -> URL {
        let sessions = dir.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return sessions
    }

    /// The `sessions` row shape the phone-facing JSON carries.
    private struct Row: Decodable {
        let pid: Int32
        let name: String?
        let kind: String
        let status: String?
        let cwd: String
        let messagingSocketPath: String
        let alive: Bool
        let pipe: Bool
    }
}
