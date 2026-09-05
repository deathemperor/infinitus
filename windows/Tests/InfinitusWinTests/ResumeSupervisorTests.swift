import XCTest
import InfinitusCore

/// The automatic resume pass's DECISION, exercised through
/// `infinitus-win resume --explain` (the executable's module can't be
/// linked into a test host — see DaemonHarness).
///
/// This is the part worth pinning: the Mac's equivalent once fired three
/// nudges in one minute into a session that was still limited, because
/// the "account is alive" verdict predated the stop. Each case below is a
/// state that must NOT produce a nudge, plus the one that must.
///
/// The account state comes from a JSON file via
/// `INFINITUS_ACCOUNTS_JSON`, so no real account, credential, or `cswap`
/// call is involved.
final class ResumeSupervisorTests: XCTestCase {
    /// A live account and a stop that PREDATES the last usage poll: the
    /// poll proves nothing about now, so the pass must hold. This is the
    /// exact shape of the 2026-09-01 runaway.
    func testHoldsWhenUsagePollPredatesTheStop() throws {
        try withStubbedEngine(activeAlive: true,
                              usageFetchedAt: "2026-09-04T02:00:00.000Z") { dir, engine in
            // Stop at 03:00, poll at 02:00 — an hour STALE.
            try self.writeStoppedSession(to: dir, stoppedAt: "2026-09-04T03:00:00.000Z")
            let (lines, error, status) = try DaemonHarness.run(
                ["resume", "--explain", "--claude-dir", dir.path],
                environment: ["INFINITUS_ACCOUNTS_JSON": engine.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            let text = lines.joined(separator: "\n")
            XCTAssertTrue(text.contains("would hold"),
                          "a stop newer than the usage poll must be held: \(text)")
            XCTAssertFalse(text.contains("would nudge 1"),
                           "must not nudge into the same wall: \(text)")
        }
    }

    /// A usage poll from moments BEFORE the stop clears the gate: an
    /// account polled alive seconds earlier cannot have died in between,
    /// so that stop is the old token failing right after a switch.
    func testNudgesWhenPollIsMomentsBeforeTheStop() throws {
        try withStubbedEngine(activeAlive: true,
                              usageFetchedAt: "2026-09-04T02:59:30.000Z") { dir, engine in
            // Stop at 03:00, poll 30 s earlier — inside freshBeforeStop.
            try self.writeStoppedSession(to: dir, stoppedAt: "2026-09-04T03:00:00.000Z")
            let (lines, error, status) = try DaemonHarness.run(
                ["resume", "--explain", "--claude-dir", dir.path],
                environment: ["INFINITUS_ACCOUNTS_JSON": engine.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            let text = lines.joined(separator: "\n")
            XCTAssertTrue(text.contains("would nudge"),
                          "a poll just before the stop is evidence, not staleness: \(text)")
        }
    }

    /// The account it would resume ONTO is at 100%: nudging would only
    /// burn the same wall again, so nothing is even considered.
    func testSkipsWhenActiveAccountIsAtALimit() throws {
        try withStubbedEngine(activeAlive: false,
                              usageFetchedAt: "2026-09-04T02:59:30.000Z") { dir, engine in
            try self.writeStoppedSession(to: dir, stoppedAt: "2026-09-04T03:00:00.000Z")
            let (lines, error, status) = try DaemonHarness.run(
                ["resume", "--explain", "--claude-dir", dir.path],
                environment: ["INFINITUS_ACCOUNTS_JSON": engine.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            let text = lines.joined(separator: "\n")
            XCTAssertTrue(text.contains("at a limit"), text)
            XCTAssertTrue(text.contains("would nudge nothing"), text)
        }
    }

    /// No engine at all: the pass has no quota signal, so it decides
    /// nothing rather than guessing. (The original reason `Resume.swift`
    /// kept the nudge manual — still true when cswap isn't installed.)
    func testSkipsWithoutAnEngine() throws {
        try DaemonHarness.scratch { dir in
            try self.writeStoppedSession(to: dir, stoppedAt: "2026-09-04T03:00:00.000Z")
            let (lines, error, status) = try DaemonHarness.run(
                ["resume", "--explain", "--claude-dir", dir.path],
                environment: ["INFINITUS_CSWAP": ""])   // empty = no engine
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            let text = lines.joined(separator: "\n")
            XCTAssertTrue(text.contains("would nudge nothing"), text)
            XCTAssertTrue(text.contains("engine reported nothing"), text)
        }
    }

    /// `--explain` must never deliver. A session whose transcript is a
    /// limit stop is left byte-identical.
    func testExplainWritesNothing() throws {
        try withStubbedEngine(activeAlive: true,
                              usageFetchedAt: "2026-09-04T02:59:30.000Z") { dir, engine in
            let transcript = try self.writeStoppedSession(
                to: dir, stoppedAt: "2026-09-04T03:00:00.000Z")
            let before = try Data(contentsOf: transcript)
            _ = try DaemonHarness.run(["resume", "--explain", "--claude-dir", dir.path],
                                      environment: ["INFINITUS_ACCOUNTS_JSON": engine.path])
            XCTAssertEqual(try Data(contentsOf: transcript), before,
                           "--explain must not write to a session")
        }
    }

    // MARK: plumbing

    /// A scratch `~/.claude` plus an account state for the gate to reason
    /// about, handed over as a file (`INFINITUS_ACCOUNTS_JSON`) rather
    /// than a stub engine: `Process.run()` uses CreateProcess, which
    /// cannot launch a `.cmd`, so a script stub is located fine and then
    /// silently fails — indistinguishable from "engine reported nothing".
    /// Nothing here touches the real engine or any credential.
    private func withStubbedEngine(activeAlive: Bool, usageFetchedAt: String,
                                   _ block: (URL, URL) throws -> Void) throws {
        try DaemonHarness.scratch { dir in
            // 100% is what AccountVitals.isDead keys on.
            let pct = activeAlive ? 12.0 : 100.0
            let list: [String: Any] = [
                "schemaVersion": 1,
                "activeAccountNumber": 1,
                "accounts": [[
                    "number": 1,
                    "email": "stub@example.com",
                    "organizationName": "Stub",
                    "organizationUuid": "0",
                    "isOrganization": false,
                    "active": true,
                    "usageStatus": "ok",
                    "usageFetchedAt": usageFetchedAt,
                    "usage": ["fiveHour": ["pct": pct], "sevenDay": ["pct": pct]],
                ]],
            ]
            let accounts = dir.appendingPathComponent("accounts.json")
            try JSONSerialization.data(withJSONObject: list).write(to: accounts)
            try block(dir, accounts)
        }
    }

    /// A live record plus a transcript whose last entry is a limit stop at
    /// `stoppedAt`. Returns the transcript path.
    @discardableResult
    private func writeStoppedSession(to dir: URL, stoppedAt: String) throws -> URL {
        let sessionId = "88888888-7777-6666-5555-444444444444"
        let cwd = "D:\\w\\synthetic-auto"
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let pid = SelfProcess.pid
        let record: [String: Any] = [
            "pid": pid,
            "sessionId": sessionId,
            "cwd": cwd,
            "startedAt": 1_788_494_441_754,
            "peerProtocol": 1,
            "kind": "interactive",
            "messagingSocketPath": "\\\\.\\pipe\\LOCAL\\cc-msg-autoresume-fixture",
            "name": "fixture-auto-stopped",
            "status": "idle",
            "statusUpdatedAt": 1_788_495_080_643,
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: sessions.appendingPathComponent("\(pid).json"))

        let transcript = Transcript.path(cwd: cwd, sessionId: sessionId, claudeDir: dir)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stop: [String: Any] = [
            "type": "assistant", "uuid": "auto-stop-1",
            "timestamp": stoppedAt,
            "isApiErrorMessage": true,
            "error": "rate_limit",
            "message": ["role": "assistant", "content": [[
                "type": "text",
                "text": "5-hour limit reached ∙ resets 4pm",
            ]]],
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: stop), as: UTF8.self)
        try (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return transcript
    }
}
