import XCTest
@testable import InfinitusCore

/// The Linux tray's control routing (#486 slice 3) — the socket itself is
/// Linux-only plumbing, this is every decision it makes.
final class ControlDispatchTests: XCTestCase {
    /// One recording handler set: what the tray would have done.
    private final class Recorder: @unchecked Sendable {
        var statusCalls = 0
        var handlers: ControlDispatch.Handlers {
            ControlDispatch.Handlers(
                status: { [self] in
                    statusCalls += 1
                    return .object(["platform": .string("linux"), "version": .string("dev"),
                                    "sessions": .number(2)])
                })
        }
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
        for command in ["fleets", "switch", "approve", "perf", "nonsense"] {
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
