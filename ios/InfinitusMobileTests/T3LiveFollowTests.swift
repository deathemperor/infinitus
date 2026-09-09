import XCTest
@testable import InfinitusMobile

/// `resolveThreadFeedLiveFollow` (T3 `thread-feed-live-follow.ts`): the
/// latch that keeps a reader on history while rows stream in.
final class T3LiveFollowTests: XCTestCase {
    private func run(_ current: Bool, _ event: T3LiveFollow.Event) -> Bool { T3LiveFollow.resolve(current, event) }

    func testAResetOrReachingTheEndReArmsFollow() {
        XCTAssertTrue(run(false, .reset))
        XCTAssertTrue(run(false, .scroll(isAtEnd: true, sessionActive: false)))
        XCTAssertTrue(run(false, .userScrollEnd(isAtEnd: true, sessionActive: true)))
    }

    func testAUserScrollBreaksFollowAndAProgrammaticOneDoesNot() {
        XCTAssertFalse(run(true, .userScrollBegin))
        XCTAssertFalse(run(true, .scroll(isAtEnd: false, sessionActive: true)))
        XCTAssertFalse(run(true, .userScrollEnd(isAtEnd: false, sessionActive: true)))
        // Outside a user session a drift off the end keeps whatever held.
        XCTAssertTrue(run(true, .scroll(isAtEnd: false, sessionActive: false)))
        XCTAssertFalse(run(false, .scroll(isAtEnd: false, sessionActive: false)))
        XCTAssertTrue(run(true, .userScrollEnd(isAtEnd: false, sessionActive: false)))
    }

    func testAFoldSettlingFollowsOnlyWhenItLeftTheReaderAtTheEnd() {
        XCTAssertTrue(run(false, .disclosureSettled(isAtEnd: true, sessionActive: false)))
        XCTAssertFalse(run(true, .disclosureSettled(isAtEnd: false, sessionActive: false)))
        XCTAssertFalse(run(true, .disclosureSettled(isAtEnd: true, sessionActive: true)))
    }
}
