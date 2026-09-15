import XCTest
@testable import InfinitusCore

/// A read-only engine: declares nothing beyond snapshots.
private struct StubEngine: AccountEngine {
    let id = "stub"
    let displayName = "Stub"
    let capabilities: EngineCapabilities = []
    let fleets: [EngineFleet]
    func snapshot() async throws -> [EngineFleet] { fleets }
}

final class AccountEngineTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    func testDefaultActionsThrowUnsupported() async {
        let engine = StubEngine(fleets: [])
        do {
            try await engine.switchTo(fleet: .claude, number: 1)
            XCTFail("switch should be unsupported")
        } catch let e as EngineError {
            XCTAssertEqual(e, .unsupported("switch"))
        } catch { XCTFail("wrong error \(error)") }
        do {
            _ = try await engine.usageReport(days: 7)
            XCTFail("cost should be unsupported")
        } catch let e as EngineError {
            XCTAssertEqual(e, .unsupported("costReport"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testFleetRoundTripsThroughJSONWithRawBytes() throws {
        let raw = try fixture("list.json")
        let list = try JSONDecoder().decode(AccountList.self, from: raw)
        let fleet = EngineFleet(engineID: "swapd", provider: .claude, accounts: list.accounts,
                                activeNumber: list.activeAccountNumber, raw: raw)
        XCTAssertEqual(fleet.key, "swapd/claude")
        XCTAssertEqual(fleet.activeNumber, 5)
        let data = try JSONEncoder().encode([fleet])
        let back = try JSONDecoder().decode([EngineFleet].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].accounts.count, list.accounts.count)
        XCTAssertEqual(back[0].raw, raw)
        // The raw bytes still decode as the list payload the phone reads.
        let again = try JSONDecoder().decode(AccountList.self, from: back[0].raw!)
        XCTAssertEqual(again.activeAccountNumber, 5)
    }

    func testProviderOrderingIsClaudeFirst() {
        XCTAssertEqual(Provider.allCases.first, .claude)
        XCTAssertEqual(Provider.codex.displayName, "Codex")
    }

    // Cross-engine usage sharing: two engines holding one email used to
    // race, and the loser's pace-less copy rendered the row.
    func testRichestDonationPrefersPaceOverArrivalOrder() {
        let stamp = Date()
        let bare = SharedUsage(usage: Usage(sevenDay: UsageWindow(pct: 40)), at: stamp)
        let paced = SharedUsage(
            usage: Usage(sevenDay: UsageWindow(pct: 40, expectedPct: 25, aheadOfPace: true)),
            at: stamp)
        XCTAssertEqual(bare.richest(with: paced).usage.sevenDay?.expectedPct, 25)
        XCTAssertEqual(paced.richest(with: bare).usage.sevenDay?.expectedPct, 25)
    }

    func testRichestDonationBreaksTiesOnWindowCount() {
        let stamp = Date()
        let thin = SharedUsage(usage: Usage(sevenDay: UsageWindow(pct: 40)), at: stamp)
        let wide = SharedUsage(usage: Usage(fiveHour: UsageWindow(pct: 10),
                                            sevenDay: UsageWindow(pct: 40),
                                            scoped: [UsageWindow(pct: 5, name: "Opus")]),
                               at: stamp)
        XCTAssertEqual(thin.richest(with: wide).usage.scoped?.count, 1)
        XCTAssertEqual(wide.richest(with: thin).usage.scoped?.count, 1)
        // Equal readings keep the one already held, so the walk's order
        // decides only between equals.
        let other = SharedUsage(usage: Usage(sevenDay: UsageWindow(pct: 99)), at: stamp)
        XCTAssertEqual(thin.richest(with: other).usage.sevenDay?.pct, 40)
    }
}
