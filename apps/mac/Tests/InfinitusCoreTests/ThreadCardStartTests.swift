import Foundation
import XCTest
@testable import InfinitusCore

/// #1277: one push-to-start per card; what changes before the phone
/// registers the card's token is held and sent once it does.
final class ThreadCardStartTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func state(_ n: Int) -> AgentActivityState {
        AgentActivityState(title: "\(n) working", subtitle: "s", activeCount: n, props: "{\"n\":\(n)}")
    }

    func testAStartOpensAHoldThatTakesLaterStatesUntilTheTokenReleasesThem() {
        let first = ThreadCardStart.plan(state: state(1), live: false, start: true, hold: nil, now: t0)
        XCTAssertEqual(first.action, .start)
        let hold = try! XCTUnwrap(first.hold)
        XCTAssertEqual(hold.pending, .none)
        // Two more states before the phone answers: the latest wins, nothing sent.
        let second = ThreadCardStart.plan(state: state(2), live: false, start: true, hold: hold, now: t0.addingTimeInterval(5))
        XCTAssertEqual(second.action, .held)
        let third = ThreadCardStart.plan(state: state(3), live: false, start: true, hold: second.hold, now: t0.addingTimeInterval(9))
        XCTAssertEqual(third.action, .held)
        XCTAssertEqual(third.hold?.pending, .update(state(3)))
        // The token registers: the held state goes out as an update.
        XCTAssertEqual(ThreadCardStart.release(third.hold!), .update)
        XCTAssertEqual(ThreadCardStart.release(hold), .none)
    }

    func testTheHoldLapsesWithTheStaleWindowAndAFreshStartIsAllowed() {
        let hold = ThreadCardStart.Hold(startedAt: t0)
        let within = ThreadCardStart.plan(state: state(2), live: false, start: true, hold: hold,
                                          now: t0.addingTimeInterval(LiveActivityPush.staleAfter))
        XCTAssertEqual(within.action, .held)
        let after = ThreadCardStart.plan(state: state(2), live: false, start: true, hold: hold,
                                         now: t0.addingTimeInterval(LiveActivityPush.staleAfter + 1))
        XCTAssertEqual(after.action, .start)
        XCTAssertEqual(after.hold?.startedAt, t0.addingTimeInterval(LiveActivityPush.staleAfter + 1))
    }

    func testAnEndWhileUnreportedIsHeldAndReleasedAsTheEnd() {
        let hold = ThreadCardStart.plan(state: state(1), live: false, start: true, hold: nil, now: t0).hold
        let ended = ThreadCardStart.plan(state: nil, live: false, start: true, hold: hold, now: t0.addingTimeInterval(3))
        XCTAssertEqual(ended.action, .held)
        XCTAssertEqual(ended.hold?.pending, .end)
        XCTAssertEqual(ThreadCardStart.release(ended.hold!), .end)
    }

    func testALiveTokenUpdatesInPlaceAndNoTokenSendsNothing() {
        XCTAssertEqual(ThreadCardStart.plan(state: state(1), live: true, start: true, hold: nil, now: t0).action, .update)
        XCTAssertEqual(ThreadCardStart.plan(state: nil, live: true, start: false, hold: nil, now: t0).action, .end)
        XCTAssertEqual(ThreadCardStart.plan(state: state(1), live: false, start: false, hold: nil, now: t0).action, .none)
        // An end with only a start token has no card to end and opens no hold.
        let end = ThreadCardStart.plan(state: nil, live: false, start: true, hold: nil, now: t0)
        XCTAssertEqual(end.action, .none)
        XCTAssertNil(end.hold)
    }
}
