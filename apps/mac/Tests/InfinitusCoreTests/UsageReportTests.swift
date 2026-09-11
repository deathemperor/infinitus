import XCTest
@testable import InfinitusCore

final class UsageReportTests: XCTestCase {
    func testDecodesReport() throws {
        let json = """
        {"schemaVersion":1,"days":7,"estimatedTotalUSD":75.5,
         "priceTable":{"source":"models.dev","date":"2026-08-28"},
         "accounts":[{"number":1,"email":"a@x.io","alias":"dev",
           "estimatedUSD":75.5,"messages":10,"input":5,"output":6,
           "cacheRead":7,"cacheWrite":8,
           "models":[{"model":"claude-opus-5","estimatedUSD":75.5,"messages":10}]}],
         "caveats":["NOT billing truth."]}
        """
        let r = try JSONDecoder().decode(UsageReport.self, from: Data(json.utf8))
        XCTAssertEqual(r.estimatedTotalUSD, 75.5)
        XCTAssertEqual(r.accounts.first?.alias, "dev")
        XCTAssertNil(r.unattributed)   // optional buckets absent when empty
        XCTAssertNil(r.unpricedTokens)
        XCTAssertEqual(r.accounts.first?.models.first?.model, "claude-opus-5")
    }

    func testCompactTokenFormat() {
        XCTAssertEqual(TokenFormat.compact(950), "950")
        XCTAssertEqual(TokenFormat.compact(12_300), "12.3k")
        XCTAssertEqual(TokenFormat.compact(4_500_000), "4.5M")
        XCTAssertEqual(TokenFormat.compact(1_200_000_000), "1.2B")
    }
}

final class GaugeMathTests: XCTestCase {
    func testFilledCells() {
        XCTAssertEqual(GaugeMath.filled(0), 0)
        XCTAssertEqual(GaugeMath.filled(100), 8)
        XCTAssertEqual(GaugeMath.filled(50), 4)
        XCTAssertEqual(GaugeMath.filled(6), 0)     // rounds to nearest cell
        XCTAssertEqual(GaugeMath.filled(7), 1)
        XCTAssertEqual(GaugeMath.filled(150), 8)   // clamped
        XCTAssertEqual(GaugeMath.filled(-5), 0)
    }

    func testRemainingIsHPSemantics() {
        XCTAssertEqual(GaugeMath.remaining(usedPct: 30), 70)
        XCTAssertEqual(GaugeMath.remaining(usedPct: 120), 0)  // over-limit floors
        XCTAssertEqual(GaugeMath.remaining(usedPct: -1), 100)
    }

    func testBurnHeatScalesWithLead() {
        XCTAssertEqual(GaugeMath.burnHeat(usedPct: 40, expectedPct: 40, ahead: true), 0)
        XCTAssertEqual(GaugeMath.burnHeat(usedPct: 55, expectedPct: 40, ahead: true), 0.5)
        XCTAssertEqual(GaugeMath.burnHeat(usedPct: 90, expectedPct: 40, ahead: true), 1)  // caps at +30
    }

    func testBurnHeatGates() {
        // Behind pace: expectedPct present but ahead is false/nil — no fire.
        XCTAssertEqual(GaugeMath.burnHeat(usedPct: 64, expectedPct: 39, ahead: false), 0)
        XCTAssertEqual(GaugeMath.burnHeat(usedPct: 64, expectedPct: 39, ahead: nil), 0)
        XCTAssertEqual(GaugeMath.burnHeat(usedPct: 64, expectedPct: nil, ahead: true), 0)
    }
}
