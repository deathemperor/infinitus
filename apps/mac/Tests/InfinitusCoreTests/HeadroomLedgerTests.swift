import XCTest
import InfinitusCore

final class HeadroomLedgerTests: XCTestCase {
    private let held = Headroom(state: .low, window: "5h", pct: 85, reason: "", since: 500)

    func testRoundTrip() throws {
        let data = HeadroomLedger.encode(fleetKey: "claude", email: "ada@example.com", headroom: held)
        XCTAssertNotNil(data)
        let seeded = HeadroomLedger.seed(data, fleetKey: "claude", email: "ada@example.com")
        XCTAssertEqual(seeded, held)
    }

    func testMismatchedEmailSeedsNothing() throws {
        let data = HeadroomLedger.encode(fleetKey: "claude", email: "ada@example.com", headroom: held)
        XCTAssertNil(HeadroomLedger.seed(data, fleetKey: "claude", email: "grace@example.com"))
        XCTAssertNil(HeadroomLedger.seed(data, fleetKey: "claude", email: nil))
    }

    func testMismatchedFleetKeySeedsNothing() throws {
        let data = HeadroomLedger.encode(fleetKey: "claude", email: "ada@example.com", headroom: held)
        XCTAssertNil(HeadroomLedger.seed(data, fleetKey: "codex", email: "ada@example.com"))
    }

    func testNilOrGarbageDataSeedsNothing() throws {
        XCTAssertNil(HeadroomLedger.seed(nil, fleetKey: "claude", email: "ada@example.com"))
        let garbage = Data("not json".utf8)
        XCTAssertNil(HeadroomLedger.seed(garbage, fleetKey: "claude", email: "ada@example.com"))
    }

    func testSeededVerdictHoldsInsideTheBandAcrossARelaunch() throws {
        // The relaunch case, end to end at the Core level: the fleet was
        // held `low` at 85% before the relaunch; the same account comes
        // back in the band at 65%. With the seed the hold survives;
        // without it the first judgement reads `previous: nil` and
        // releases for one poll.
        let previous = Headroom(state: .low, window: "5h", pct: 85, reason: "")
        let data = HeadroomLedger.encode(fleetKey: "claude", email: "ada@example.com", headroom: previous)
        let band = try JSONDecoder().decode(Usage.self, from: Data(#"{"fiveHour": {"pct": 65}}"#.utf8))

        let seeded = HeadroomLedger.seed(data, fleetKey: "claude", email: "ada@example.com")
        let withSeed = Headroom.verdict(previous: seeded, usage: band, lowPct: 80, abundantPct: 50)
        XCTAssertEqual(withSeed?.state, .low, "the seed carries the hold across the relaunch")

        let withoutSeed = Headroom.verdict(previous: nil, usage: band, lowPct: 80, abundantPct: 50)
        XCTAssertEqual(withoutSeed?.state, .abundant, "with no seed, a fresh launch reads the band as abundant")
    }
}
