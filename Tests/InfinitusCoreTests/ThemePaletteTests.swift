import XCTest
@testable import InfinitusCore

final class ThemePaletteTests: XCTestCase {
    func testHexParses() {
        let parsedLower = ThemePalette.hex("#ff2d95")
        XCTAssertEqual(parsedLower, ThemePalette.RGB(r: 255, g: 45, b: 149))

        let parsedUpper = ThemePalette.hex("#FF2D95")
        XCTAssertEqual(parsedUpper, ThemePalette.RGB(r: 255, g: 45, b: 149))

        let black = ThemePalette.hex("#000000")
        XCTAssertEqual(black, ThemePalette.RGB(r: 0, g: 0, b: 0))

        let white = ThemePalette.hex("#ffffff")
        XCTAssertEqual(white, ThemePalette.RGB(r: 255, g: 255, b: 255))
    }

    func testHexRejectsMalformed() {
        XCTAssertNil(ThemePalette.hex("#fff"))
        XCTAssertNil(ThemePalette.hex("ff2d95"))
        XCTAssertNil(ThemePalette.hex("#gggggg"))
        XCTAssertNil(ThemePalette.hex(""))
        XCTAssertNil(ThemePalette.hex("#1234567"))
    }

    func testNamedColors() {
        XCTAssertEqual(ThemePalette.named("red"), ThemePalette.RGB(r: 255, g: 69, b: 58))
        XCTAssertEqual(ThemePalette.named("blue"), ThemePalette.RGB(r: 10, g: 132, b: 255))
        XCTAssertEqual(ThemePalette.named("green"), ThemePalette.RGB(r: 48, g: 209, b: 88))
        XCTAssertEqual(ThemePalette.named("yellow"), ThemePalette.RGB(r: 255, g: 214, b: 10))
        XCTAssertEqual(ThemePalette.named("orange"), ThemePalette.RGB(r: 255, g: 159, b: 10))
        XCTAssertEqual(ThemePalette.named("purple"), ThemePalette.RGB(r: 191, g: 90, b: 242))
        XCTAssertEqual(ThemePalette.named("indigo"), ThemePalette.RGB(r: 94, g: 92, b: 230))
        XCTAssertEqual(ThemePalette.named("cyan"), ThemePalette.RGB(r: 100, g: 210, b: 255))
        XCTAssertEqual(ThemePalette.named("teal"), ThemePalette.RGB(r: 64, g: 200, b: 224))
        XCTAssertEqual(ThemePalette.named("pink"), ThemePalette.RGB(r: 255, g: 55, b: 95))
        XCTAssertEqual(ThemePalette.named("mint"), ThemePalette.RGB(r: 102, g: 212, b: 207))
        XCTAssertEqual(ThemePalette.named("brown"), ThemePalette.RGB(r: 172, g: 142, b: 104))

        // System labels return nil
        XCTAssertNil(ThemePalette.named("secondary"))
        XCTAssertNil(ThemePalette.named("gray"))
        XCTAssertNil(ThemePalette.named("primary"))
    }

    func testEveryBuiltinThemeColourResolves() {
        let validSystemNames: Set<String> = ["secondary", "gray", "primary"]
        XCTAssertEqual(RowTheme.builtins.count, 15)

        for theme in RowTheme.builtins {
            let colorsToCheck = [
                theme.sessionColor,
                theme.weeklyColor,
                theme.scopedColor,
                theme.creditColor,
                theme.flashColor
            ]

            for c in colorsToCheck where !c.isEmpty {
                let resolves = ThemePalette.rgb(c) != nil || validSystemNames.contains(c.lowercased())
                XCTAssertTrue(resolves, "Theme '\(theme.id)' has unresolvable colour: '\(c)'")
            }
        }
    }
}
