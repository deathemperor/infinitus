import XCTest
import InfinitusCore

private func usage(_ json: String) throws -> Usage {
    try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
}

final class HeadroomTests: XCTestCase {
    private let low = 80.0, abundant = 50.0

    func testNoUsageKeepsThePreviousVerdict() throws {
        // #159: a refresh with no usage for the active account says
        // nothing — the held sessions must not be released for one poll.
        let held = Headroom(state: .low, window: "5h", pct: 85, reason: "")
        XCTAssertEqual(Headroom.verdict(previous: held, usage: nil, lowPct: low, abundantPct: abundant), held)
        XCTAssertNil(Headroom.verdict(previous: nil, usage: nil, lowPct: low, abundantPct: abundant))
        XCTAssertEqual(Headroom.verdict(previous: held, usage: try usage("{}"), lowPct: low, abundantPct: abundant), held)
    }

    func testFullestWindowBinds() throws {
        let u = try usage(#"{"fiveHour": {"pct": 12}, "sevenDay": {"pct": 41}, "scoped": [{"pct": 84, "name": "Fable"}]}"#)
        let v = Headroom.verdict(previous: nil, usage: u, lowPct: low, abundantPct: abundant)
        XCTAssertEqual(v?.state, .low)
        XCTAssertEqual(v?.window, "Fable")
        XCTAssertEqual(v?.pct, 84)
    }

    func testFirstVerdictInsideTheBandIsAbundant() throws {
        let u = try usage(#"{"fiveHour": {"pct": 65}, "sevenDay": {"pct": 20}}"#)
        let v = Headroom.verdict(previous: nil, usage: u, lowPct: low, abundantPct: abundant)
        XCTAssertEqual(v?.state, .abundant)
        XCTAssertEqual(v?.window, "5h")
    }

    func testHysteresisHoldsInsideTheBand() throws {
        let hot = try usage(#"{"fiveHour": {"pct": 81}}"#)
        let band = try usage(#"{"fiveHour": {"pct": 65}}"#)
        let cool = try usage(#"{"fiveHour": {"pct": 50}}"#)
        let v1 = Headroom.verdict(previous: nil, usage: hot, lowPct: low, abundantPct: abundant)
        XCTAssertEqual(v1?.state, .low)
        let v2 = Headroom.verdict(previous: v1, usage: band, lowPct: low, abundantPct: abundant)
        XCTAssertEqual(v2?.state, .low, "65% is inside the band: still low")
        XCTAssertEqual(v2?.pct, 65)
        let v3 = Headroom.verdict(previous: v2, usage: cool, lowPct: low, abundantPct: abundant)
        XCTAssertEqual(v3?.state, .abundant, "at the release threshold")
        let v4 = Headroom.verdict(previous: v3, usage: band, lowPct: low, abundantPct: abundant)
        XCTAssertEqual(v4?.state, .abundant, "inside the band on the way up: still abundant")
    }

    func testSwapStartsOver() throws {
        // The caller passes nil after an account swap: the new account at
        // 60% is abundant, whatever the old one was.
        let band = try usage(#"{"fiveHour": {"pct": 60}}"#)
        let held = Headroom(state: .low, window: "5h", pct: 85, reason: "")
        XCTAssertEqual(Headroom.verdict(previous: nil, usage: band, lowPct: low, abundantPct: abundant)?.state, .abundant)
        XCTAssertEqual(Headroom.verdict(previous: held, usage: band, lowPct: low, abundantPct: abundant)?.state, .low)
    }

    func testLowWinsWhenTheThresholdsCross() throws {
        // priority_abundant_pct ≥ priority_low_pct is not validated;
        // the hold threshold is checked first.
        let u = try usage(#"{"fiveHour": {"pct": 70}}"#)
        XCTAssertEqual(Headroom.verdict(previous: nil, usage: u, lowPct: 60, abundantPct: 90)?.state, .low)
    }

    func testWireShape() throws {
        let v = Headroom(state: .low, window: "7d", pct: 84, reason: "7d at 84%, holding from 80%")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any]
        XCTAssertEqual(json?["state"] as? String, "low")
        XCTAssertEqual(json?["window"] as? String, "7d")
        XCTAssertEqual(json?["pct"] as? Double, 84)
        XCTAssertNotNil(json?["reason"])
    }
}
