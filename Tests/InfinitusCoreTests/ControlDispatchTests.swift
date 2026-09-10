import XCTest
@testable import InfinitusCore

/// The Linux tray's control routing (#486 slice 3) — the socket itself is
/// Linux-only plumbing, this is every decision it makes.
final class ControlDispatchTests: XCTestCase {
    /// One recording handler set: what the tray would have done.
    private final class Recorder: @unchecked Sendable {
        var checkpoints: [(cwd: String, sessionId: String, subject: String)] = []
        var statusCalls = 0
        var handlers: ControlDispatch.Handlers {
            ControlDispatch.Handlers(
                checkpoint: { [self] cwd, sessionId, subject in
                    checkpoints.append((cwd, sessionId, subject))
                },
                status: { [self] in
                    statusCalls += 1
                    return .object(["platform": .string("linux"), "version": .string("dev"),
                                    "sessions": .number(2)])
                })
        }
    }

    func testUserPromptSubmitRecordsOneCheckpoint() {
        let recorder = Recorder()
        let payload = #"{"session_id":"s1","cwd":"/home/me/limitless","hook_event_name":"UserPromptSubmit","prompt":"Fix the crash"}"#
        let reply = ControlDispatch.reply(to: ControlRequest(command: "event", secret: payload),
                                          handlers: recorder.handlers)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.result?["pid"], .null, "the tray does not map a session id to a pid yet")
        XCTAssertEqual(recorder.checkpoints.count, 1)
        XCTAssertEqual(recorder.checkpoints.first?.cwd, "/home/me/limitless")
        XCTAssertEqual(recorder.checkpoints.first?.sessionId, "s1")
        XCTAssertEqual(recorder.checkpoints.first?.subject, "Fix the crash")
    }

    func testPromptWithoutCwdOrSessionIsAcceptedWithoutACheckpoint() {
        let recorder = Recorder()
        for payload in [#"{"cwd":"/r","hook_event_name":"UserPromptSubmit","prompt":"p"}"#,
                        #"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"p"}"#] {
            let reply = ControlDispatch.reply(to: ControlRequest(command: "event", secret: payload),
                                              handlers: recorder.handlers)
            XCTAssertTrue(reply.ok, payload)
        }
        XCTAssertTrue(recorder.checkpoints.isEmpty)
    }

    func testOtherHooksAreAcceptedAndIgnored() {
        let recorder = Recorder()
        for name in ["Stop", "Notification", "PreToolUse"] {
            let payload = #"{"session_id":"s1","cwd":"/r","hook_event_name":"\#(name)"}"#
            let reply = ControlDispatch.reply(to: ControlRequest(command: "event", secret: payload),
                                              handlers: recorder.handlers)
            XCTAssertTrue(reply.ok, "a hook must never see a failure it would retry: \(name)")
        }
        XCTAssertTrue(recorder.checkpoints.isEmpty)
    }

    func testEventWithoutAPayloadFails() {
        let recorder = Recorder()
        for request in [ControlRequest(command: "event"),
                        ControlRequest(command: "event", secret: "not json"),
                        ControlRequest(command: "event", secret: #"{"session_id":"s1"}"#)] {
            let reply = ControlDispatch.reply(to: request, handlers: recorder.handlers)
            XCTAssertFalse(reply.ok)
            XCTAssertEqual(reply.error,
                           "event: a Claude Code hook payload (JSON with hook_event_name) is expected on stdin")
        }
        XCTAssertTrue(recorder.checkpoints.isEmpty)
    }

    func testStatusAnswersTheHandlersReport() {
        let recorder = Recorder()
        let reply = ControlDispatch.reply(to: ControlRequest(command: "status"), handlers: recorder.handlers)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(recorder.statusCalls, 1)
        XCTAssertEqual(reply.result?["platform"], .string("linux"))
        XCTAssertEqual(reply.result?["sessions"], .number(2))
    }

    func testEverythingElseSaysNotOnLinuxYet() {
        let recorder = Recorder()
        for command in ["fleets", "switch", "approve", "team-status", "nonsense"] {
            let reply = ControlDispatch.reply(to: ControlRequest(command: command), handlers: recorder.handlers)
            XCTAssertFalse(reply.ok, command)
            XCTAssertEqual(reply.error, "\(command) is not available on Linux yet")
            XCTAssertNil(reply.result)
        }
    }

    func testALineRoundTripsAndBadBytesStillAnswer() throws {
        let recorder = Recorder()
        let line = try ControlCodec.encode(ControlRequest(command: "status"))
        let out = ControlDispatch.replyLine(to: line, handlers: recorder.handlers)
        XCTAssertEqual(out.last, 0x0A, "one line out, terminated")
        XCTAssertEqual(out.filter { $0 == 0x0A }.count, 1)
        let decoded = try ControlCodec.decode(ControlReply.self, from: out)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.schemaVersion, ControlProtocol.schemaVersion)

        let garbage = ControlDispatch.replyLine(to: Data("{ not a request".utf8), handlers: recorder.handlers)
        let failed = try ControlCodec.decode(ControlReply.self, from: garbage)
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.error, "control: expected one JSON ControlRequest line")
    }
}
