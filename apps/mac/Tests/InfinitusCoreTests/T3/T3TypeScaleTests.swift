import XCTest
@testable import InfinitusCore

final class T3TypeScaleTests: XCTestCase {
    func testMobileScaleMatchesGlobalCss() {
        // apps/mobile/global.css @theme (--text-*: size / line-height)
        let expect: [(T3TypeScale.Mobile, Double, Double)] = [
            (.xxxs, 11, 14), (.xxs, 12, 16), (.xs, 13, 17), (.sm, 14, 19), (.base, 16, 23),
            (.lg, 18, 23), (.xl, 21, 28), (.xxl, 26, 32), (.xxxl, 30, 36)]
        for (k, s, lh) in expect { XCTAssertEqual(k.step, .init(size: s, lineHeight: lh), "\(k)") }
        XCTAssertEqual(T3TypeScale.Mobile.allCases.count, 9)
    }
    func testWebScaleIsTailwindV4() {
        let expect: [(T3TypeScale.Web, Double, Double)] = [
            (.xs, 12, 16), (.sm, 14, 20), (.base, 16, 24), (.lg, 18, 28), (.xl, 20, 28), (.xxl, 24, 32)]
        for (k, s, lh) in expect { XCTAssertEqual(k.step, .init(size: s, lineHeight: lh), "\(k)") }
    }
    func testLineSpacingIsTheGap() {
        XCTAssertEqual(T3TypeScale.lineSpacing(T3TypeScale.Mobile.base.step), 7)
        XCTAssertEqual(T3TypeScale.lineSpacing(T3TypeScale.Web.sm.step), 6)
    }
}
