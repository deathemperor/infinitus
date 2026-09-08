import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// The thread screen derives its rows once per input, not per body pass (#380).
@MainActor final class T3ThreadMemoTests: XCTestCase {
    func testSameInputIsNotDerivedTwice() {
        let memo = T3ThreadMemo()
        let state = T3RenderHarness.conversation(running: true)
        memo.update(state: state, expandedTurnIds: [], expandedWorkGroupIds: [])
        let rows = memo.rows
        XCTAssertFalse(rows.isEmpty)
        memo.update(state: state, expandedTurnIds: [], expandedWorkGroupIds: [])
        memo.update(state: state, expandedTurnIds: [], expandedWorkGroupIds: [])
        XCTAssertEqual(memo.derivations, 1)
        XCTAssertEqual(memo.rows, rows)
    }

    func testExpansionAndTimelineChangesDeriveAgain() {
        let memo = T3ThreadMemo()
        let running = T3RenderHarness.conversation(running: true)
        memo.update(state: running, expandedTurnIds: [], expandedWorkGroupIds: [])
        memo.update(state: running, expandedTurnIds: ["t1"], expandedWorkGroupIds: [])
        XCTAssertEqual(memo.derivations, 2)
        // The follower's cursor moving without new content is not a change.
        var polled = running
        polled.sequence += 1
        polled.synchronized.toggle()
        memo.update(state: polled, expandedTurnIds: ["t1"], expandedWorkGroupIds: [])
        XCTAssertEqual(memo.derivations, 2)
        memo.update(state: T3RenderHarness.conversation(running: false), expandedTurnIds: ["t1"], expandedWorkGroupIds: [])
        XCTAssertEqual(memo.derivations, 3)
    }
}
