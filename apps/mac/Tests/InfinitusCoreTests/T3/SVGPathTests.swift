import XCTest
@testable import InfinitusCore

final class SVGPathTests: XCTestCase {
    func testLucideArrowUp() {
        // lucide arrow-up: "m5 12 7-7 7 7" and "M12 19V5"
        XCTAssertEqual(SVGPath.parse("m5 12 7-7 7 7"), [.move(5, 12), .line(12, 5), .line(19, 12)])
        XCTAssertEqual(SVGPath.parse("M12 19V5"), [.move(12, 19), .line(12, 5)])
    }
    func testRelativeCubicAndClose() {
        XCTAssertEqual(SVGPath.parse("M1 1c1 0 1 1 2 1z"), [.move(1, 1), .cubic(2, 1, 2, 2, 3, 2), .close])
    }
    func testSmoothCurvesExpand() {
        // S reflects the previous cubic's second control point
        XCTAssertEqual(SVGPath.parse("M0 0C1 1 2 1 3 0S5 -1 6 0"),
                       [.move(0, 0), .cubic(1, 1, 2, 1, 3, 0), .cubic(4, -1, 5, -1, 6, 0)])
    }
    func testArcFlagsMayBePacked() {
        // lucide writes "a1 1 0 0 1 2 0": flags without spaces are legal too ("a1 1 0 012 0")
        XCTAssertEqual(SVGPath.parse("M0 0a1 1 0 012 0"), [.move(0, 0), .arc(rx: 1, ry: 1, rotation: 0, large: false, sweep: true, x: 2, y: 0)])
    }
}
