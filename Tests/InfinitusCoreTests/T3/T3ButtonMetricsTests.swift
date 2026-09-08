import XCTest
@testable import InfinitusCore

final class T3ButtonMetricsTests: XCTestCase {
    func testHeightsFollowTailwindClasses() {
        XCTAssertEqual(T3ButtonMetrics.height(.default), 32)   // h-8
        XCTAssertEqual(T3ButtonMetrics.height(.sm), 28)        // h-7
        XCTAssertEqual(T3ButtonMetrics.height(.icon), 32)
        XCTAssertEqual(T3ButtonMetrics.horizontalPadding(.default), 12)  // px-3
        XCTAssertEqual(T3ButtonMetrics.horizontalPadding(.sm), 10)       // px-2.5
        XCTAssertEqual(T3ButtonMetrics.horizontalPadding(.icon), 0)
    }
}
