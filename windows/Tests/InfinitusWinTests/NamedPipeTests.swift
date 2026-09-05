import XCTest
import InfinitusCore

/// W10: the bytes the daemon writes to a session's messaging pipe. The
/// wire format is Claude Code's, not ours — a reshaped frame is silently
/// ignored by the receiver, so these pin the payload exactly.
final class NamedPipeTests: XCTestCase {
    /// `message --dry-run` emits the auth frame then the user frame, both
    /// NDJSON, with the token read from the session's `.key` file.
    func testFramesCarryAuthThenEnvelope() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, token: "cafebabe", to: dir)
            let (lines, error, status) = try DaemonHarness.run(
                ["message", "--pid", "\(SelfProcess.pid)", "--claude-dir", dir.path,
                 "--dry-run", "ping from the daemon"])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            XCTAssertEqual(lines.count, 2, "auth frame then user frame")

            let auth = try self.json(lines[0])
            XCTAssertEqual(auth["type"] as? String, "auth")
            XCTAssertEqual(auth["token"] as? String, "cafebabe")

            let user = try self.json(lines[1])
            XCTAssertEqual(user["type"] as? String, "user")
            XCTAssertEqual(user["msgV"] as? Int, PeerSocket.messageVersion)
            XCTAssertEqual(user["priority"] as? String, "next")
            let from = try XCTUnwrap(user["from"] as? String)
            XCTAssertTrue(from.hasPrefix("uds:"), "the receiver's parser needs a uds: address")
            XCTAssertTrue(from.contains("infinitus-"), "the daemon names itself")

            let message = try XCTUnwrap(user["message"] as? [String: Any])
            XCTAssertEqual(message["role"] as? String, "user")
            let content = try XCTUnwrap(message["content"] as? String)
            XCTAssertTrue(content.hasPrefix("<cross-session-message from=\""))
            XCTAssertTrue(content.contains("from-name=\"Infinitus app\""))
            XCTAssertTrue(content.contains("\nping from the daemon\n"),
                          "the envelope's newlines around the body are fixed by the receiver")
            XCTAssertTrue(content.hasSuffix("</cross-session-message>"))
        }
    }

    /// The address is percent-encoded the way the envelope parser demands,
    /// and a pipe path survives it (backslashes are in `addressSafe`).
    func testOwnAddressEscapesLikeCore() {
        let address = PeerSocket.escapeAddress("\\\\.\\pipe\\LOCAL\\infinitus-42")
        XCTAssertEqual(address, "uds:\\\\.\\pipe\\LOCAL\\infinitus-42")
        XCTAssertEqual(PeerSocket.escapeAddress("/tmp/a b.sock"), "uds:/tmp/a%20b.sock")
    }

    /// A session with no pipe in its record is refused before any IO.
    func testMessageRefusesASessionWithNoPipe() throws {
        try DaemonHarness.scratch { dir in
            try self.writeSession(pid: SelfProcess.pid, token: "t", pipe: "", to: dir)
            let (_, error, status) = try DaemonHarness.run(
                ["message", "--pid", "\(SelfProcess.pid)", "--claude-dir", dir.path, "hi"])
            XCTAssertEqual(status, 2)
            XCTAssertTrue(error.joined().contains("no messaging pipe"), error.joined())
        }
    }

    /// A pid with no live record never reaches the pipe layer.
    func testMessageRefusesAnUnknownPid() throws {
        try DaemonHarness.scratch { dir in
            let (_, error, status) = try DaemonHarness.run(
                ["message", "--pid", "999999", "--claude-dir", dir.path, "hi"])
            XCTAssertEqual(status, 2)
            XCTAssertTrue(error.joined().contains("no live session"), error.joined())
        }
    }

    // MARK: plumbing

    private func json(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(line.data(using: .utf8))) as? [String: Any])
    }

    /// A live-looking record plus the `.key` file `PeerSocket.peerToken`
    /// finds by `<pid>.` prefix.
    private func writeSession(pid: Int32, token: String,
                              pipe: String = "\\\\.\\pipe\\LOCAL\\cc-msg-fixture",
                              to dir: URL) throws {
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "pid": pid,
            "sessionId": "99999999-8888-7777-6666-555555555555",
            "cwd": "D:\\w\\synthetic",
            "startedAt": 1_788_494_441_754,
            "peerProtocol": 1,
            "kind": "interactive",
            "messagingSocketPath": pipe,
            "name": "fixture-live",
            "status": "idle",
            "statusUpdatedAt": 1_788_495_080_643,
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: sessions.appendingPathComponent("\(pid).json"))
        try JSONSerialization.data(withJSONObject: ["peerToken": token, "pidDomain": "win32:fixture"])
            .write(to: sessions.appendingPathComponent("\(pid).abcdef.key"))
    }
}
