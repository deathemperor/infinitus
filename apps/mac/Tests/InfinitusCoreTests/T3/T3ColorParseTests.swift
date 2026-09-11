import XCTest
@testable import InfinitusCore

final class T3ColorParseTests: XCTestCase {
    private func tokens() throws -> [String: [String: [Double]]] {
        let url = Bundle.module.url(forResource: "tokens.resolved", withExtension: "json", subdirectory: "Fixtures/t3")!
        return try JSONDecoder().decode([String: [String: [Double]]].self, from: Data(contentsOf: url))
    }
    func testMobileHexAndRgbaResolve() throws {
        let t = try tokens()
        XCTAssertEqual(t["mobileLight"]?["screen"], [242, 242, 247, 1])
        XCTAssertEqual(t["mobileLight"]?["border"], [0, 0, 0, 0.08])
        XCTAssertEqual(t["mobileDark"]?["userBubble"], [10, 132, 255, 1])
    }
    func testWebOklchAndColorMixResolve() throws {
        let t = try tokens()
        // --background: var(--color-zinc-25) = oklch(99.2% 0 0) → 252.31 per channel (CSS Color 4 matrices) → #fcfcfc
        XCTAssertEqual(t["webLight"]?["background"], [252, 252, 252, 1])
        // --primary: oklch(0.488 0.217 264) → (26.59, 78.32, 215.81) → #1b4ed8; ±1 for rounding
        let p = try XCTUnwrap(t["webLight"]?["primary"])
        XCTAssertEqual(p[0], 27, accuracy: 1); XCTAssertEqual(p[1], 78, accuracy: 1); XCTAssertEqual(p[2], 216, accuracy: 1)
        // dark --primary: oklch(0.571 0.21 264) → (52.12, 107.04, 240.96)
        let pd = try XCTUnwrap(t["webDark"]?["primary"])
        XCTAssertEqual(pd[0], 52, accuracy: 1); XCTAssertEqual(pd[1], 107, accuracy: 1); XCTAssertEqual(pd[2], 241, accuracy: 1)
        // light --accent: var(--color-zinc-100) = oklch(0.967 0.001 286.375) → #f4f4f5 (Tailwind's documented hex)
        XCTAssertEqual(t["webLight"]?["accent"], [244, 244, 245, 1])
        // dark --accent: --alpha(var(--color-white) / 4%)
        XCTAssertEqual(t["webDark"]?["accent"], [255, 255, 255, 0.04])
        // dark --background: var(--color-neutral-950) = oklch(14.5% 0 none) → #0a0a0a (Tailwind's documented hex)
        XCTAssertEqual(t["webDark"]?["background"], [10, 10, 10, 1])
        // dark --card: color-mix(in srgb, var(--background) 97%, var(--color-white)) = 0.97·10.04 + 0.03·255 = 17.39
        let c = try XCTUnwrap(t["webDark"]?["card"])
        XCTAssertEqual(c[0], 17, accuracy: 1); XCTAssertEqual(c[3], 1)
    }
    func testEveryPaletteHasTheSameKeys() throws {
        let t = try tokens()
        XCTAssertEqual(Set(t["mobileLight"]!.keys), Set(t["mobileDark"]!.keys))
        XCTAssertEqual(Set(t["webLight"]!.keys), Set(t["webDark"]!.keys))
        XCTAssertGreaterThan(t["mobileLight"]!.count, 60)
        XCTAssertGreaterThan(t["webLight"]!.count, 40)
    }
}
