#if !os(iOS)
import XCTest
@testable import InfinitusCore

/// The swapd adapter (#8, phase 1): `list --json` → neutral fleets.
/// The fixture IS swapd's own `contract.rs` snapshot of the spec §4
/// example, so a contract change breaks this test before it reaches a row.
final class SwapdMappingTests: XCTestCase {
    /// 01:00 UTC on the fixture's day — countdowns are then exact numbers
    /// instead of "whenever the suite ran".
    let now = WeeklyRoll.parse("2026-09-09T01:00:00Z")!

    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    func list(_ json: String) throws -> SwapdList {
        try JSONDecoder().decode(SwapdList.self, from: Data(json.utf8))
    }

    func testContractFixtureMapsToOneClaudeFleet() throws {
        let list = try JSONDecoder().decode(SwapdList.self, from: fixture("swapd-list.json"))
        XCTAssertEqual(list.schemaVersion, 1)
        let fleets = SwapdMapping.fleets(from: list, now: now)
        XCTAssertEqual(fleets.count, 1)
        let fleet = fleets[0]
        XCTAssertEqual(fleet.key, "swapd/claude")
        XCTAssertEqual(fleet.activeNumber, 2)
        XCTAssertEqual(fleet.nextCandidate, 1)
        XCTAssertEqual(fleet.nextRecovery, NextRecovery(number: 8, at: "2026-09-09T03:29:59Z"))
        // The engine's list is not `AccountList` bytes and knows nothing
        // about this Mac's sessions.
        XCTAssertNil(fleet.raw)
        XCTAssertNil(fleet.liveSessions)

        let account = fleet.accounts[0]
        XCTAssertEqual(account.number, 1, "slot is the app's number")
        XCTAssertEqual(account.email, "you@example.com")
        XCTAssertEqual(account.organizationName, "Example Org")
        XCTAssertEqual(account.alias, "death2")
        XCTAssertEqual(account.icon, "🩸")
        XCTAssertEqual(account.plan, "Max 20x")
        XCTAssertEqual(account.usageStatus, "ok")
        XCTAssertEqual(account.disabled, false)
        XCTAssertEqual(account.preferred, false)
        XCTAssertEqual(account.usageFetchedAt, "2026-09-09T01:11:03Z")
        XCTAssertEqual(account.usageAgeSeconds, 7.6)

        XCTAssertEqual(account.usage?.fiveHour?.pct, 0)
        XCTAssertEqual(account.usage?.fiveHour?.resetsAt, "2026-09-09T05:59:59Z")
        // Countdown/clock are NOT in the contract — the app formats them.
        XCTAssertEqual(account.usage?.fiveHour?.countdown, "4h 59m")
        XCTAssertNotNil(account.usage?.fiveHour?.clock)
        XCTAssertNil(account.usage?.fiveHour?.name, "name rides scoped windows only")
        XCTAssertEqual(account.usage?.sevenDay?.pct, 19)
        XCTAssertEqual(account.usage?.sevenDay?.expectedPct, 20.3)
        XCTAssertEqual(account.usage?.sevenDay?.aheadOfPace, true)
        XCTAssertEqual(account.usage?.sevenDay?.willLastToReset, true)
        XCTAssertNil(account.usage?.sevenDay?.projectedExhaustionAt, "absent, not null")
        XCTAssertEqual(account.usage?.scoped?.map(\.name), ["Fable"])
        XCTAssertEqual(account.usage?.scoped?.first?.pct, 29)
        // `lastGood` with no windows is a fetch that carried nothing.
        XCTAssertEqual(account.lastGoodFetchedAt, "2026-09-09T01:11:03Z")
        XCTAssertNil(account.lastGoodUsage)
    }

    /// The payload a fresh install prints (probed against the real binary):
    /// absent optionals, no accounts, and nothing to render.
    func testInstalledProviderWithNoAccountsYieldsNoFleet() throws {
        let list = try list(#"{"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[]}]}"#)
        XCTAssertNil(list.providers[0].activeSlot)
        XCTAssertTrue(SwapdMapping.fleets(from: list, now: now).isEmpty)
    }

    func testUnknownProviderLandsInOtherOnlyOnce() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[
          {"provider":"grok","installed":true,"accounts":[\(Self.account(slot: 1))]},
          {"provider":"mystery","installed":true,"accounts":[\(Self.account(slot: 1))]},
          {"provider":"codex","installed":true,"accounts":[\(Self.account(slot: 1))]}]}
        """)
        // One state per (engine, provider) key: a second `.other` would
        // collide on "swapd/other", so the first one wins.
        XCTAssertEqual(SwapdMapping.fleets(from: list, now: now).map(\.provider), [.other, .codex])
    }

    func testStaleServesItsWindowsAsTheLastGoodFetch() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[
          {"slot":1,"email":"a@b.c","organizationName":"","organizationUuid":"","active":true,
           "disabled":false,"preferred":false,"usageStatus":"stale",
           "fetchedAt":"2026-09-09T00:00:00Z","ageSeconds":900,
           "windows":[{"kind":"5h","pct":41,"resetsAt":"2026-09-09T05:59:59Z"}]}]}]}
        """)
        let account = SwapdMapping.fleets(from: list, now: now)[0].accounts[0]
        // "stale" is not a sentinel: the row shows usage, not a note.
        XCTAssertEqual(account.usageStatus, "ok")
        XCTAssertNil(SentinelNotes.note(for: account.usageStatus))
        XCTAssertEqual(account.usage?.fiveHour?.pct, 41)
        XCTAssertEqual(account.lastGoodUsage?.fiveHour?.pct, 41)
        XCTAssertEqual(account.lastGoodFetchedAt, "2026-09-09T00:00:00Z")
        XCTAssertEqual(account.lastGoodAgeSeconds, 900)
    }

    func testSentinelStatusesTakeCswapsSpelling() {
        XCTAssertEqual(SwapdMapping.usageStatus("relogin-required"), "relogin_required")
        XCTAssertEqual(SwapdMapping.usageStatus("token-expired"), "token_expired")
        XCTAssertEqual(SwapdMapping.usageStatus("no-credentials"), "no_credentials")
        XCTAssertEqual(SwapdMapping.usageStatus("api-key"), "api_key")
        // …because every surface renders the note keyed on that spelling.
        XCTAssertEqual(SentinelNotes.short(for: SwapdMapping.usageStatus("relogin-required")),
                       "re-login needed")
        XCTAssertNotNil(SentinelNotes.note(for: SwapdMapping.usageStatus("api-key")))
        // A status this build predates still reads as a note, never a crash.
        XCTAssertEqual(SwapdMapping.usageStatus("unsupported"), "unsupported")
    }

    func testSpendNeedsItsMoneyAndUnknownKindsBecomeNamedGauges() throws {
        let list = try list("""
        {"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"accounts":[
          {"slot":1,"email":"a@b.c","organizationName":"","organizationUuid":"","active":true,
           "disabled":false,"preferred":false,"usageStatus":"ok","windows":[
             {"kind":"spend","pct":25,"used":5,"limit":20,"currency":"USD","resetsAt":"2026-10-01T00:00:00Z"},
             {"kind":"monthly","pct":12},
             {"kind":"daily","pct":3}]},
          {"slot":2,"email":"d@b.c","organizationName":"","organizationUuid":"","active":false,
           "disabled":false,"preferred":false,"usageStatus":"ok","windows":[
             {"kind":"spend","pct":25,"used":5}]}]}]}
        """)
        let accounts = SwapdMapping.fleets(from: list, now: now)[0].accounts
        XCTAssertEqual(accounts[0].usage?.spend?.used, 5)
        XCTAssertEqual(accounts[0].usage?.spend?.limit, 20)
        XCTAssertEqual(accounts[0].usage?.spend?.currency, "USD")
        // daily/monthly have no home of their own: shown, never dropped.
        XCTAssertEqual(accounts[0].usage?.scoped?.map(\.name), ["monthly", "daily"])
        // A spend pool with no limit or currency renders nothing.
        XCTAssertNil(accounts[1].usage?.spend)
        XCTAssertNil(accounts[1].usage, "no window left to show")
    }

    static func account(slot: Int) -> String {
        """
        {"slot":\(slot),"email":"a\(slot)@b.c","organizationName":"","organizationUuid":"",
         "active":true,"disabled":false,"preferred":false,"usageStatus":"ok","windows":[]}
        """
    }
}
#endif
