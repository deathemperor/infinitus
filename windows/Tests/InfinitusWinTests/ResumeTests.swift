import XCTest
import InfinitusCore

/// W15: `infinitus-win resume`. The limit-stop detection is core's
/// (`Transcript.findStopped`) — what's tested here is that the daemon
/// finds a stopped session in a synthetic `~/.claude`, reports its
/// reachability honestly, and writes nothing on `--dry-run`.
final class ResumeTests: XCTestCase {
    /// A transcript whose tail is a limit stop shows up, labelled by
    /// whether its pipe still answers (a fixture's never does).
    func testDryRunListsAStoppedSession() throws {
        try DaemonHarness.scratch { dir in
            try self.writeStoppedSession(pid: SelfProcess.pid, to: dir)
            let (lines, error, status) = try DaemonHarness.run(
                ["resume", "--dry-run", "--claude-dir", dir.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            let row = try XCTUnwrap(lines.first)
            XCTAssertTrue(row.hasPrefix("\(SelfProcess.pid) "), row)
            XCTAssertTrue(row.contains("fixture-stopped"), row)
            XCTAssertTrue(row.contains("pipe gone"),
                          "a fixture pipe has no server, and the daemon says so: \(row)")
        }
    }

    /// `--pid` narrows to one session; a pid that isn't stopped yields the
    /// quiet "nothing stopped" line, not an error.
    func testDryRunFiltersByPid() throws {
        try DaemonHarness.scratch { dir in
            try self.writeStoppedSession(pid: SelfProcess.pid, to: dir)
            let (lines, error, status) = try DaemonHarness.run(
                ["resume", "--dry-run", "--pid", "999999", "--claude-dir", dir.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            XCTAssertEqual(lines, ["nothing stopped at a usage limit"])
        }
    }

    /// A `~/.claude` with no limit stop says so and exits clean — the
    /// phone polls this, so "nothing to do" is not a failure.
    func testNothingStoppedIsNotAnError() throws {
        try DaemonHarness.scratch { dir in
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            let (lines, error, status) = try DaemonHarness.run(
                ["resume", "--dry-run", "--claude-dir", dir.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            XCTAssertEqual(lines, ["nothing stopped at a usage limit"])
        }
    }

    // MARK: plumbing

    /// A live record plus a transcript whose last entry is the limit stop
    /// `Transcript.findStopped` looks for.
    private func writeStoppedSession(pid: Int32, to dir: URL) throws {
        let sessionId = "77777777-6666-5555-4444-333333333333"
        let cwd = "D:\\w\\synthetic"
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "pid": pid,
            "sessionId": sessionId,
            "cwd": cwd,
            "startedAt": 1_788_494_441_754,
            "peerProtocol": 1,
            "kind": "interactive",
            "messagingSocketPath": "\\\\.\\pipe\\LOCAL\\cc-msg-resume-fixture",
            "name": "fixture-stopped",
            "status": "idle",
            "statusUpdatedAt": 1_788_495_080_643,
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: sessions.appendingPathComponent("\(pid).json"))

        let transcript = Transcript.path(cwd: cwd, sessionId: sessionId, claudeDir: dir)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The shape `Transcript.isLimitStop` keys on: an assistant entry
        // flagged as an API error whose `error` is `rate_limit`, with no
        // `retryAttempt` (a retry is Claude Code still trying, not a stop).
        let stop: [String: Any] = [
            "type": "assistant", "uuid": "stop-1",
            "timestamp": "2026-09-04T03:00:00.000Z",
            "isApiErrorMessage": true,
            "error": "rate_limit",
            "message": ["role": "assistant", "content": [[
                "type": "text",
                "text": "5-hour limit reached ∙ resets 4pm",
            ]]],
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: stop), as: UTF8.self)
        try (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)
    }
}
