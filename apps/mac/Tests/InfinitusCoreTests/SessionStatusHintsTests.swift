import XCTest
@testable import InfinitusCore

final class SessionStatusHintsTests: XCTestCase {
    private func record(status: String?, statusUpdatedAt: Date?) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/r", status: status, statusUpdatedAt: statusUpdatedAt)
    }

    func testAHintYieldsToANewerRecordAndToTime() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(1)
        let t2 = t1.addingTimeInterval(1)

        var hints = SessionStatusHints()
        hints.note(sessionId: "s1", .init(status: "idle", at: t1))

        let busy = record(status: "busy", statusUpdatedAt: t0)
        let applied = hints.apply([busy], now: t1)
        XCTAssertEqual(applied.first?.status, "idle")
        XCTAssertNotNil(hints.hints["s1"])

        let rewritten = record(status: "busy", statusUpdatedAt: t2)
        let afterRewrite = hints.apply([rewritten], now: t2)
        XCTAssertEqual(afterRewrite.first?.status, "busy")
        XCTAssertNil(hints.hints["s1"])

        var expiring = SessionStatusHints()
        expiring.note(sessionId: "s1", .init(status: "idle", at: t1))
        let stale = record(status: "busy", statusUpdatedAt: t0)
        let afterTtl = expiring.apply([stale], now: t1.addingTimeInterval(SessionStatusHints.ttl + 1))
        XCTAssertEqual(afterTtl.first?.status, "busy")
        XCTAssertNil(expiring.hints["s1"])
    }

    func testAGoneHintRemovesTheRowUntilTheRecordMovesOn() {
        let t0 = Date(timeIntervalSince1970: 2_000)
        let t1 = t0.addingTimeInterval(1)

        var hints = SessionStatusHints()
        hints.note(sessionId: "s1", .init(status: nil, at: t1))

        let busy = record(status: "busy", statusUpdatedAt: t0)
        XCTAssertTrue(hints.apply([busy], now: t1).isEmpty)

        let t2 = t1.addingTimeInterval(1)
        let movedOn = record(status: "busy", statusUpdatedAt: t2)
        let after = hints.apply([movedOn], now: t2)
        XCTAssertEqual(after.first?.status, "busy")
        XCTAssertNil(hints.hints["s1"])
    }

    func testAHintWithoutARecordWaitsThenExpires() {
        let t0 = Date(timeIntervalSince1970: 3_000)
        var hints = SessionStatusHints()
        hints.note(sessionId: "ghost", .init(status: "idle", at: t0))

        XCTAssertTrue(hints.apply([], now: t0.addingTimeInterval(1)).isEmpty)
        XCTAssertNotNil(hints.hints["ghost"])

        XCTAssertTrue(hints.apply([], now: t0.addingTimeInterval(SessionStatusHints.ttl + 1)).isEmpty)
        XCTAssertNil(hints.hints["ghost"])
    }
}
