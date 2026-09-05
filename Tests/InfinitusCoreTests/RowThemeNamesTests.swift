import XCTest
@testable import InfinitusCore

final class RowThemeNamesTests: XCTestCase {
    /// Deterministic: a tiny LCG so picks are reproducible.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testEveryThemedBuiltinHasAPoolOfDistinctAliasSafeNames() {
        for theme in RowTheme.builtins where !theme.plain {
            XCTAssertGreaterThanOrEqual(theme.accountNames.count, 12, theme.id)
            XCTAssertEqual(Set(theme.accountNames).count, theme.accountNames.count, "\(theme.id) repeats a name")
            for name in theme.accountNames {
                XCTAssertTrue(RowTheme.isAliasSafe(name), "\(theme.id): \(name) is not alias-safe")
            }
        }
        XCTAssertTrue(RowTheme.off.accountNames.isEmpty)
    }

    func testPicksAreDistinctFromThePoolAndSuffixedPastIt() {
        var g = Seeded(state: 7)
        let five = RowTheme.rpg.randomAccountNames(count: 5, using: &g)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(Set(five).count, 5)
        XCTAssertTrue(five.allSatisfy { RowTheme.rpg.accountNames.contains($0) })
        var g2 = Seeded(state: 7)
        XCTAssertEqual(RowTheme.rpg.randomAccountNames(count: 5, using: &g2), five, "same seed, same picks")
        var g3 = Seeded(state: 1)
        let many = RowTheme.rpg.randomAccountNames(count: RowTheme.rpg.accountNames.count + 2, using: &g3)
        XCTAssertEqual(Set(many).count, many.count)
        XCTAssertTrue(many.suffix(2).allSatisfy { $0.hasSuffix("-2") })
    }

    func testASingleRerollSkipsTheNamesTheFleetWears() {
        let pool = RowTheme.rpg.accountNames
        var g = Seeded(state: 5)
        let free = pool.last!
        XCTAssertEqual(RowTheme.rpg.randomAccountNames(count: 1, avoiding: Set(pool.dropLast()), using: &g), [free])
        var g2 = Seeded(state: 5)
        let exhausted = RowTheme.rpg.randomAccountNames(count: 2, avoiding: Set(pool), using: &g2)
        XCTAssertEqual(exhausted.count, 2)
        XCTAssertTrue(exhausted.allSatisfy { $0.hasSuffix("-2") }, "\(exhausted)")
        XCTAssertTrue(Set(exhausted).isDisjoint(with: pool))
        var g3 = Seeded(state: 5)
        XCTAssertEqual(RowTheme.rpg.randomAccountNames(count: 2, avoiding: Set(pool), using: &g3), exhausted, "same seed, same picks")
    }

    func testAPoollessThemeDrawsFromEveryBuiltin() {
        var g = Seeded(state: 3)
        let names = RowTheme.off.randomAccountNames(count: 4, using: &g)
        let all = Set(RowTheme.builtins.flatMap(\.accountNames))
        XCTAssertEqual(names.count, 4)
        XCTAssertTrue(names.allSatisfy { all.contains($0) })
    }

    func testAliasSafety() {
        XCTAssertTrue(RowTheme.isAliasSafe("Gray-Fox"))
        XCTAssertTrue(RowTheme.isAliasSafe("v2.1_b"))
        XCTAssertFalse(RowTheme.isAliasSafe("42"))
        XCTAssertFalse(RowTheme.isAliasSafe("Big Boss"))
        XCTAssertFalse(RowTheme.isAliasSafe("Néon"))
        XCTAssertFalse(RowTheme.isAliasSafe(""))
    }
}
