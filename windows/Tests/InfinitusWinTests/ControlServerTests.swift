import XCTest
import Foundation
import InfinitusCore
#if os(Windows)
import WinSDK
#endif

/// ControlServer tests exercising the named pipe control socket and the
/// `infinitus-win control` client against a running daemon subprocess.
final class ControlServerTests: XCTestCase {
    /// Launches `infinitus-win serve` on an ephemeral port with an isolated control pipe
    /// and an isolated claude directory.
    private func withServe(pipeName: String,
                           claudeDir: URL,
                           _ block: (UInt16) throws -> Void) throws {
        guard let executable = DaemonHarness.executable() else {
            throw XCTSkip("infinitus-win.exe not built — run `swift build --product infinitus-win` first")
        }
        let output = DaemonHarness.tempFile("out")
        let error = DaemonHarness.tempFile("err")
        let tokenFile = DaemonHarness.tempFile("token")
        try Data("TESTPAIRINGTOKEN12345678".utf8).write(to: tokenFile)
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: error)
            try? FileManager.default.removeItem(at: tokenFile)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "serve",
            "--port", "0",
            "--claude-dir", claudeDir.path,
            "--token-file", tokenFile.path,
        ]
        var env = ProcessInfo.processInfo.environment
        env["INFINITUS_CONTROL_PIPE"] = pipeName
        process.environment = env
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let port = try waitForPort(output)
        try block(port)
    }

    private func waitForPort(_ output: URL, timeout: TimeInterval = 10) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: output, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: " ")
                    if parts.count == 3, parts[0] == "listening", parts[1] == "on",
                       let port = UInt16(parts[2]) {
                        return port
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTFailure("serve never reported 'listening on N'")
    }

    /// `control status` returns serving port, session count, enginePresent, etc.
    func testControlStatus() throws {
        let pipeName = "infinitus-test-status-\(UUID().uuidString)"
        try DaemonHarness.scratch { dir in
            try self.withServe(pipeName: pipeName, claudeDir: dir) { boundPort in
                let (lines, error, status) = try DaemonHarness.run(
                    ["control", "status"],
                    environment: ["INFINITUS_CONTROL_PIPE": pipeName]
                )
                XCTAssertEqual(status, 0, error.joined(separator: "\n"))
                let joined = lines.joined(separator: "\n")
                guard let data = joined.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    XCTFail("could not parse status JSON: \(joined)")
                    return
                }
                XCTAssertEqual(json["servingPort"] as? UInt16, boundPort)
                XCTAssertNotNil(json["uptimeSeconds"])
                XCTAssertNotNil(json["sessionCount"])
                XCTAssertNotNil(json["enginePresent"])
                XCTAssertNotNil(json["bonjour"])
            }
        }
    }

    /// `control sessions` returns the live session list matching `sessions`.
    func testControlSessions() throws {
        let pipeName = "infinitus-test-sessions-\(UUID().uuidString)"
        try DaemonHarness.scratch { dir in
            try self.writeSyntheticSession(pid: SelfProcess.pid, to: dir)
            try self.withServe(pipeName: pipeName, claudeDir: dir) { _ in
                let (lines, error, status) = try DaemonHarness.run(
                    ["control", "sessions"],
                    environment: ["INFINITUS_CONTROL_PIPE": pipeName]
                )
                XCTAssertEqual(status, 0, error.joined(separator: "\n"))
                let joined = lines.joined(separator: "\n")
                guard let data = joined.data(using: .utf8),
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    XCTFail("could not parse sessions JSON: \(joined)")
                    return
                }
                XCTAssertEqual(list.count, 1)
                XCTAssertEqual(list.first?["pid"] as? Int32, SelfProcess.pid)
            }
        }
    }

    /// `control snapshot` returns the snapshot payload.
    func testControlSnapshot() throws {
        let pipeName = "infinitus-test-snapshot-\(UUID().uuidString)"
        try DaemonHarness.scratch { dir in
            try self.withServe(pipeName: pipeName, claudeDir: dir) { _ in
                let (lines, error, status) = try DaemonHarness.run(
                    ["control", "snapshot"],
                    environment: ["INFINITUS_CONTROL_PIPE": pipeName]
                )
                XCTAssertEqual(status, 0, error.joined(separator: "\n"))
                let joined = lines.joined(separator: "\n")
                guard let data = joined.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    XCTFail("could not parse snapshot JSON: \(joined)")
                    return
                }
                XCTAssertNotNil(json["machineName"])
                XCTAssertNotNil(json["fleets"])
            }
        }
    }

    /// `control message --pid N <text>` returns SessionInput.Reply shape.
    func testControlMessageUnknownPid() throws {
        let pipeName = "infinitus-test-msg-\(UUID().uuidString)"
        try DaemonHarness.scratch { dir in
            try self.withServe(pipeName: pipeName, claudeDir: dir) { _ in
                let (lines, error, status) = try DaemonHarness.run(
                    ["control", "message", "--pid", "999999", "hello test"],
                    environment: ["INFINITUS_CONTROL_PIPE": pipeName]
                )
                XCTAssertEqual(status, 0, error.joined(separator: "\n"))
                let joined = lines.joined(separator: "\n")
                guard let data = joined.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    XCTFail("could not parse reply JSON: \(joined)")
                    return
                }
                XCTAssertEqual(json["outcome"] as? String, "noChannel")
            }
        }
    }

    /// Unknown command returns error and non-zero exit code.
    func testControlUnknownCommand() throws {
        let (lines, error, status) = try DaemonHarness.run(["control", "boguscmd"])
        XCTAssertEqual(status, 2)
        XCTAssertTrue(error.joined().contains("unknown command 'boguscmd'"), lines.joined())
    }

    private func writeSyntheticSession(pid: Int32, to dir: URL) throws {
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var record: [String: Any] = [
            "pid": pid,
            "sessionId": "11111111-2222-3333-4444-555555555555",
            "cwd": "D:\\w\\synthetic",
            "kind": "interactive",
            "status": "idle",
            "name": "synthetic-test",
            "messagingSocketPath": "\\\\.\\pipe\\LOCAL\\cc-msg-test",
        ]
        if let procStart = SelfProcess.procStart {
            record["procStart"] = procStart
        }
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: sessions.appendingPathComponent("\(pid).json"))
    }
}

private struct XCTFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
