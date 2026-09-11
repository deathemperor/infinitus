import XCTest
@testable import InfinitusCore

final class EventFeedTests: XCTestCase {
    func testDecodesTheCapturedStream() throws {
        let url = Bundle.module.url(forResource: "Fixtures/events.ndjson", withExtension: nil)!
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n")
        let decoded = lines.map { EventFeed.decode(line: String($0)) }
        guard case .event(let poll) = decoded[0] else { return XCTFail("poll expected") }
        XCTAssertEqual(poll.kind, "poll")
        XCTAssertNotNil(poll.ts)
        guard case .event(let noSwitch) = decoded[1] else { return XCTFail() }
        XCTAssertEqual(noSwitch.kind, "no-switch")
        if case .string(let reason)? = noSwitch.raw["reason"] {
            XCTAssertEqual(reason, "below-threshold")
        } else { XCTFail("reason missing") }
    }

    func testUnknownKindIsStillAnEventNeverFatal() {
        let line = #"{"schemaVersion": 1, "event": "brand-new-kind", "ts": "2026-01-01T00:00:00Z"}"#
        guard case .event(let e) = EventFeed.decode(line: line) else { return XCTFail() }
        XCTAssertEqual(e.kind, "brand-new-kind")
    }

    func testSchemaMismatchIsSurfacedNotParsed() {
        let line = #"{"schemaVersion": 2, "event": "poll"}"#
        guard case .schemaMismatch(let v) = EventFeed.decode(line: line) else { return XCTFail() }
        XCTAssertEqual(v, 2)
    }

    func testAwayNotifiedSummaryNamesTheChannels() {
        let line = #"{"schemaVersion": 1, "event": "away-notified", "channels": ["slack", "telegram"]}"#
        guard case .event(let e) = EventFeed.decode(line: line) else { return XCTFail() }
        XCTAssertEqual(e.summary, "pushed switch notice to slack, telegram")
    }

    func testGarbageLineIsSkippedNotFatal() {
        guard case .garbage = EventFeed.decode(line: "not json at all") else { return XCTFail() }
        // A blank line is noise, not garbage worth logging.
        guard case .garbage = EventFeed.decode(line: "   ") else { return XCTFail() }
    }
}

final class SupervisorBackoffTests: XCTestCase {
    func testExponentialToACap() {
        var b = SupervisorBackoff()
        XCTAssertEqual(b.nextDelay(), 1)
        XCTAssertEqual(b.nextDelay(), 2)
        XCTAssertEqual(b.nextDelay(), 4)
        for _ in 0..<10 { _ = b.nextDelay() }
        XCTAssertEqual(b.nextDelay(), 60)
    }

    func testAFiveMinuteCleanRunResetsIt() {
        var b = SupervisorBackoff()
        _ = b.nextDelay(); _ = b.nextDelay(); _ = b.nextDelay()
        b.noteExit(afterCleanSeconds: 301)
        XCTAssertEqual(b.nextDelay(), 1)
    }

    func testAShortLivedChildKeepsEscalating() {
        var b = SupervisorBackoff()
        _ = b.nextDelay()
        b.noteExit(afterCleanSeconds: 3)
        XCTAssertEqual(b.nextDelay(), 2)
    }
}
