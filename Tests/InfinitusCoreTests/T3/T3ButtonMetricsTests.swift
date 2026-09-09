import XCTest
@testable import InfinitusCore

final class T3ButtonMetricsTests: XCTestCase {
    func testHeightsFollowTailwindClasses() {
        XCTAssertEqual(T3ButtonMetrics.height(.default), 32)   // h-8
        XCTAssertEqual(T3ButtonMetrics.height(.sm), 28)        // h-7
        XCTAssertEqual(T3ButtonMetrics.height(.xs), 24)        // h-6
        XCTAssertEqual(T3ButtonMetrics.height(.icon), 32)
        // `px-[calc(--spacing(n)-1px)]`: the class's own arithmetic, since the
        // 1 px it removes is an outline neither CSS nor SwiftUI lays out.
        XCTAssertEqual(T3ButtonMetrics.horizontalPadding(.default), 11)
        XCTAssertEqual(T3ButtonMetrics.horizontalPadding(.sm), 9)
        XCTAssertEqual(T3ButtonMetrics.horizontalPadding(.xs), 7)
        XCTAssertEqual(T3ButtonMetrics.horizontalPadding(.icon), 0)
    }
}
