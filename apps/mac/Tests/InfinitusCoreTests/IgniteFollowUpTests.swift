import XCTest
@testable import InfinitusCore

/// The ignite follow-up (#338): a bounded, growing schedule and the three
/// things the plan line can say while it runs.
final class IgniteFollowUpTests: XCTestCase {
    func testScheduleIsBoundedAndGrows() {
        let d = IgniteFollowUp.delays
        XCTAssertEqual(d, d.sorted())
        XCTAssertEqual(d.reduce(0, +), 765)
        XCTAssertEqual(IgniteFollowUp.unseen("death3"), "ignited death3, but its clock has not shown after 12 min")
    }

    func testTexts() {
        XCTAssertEqual(IgniteFollowUp.waiting("death3"), "death3's window started — waiting for its clock to show")
        XCTAssertTrue(IgniteFollowUp.started("death3", resets: Date()).hasPrefix("death3's window started — resets "))
    }
}
