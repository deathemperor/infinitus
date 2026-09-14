import XCTest
import InfinitusCore

final class ConnectionTestTests: XCTestCase {
    func testAReachedReplyCarriesLatencyAndNoError() {
        let fields = ConnectionTest.Reply.reached(latencyMs: 42).fields
        XCTAssertEqual(fields, ["ok": .bool(true), "latencyMs": .number(42)])
    }

    func testAFailedReplyCarriesTheWordsOnly() {
        let fields = ConnectionTest.Reply.failed("The engine refused the key.").fields
        XCTAssertEqual(fields, ["ok": .bool(false), "error": .string("The engine refused the key.")])
    }

    func testTheDeadlineWinsOverAProbeThatNeverAnswers() async {
        do {
            _ = try await ConnectionTest.withDeadline(seconds: 0.05) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is ConnectionTest.TimedOut)
        }
    }

    func testAPromptAnswerBeatsTheDeadline() async throws {
        let value = try await ConnectionTest.withDeadline(seconds: 1) { 7 }
        XCTAssertEqual(value, 7)
    }
}
