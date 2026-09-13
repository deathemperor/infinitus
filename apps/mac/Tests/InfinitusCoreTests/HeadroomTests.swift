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

    func testInterruptModeSaysCriticalWhereHoldSaysLow() throws {
        // #743: same line, same hysteresis, a different holding state —
        // and a verdict held under the other mode re-reads in this one.
        let hot = try usage(#"{"fiveHour": {"pct": 81}}"#)
        let band = try usage(#"{"fiveHour": {"pct": 65}}"#)
        let cool = try usage(#"{"fiveHour": {"pct": 50}}"#)
        let v1 = Headroom.verdict(previous: nil, usage: hot, lowPct: low, abundantPct: abundant, interrupt: true)
        XCTAssertEqual(v1?.state, .critical)
        XCTAssertEqual(v1?.reason, "5h at 81%, interrupting from 80%")
        let v2 = Headroom.verdict(previous: v1, usage: band, lowPct: low, abundantPct: abundant, interrupt: true)
        XCTAssertEqual(v2?.state, .critical, "inside the band: still critical")
        let v3 = Headroom.verdict(previous: v2, usage: cool, lowPct: low, abundantPct: abundant, interrupt: true)
        XCTAssertEqual(v3?.state, .abundant)
        // Mode flipped mid-hold: the held verdict follows the new mode.
        let heldLow = Headroom(state: .low, window: "5h", pct: 65, reason: "")
        XCTAssertEqual(Headroom.verdict(previous: heldLow, usage: band, lowPct: low, abundantPct: abundant, interrupt: true)?.state, .critical)
        XCTAssertEqual(Headroom.verdict(previous: v2, usage: band, lowPct: low, abundantPct: abundant)?.state, .low)
        XCTAssertEqual(Headroom.verdict(previous: nil, usage: band, lowPct: low, abundantPct: abundant, interrupt: true)?.state, .abundant)
    }

    func testLowWinsWhenTheThresholdsCross() throws {
        // priority_abundant_pct ≥ priority_low_pct is not validated;
        // the hold threshold is checked first.
        let u = try usage(#"{"fiveHour": {"pct": 70}}"#)
        XCTAssertEqual(Headroom.verdict(previous: nil, usage: u, lowPct: 60, abundantPct: 90)?.state, .low)
    }

    func testFillBeforeResetHoldsBelowTheLine() throws {
        // #616 remainder 1: 55% is below `low`, but the pace projects the
        // window full in 20 minutes, before its reset — hold anyway.
        let u = try usage(#"{"fiveHour": {"pct": 55}}"#)
        let now = 1_000_000.0
        let fill = Headroom.Fill(window: "5h", at: now + 20 * 60)
        let v = Headroom.verdict(previous: nil, usage: u, lowPct: low, abundantPct: abundant,
                                  fill: fill, now: now)
        XCTAssertEqual(v?.state, .low)
        XCTAssertEqual(v?.window, "5h")
        XCTAssertEqual(v?.pct, 55)
        XCTAssertTrue(v?.reason.contains("fills in 20 min") == true, v?.reason ?? "")
    }

    func testFillNamesItsOwnWindow() throws {
        // The fullest window (7d at 70%) is not the one on pace to fill —
        // the verdict reports the fill's own window and pct, not the
        // fullest one's.
        let u = try usage(#"{"fiveHour": {"pct": 40}, "sevenDay": {"pct": 70}}"#)
        let now = 1_000_000.0
        let fill = Headroom.Fill(window: "5h", at: now + 15 * 60)
        let v = Headroom.verdict(previous: nil, usage: u, lowPct: low, abundantPct: abundant,
                                  fill: fill, now: now)
        XCTAssertEqual(v?.state, .low)
        XCTAssertEqual(v?.window, "5h")
        XCTAssertEqual(v?.pct, 40)
    }

    func testPctRuleWinsOverFill() throws {
        // Already at/above `lowPct`: the pct reason wins even though a
        // fill was also passed.
        let u = try usage(#"{"fiveHour": {"pct": 90}}"#)
        let now = 1_000_000.0
        let fill = Headroom.Fill(window: "5h", at: now + 5 * 60)
        let v = Headroom.verdict(previous: nil, usage: u, lowPct: low, abundantPct: abundant,
                                  fill: fill, now: now)
        XCTAssertEqual(v?.state, .low)
        XCTAssertEqual(v?.reason, "5h at 90%, holding from 80%")
    }

    func testInterruptModeFillSaysCritical() throws {
        let u = try usage(#"{"fiveHour": {"pct": 55}}"#)
        let now = 1_000_000.0
        let fill = Headroom.Fill(window: "5h", at: now + 10 * 60)
        let v = Headroom.verdict(previous: nil, usage: u, lowPct: low, abundantPct: abundant,
                                  interrupt: true, fill: fill, now: now)
        XCTAssertEqual(v?.state, .critical)
        XCTAssertTrue(v?.reason.contains("interrupting") == true, v?.reason ?? "")
    }

    func testFillGoneKeepsTheHeldVerdictInsideTheBand() throws {
        // The held verdict came from a fill; once the pace drops back
        // (fill nil) and pct sits in the band, the ordinary hysteresis
        // keeps it held until `abundantPct` — same as any other hold.
        let held = Headroom(state: .low, window: "5h", pct: 55,
                             reason: "5h at 55%, fills in 20 min before its reset — holding")
        let band = try usage(#"{"fiveHour": {"pct": 65}}"#)
        let v = Headroom.verdict(previous: held, usage: band, lowPct: low, abundantPct: abundant, fill: nil)
        XCTAssertEqual(v?.state, .low, "65% is inside the band: still low")
        let cool = try usage(#"{"fiveHour": {"pct": 45}}"#)
        let v2 = Headroom.verdict(previous: v, usage: cool, lowPct: low, abundantPct: abundant, fill: nil)
        XCTAssertEqual(v2?.state, .abundant, "at the release threshold")
    }

    func testNoFillIsExactlyV1() throws {
        // fill: nil (the default) must reproduce the pre-existing
        // behaviour exactly — one abundant case, one low case.
        let abundantUsage = try usage(#"{"fiveHour": {"pct": 65}, "sevenDay": {"pct": 20}}"#)
        XCTAssertEqual(
            Headroom.verdict(previous: nil, usage: abundantUsage, lowPct: low, abundantPct: abundant, fill: nil)?.state,
            .abundant)
        let lowUsage = try usage(#"{"fiveHour": {"pct": 12}, "sevenDay": {"pct": 41}, "scoped": [{"pct": 84, "name": "Fable"}]}"#)
        let v = Headroom.verdict(previous: nil, usage: lowUsage, lowPct: low, abundantPct: abundant, fill: nil)
        XCTAssertEqual(v?.state, .low)
        XCTAssertEqual(v?.window, "Fable")
        XCTAssertEqual(v?.pct, 84)
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
