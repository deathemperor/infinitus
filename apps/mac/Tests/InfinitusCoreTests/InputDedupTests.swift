import XCTest
@testable import InfinitusCore

final class InputDedupTests: XCTestCase {
    func testReplayIsNilBeforeRemember() {
        let dedup = InputDedup()
        XCTAssertNil(dedup.replay(pid: 7, requestId: "a"))
    }

    func testReplayReturnsTheRememberedReply() {
        var dedup = InputDedup()
        let reply = SessionInput.Reply(outcome: "delivered", detail: nil)
        dedup.remember(pid: 7, requestId: "a", reply: reply)
        XCTAssertEqual(dedup.replay(pid: 7, requestId: "a"), reply)
    }

    func testPidsAreIsolated() {
        var dedup = InputDedup()
        dedup.remember(pid: 7, requestId: "a", reply: SessionInput.Reply(outcome: "delivered", detail: nil))
        XCTAssertNil(dedup.replay(pid: 8, requestId: "a"))
    }

    func testRingEvictsTheOldest() {
        var dedup = InputDedup(capacity: 3)
        for id in ["a", "b", "c"] {
            dedup.remember(pid: 1, requestId: id, reply: SessionInput.Reply(outcome: id, detail: nil))
        }
        dedup.remember(pid: 1, requestId: "d", reply: SessionInput.Reply(outcome: "d", detail: nil))   // evicts "a"
        XCTAssertNil(dedup.replay(pid: 1, requestId: "a"))
        XCTAssertEqual(dedup.replay(pid: 1, requestId: "d"), SessionInput.Reply(outcome: "d", detail: nil))
    }
}
