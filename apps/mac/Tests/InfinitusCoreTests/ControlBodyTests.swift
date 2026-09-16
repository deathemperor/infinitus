import XCTest
@testable import InfinitusCore

/// The `--body <json>` carrier (#572 N1): the verbs decode exactly what
/// their mirror routes decoded.
final class ControlBodyTests: XCTestCase {
    private func request(_ command: String, body: String?) -> ControlRequest {
        ControlRequest(command: command, args: [], options: body.map { ["body": $0] } ?? [:], secret: nil)
    }

    func testTheBodyVerbsAreWriteCommandsWithABodyOption() {
        for name in ["client-activity", "crash-report"] {
            let command = ControlCommand.named(name)
            XCTAssertEqual(command?.effect, .write, name)
            XCTAssertEqual(command?.options.first, "--body <json>", name)
        }
    }

    func testAClientReportDecodesItsScopes() throws {
        let body = #"{"clientId":"fork-1","visible":true,"focused":false,"recentlyInteracted":true,"scopes":[{"type":"sessions"},{"type":"session","pid":4242}],"ttlMs":30000}"#
        let r = try ControlBody.decode(ClientActivity.Report.self, from: request("client-activity", body: body))
        XCTAssertEqual(r.clientId, "fork-1")
        XCTAssertEqual(r.scopes, [.sessions, .session(4242)])
        XCTAssertEqual(r.ttlMs, 30000)
    }

    func testACrashReportDecodesAndIsCappedLikeTheRoute() throws {
        let body = #"{"id":"c1","platform":"ios","device":"iPhone","appVersion":"1.0","osVersion":"26.0","at":"2026-09-10T10:00:00Z","kind":"crash","reason":"SIGSEGV","frames":["a +1 b"]}"#
        let r = try ControlBody.decode(CrashReport.self, from: request("crash-report", body: body), cap: 2 * CrashReport.rawCap)
        XCTAssertEqual(r.id, "c1")
        XCTAssertEqual(r.frames, ["a +1 b"])
        let huge = String(repeating: "x", count: 2 * CrashReport.rawCap + 1)
        XCTAssertThrowsError(try ControlBody.decode(CrashReport.self, from: request("crash-report", body: huge), cap: 2 * CrashReport.rawCap)) {
            XCTAssertEqual(($0 as? ControlBody.Failure)?.message, "crash-report body is over \(2 * CrashReport.rawCap) bytes")
        }
    }

    func testAMissingOrBrokenBodyIsRefusedWithAMessage() {
        func message(_ command: String, _ body: String?) -> String? {
            do { _ = try ControlBody.decode(ClientActivity.Report.self, from: request(command, body: body)) } catch { return (error as? ControlBody.Failure)?.message }
            return nil
        }
        XCTAssertEqual(message("client-activity", nil), "client-activity needs --body <json> (or the JSON on stdin)")
        XCTAssertEqual(message("client-activity", ""), "client-activity needs --body <json> (or the JSON on stdin)")
        XCTAssertEqual(message("client-activity", "{nope"), "client-activity body: not JSON")
        XCTAssertEqual(message("client-activity", #"{"clientId":"x"}"#), "client-activity body: missing visible")
        XCTAssertEqual(message("client-activity", #"{"clientId":1,"visible":true,"focused":true,"recentlyInteracted":true,"scopes":[],"ttlMs":1}"#),
                       "client-activity body: clientId has the wrong type")
    }
}
