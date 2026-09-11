import XCTest
@testable import InfinitusCore

final class T3ThreadTests: XCTestCase {
    func testSessionStatusRoundTripsEverySessionFactsStatus() {
        for status in SessionFacts.Status.allCases {
            XCTAssertEqual(T3Thread.SessionStatus(status).rawValue, status.rawValue)
        }
    }

    func testTurnStateRoundTripsEverySessionTimelineTurnState() {
        for state in SessionTimeline.Turn.State.allCases {
            XCTAssertEqual(T3Thread.Turn.State(state).rawValue, state.rawValue)
        }
    }
}
