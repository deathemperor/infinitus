import XCTest
import InfinitusCore

/// W6: the `GET /snapshot` body. Built through `infinitus-win snapshot`
/// against a synthetic `~/.claude` (the daemon runs as a subprocess —
/// importing the executable's module kills the test host, W2) and decoded
/// with the phone's own `MirrorSnapshot`, so a field the phone can't read
/// fails here.
final class SnapshotTests: XCTestCase {
    /// The whole payload decodes on the phone's type, carries the
    /// synthetic engine-less fleet, and counts the live records.
    func testDecodesOnPhoneShape() throws {
        try DaemonHarness.scratch { dir in
            try self.writeRecord(pid: SelfProcess.pid, status: "busy", to: dir)
            // Engine pinned off so the shape is the same on a box with
            // cswap installed and one without; the engine-present fleet is
            // the Mac's own EngineFleet, covered by the core's tests.
            let snapshot = try self.snapshot(claudeDir: dir, environment: ["INFINITUS_CSWAP": ""])

            XCTAssertFalse(snapshot.machineName.isEmpty, "the phone labels the host with this")
            let fleet = try XCTUnwrap(snapshot.fleets?.first)
            XCTAssertEqual(fleet.engineID, "claude-code-windows")
            XCTAssertEqual(fleet.provider, .claude)
            XCTAssertTrue(fleet.accounts.isEmpty, "no engine on this run")
            XCTAssertEqual(fleet.liveSessions?.total, 1)
            XCTAssertEqual(fleet.liveSessions?.busy, 1)
            XCTAssertEqual(fleet.liveSessions?.sessions?.first?.pid, Int(SelfProcess.pid))
            XCTAssertEqual(fleet.liveSessions?.sessions?.first?.startedAt, 1_788_494_441_754)
            XCTAssertNotNil(snapshot.progressByPid?[Int(SelfProcess.pid)],
                            "every live session gets a name, not just the panel rows")
        }
    }

    /// `listJSON` keeps a phone older than `fleets` working: it decodes as
    /// an `AccountList` whose `liveSessions` matches the fleet's.
    func testListJSONDecodesAsAccountListForOlderPhones() throws {
        try DaemonHarness.scratch { dir in
            try self.writeRecord(pid: SelfProcess.pid, status: "idle", to: dir)
            let snapshot = try self.snapshot(claudeDir: dir)
            let list = try JSONDecoder().decode(AccountList.self, from: snapshot.listJSON)
            XCTAssertEqual(list.schemaVersion, 1)
            XCTAssertTrue(list.accounts.isEmpty)
            XCTAssertNil(list.activeAccountNumber)
            XCTAssertEqual(list.liveSessions?.total, 1)
            XCTAssertEqual(list.liveSessions?.idle, 1)
        }
    }

    /// Only busy/waiting records become panel rows (the Mac's selection);
    /// an idle-only host has none, while every record still reaches
    /// `liveSessions` and `progressByPid`.
    func testPanelRowsTakeBusyAndWaitingOnly() throws {
        try DaemonHarness.scratch { dir in
            try self.writeRecord(pid: SelfProcess.pid, status: "idle", to: dir)
            let snapshot = try self.snapshot(claudeDir: dir)
            XCTAssertTrue(snapshot.sessions.isEmpty, "idle sessions are not panel rows")
            XCTAssertEqual(snapshot.fleets?.first?.liveSessions?.total, 1)
            XCTAssertEqual(snapshot.progressByPid?.count, 1)
        }
    }

    /// With no swap engine on the box the fleet stays synthetic and
    /// account-less — the phone hides that section rather than showing a
    /// pane of zeros. `INFINITUS_CSWAP=""` is CswapLocator's own "no
    /// engine" switch.
    func testFleetIsSyntheticWithoutTheEngine() throws {
        try DaemonHarness.scratch { dir in
            try self.writeRecord(pid: SelfProcess.pid, status: "idle", to: dir)
            let snapshot = try self.snapshot(claudeDir: dir, environment: ["INFINITUS_CSWAP": ""])
            let fleet = try XCTUnwrap(snapshot.fleets?.first)
            XCTAssertEqual(fleet.engineID, "claude-code-windows")
            XCTAssertTrue(fleet.accounts.isEmpty)
            XCTAssertNil(fleet.activeNumber)
            XCTAssertEqual(fleet.liveSessions?.total, 1, "sessions serve with or without an engine")
        }
    }

    /// When Claude Code is routed through 9Router via ANTHROPIC_BASE_URL
    /// in settings.json and cswap is absent, the synthetic fleet reflects
    /// the 9Router routing (`claude-code-windows-9router`).
    func testFleetIsSyntheticWith9RouterRouting() throws {
        try DaemonHarness.scratch { dir in
            try self.writeRecord(pid: SelfProcess.pid, status: "idle", to: dir)
            let settings: [String: Any] = [
                "env": [
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:20128"
                ]
            ]
            try JSONSerialization.data(withJSONObject: settings)
                .write(to: dir.appendingPathComponent("settings.json"))

            let snapshot = try self.snapshot(claudeDir: dir, environment: ["INFINITUS_CSWAP": ""])
            let fleet = try XCTUnwrap(snapshot.fleets?.first)
            XCTAssertEqual(fleet.engineID, "claude-code-windows-9router")
            XCTAssertTrue(fleet.accounts.isEmpty)
            XCTAssertNil(fleet.activeNumber)
            XCTAssertEqual(fleet.liveSessions?.total, 1)
        }
    }

    // MARK: plumbing

    /// The daemon's snapshot for a synthetic `~/.claude` dir, decoded the
    /// way the phone decodes it (`.iso8601`).
    private func snapshot(claudeDir: URL,
                          environment: [String: String] = [:]) throws -> MirrorSnapshot {
        let (lines, error, status) = try DaemonHarness.run(
            ["snapshot", "--claude-dir", claudeDir.path], environment: environment)
        XCTAssertEqual(status, 0, error.joined(separator: "\n"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MirrorSnapshot.self, from: XCTUnwrap(
            lines.joined(separator: "\n").data(using: .utf8)))
    }

    /// A record pointing at this test process, so the daemon's liveness
    /// path has a real pid to walk.
    private func writeRecord(pid: Int32, status: String, to dir: URL) throws {
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
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
            "status": status,
            "statusUpdatedAt": 1_788_495_080_643,
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: sessions.appendingPathComponent("\(pid).json"))
    }
}
