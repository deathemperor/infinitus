import XCTest
@testable import InfinitusCore

/// Decoding is tested against fixtures captured from the real CLI
/// (sanitized: emails and org UUIDs replaced), so the Swift models can only
/// drift from `cswap --json` by failing here first.
final class ModelsTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    func testAccountListDecodesTheRealPayload() throws {
        let list = try JSONDecoder().decode(AccountList.self, from: fixture("list.json"))
        XCTAssertEqual(list.schemaVersion, 1)
        XCTAssertEqual(list.accounts.count, 5)
        XCTAssertEqual(list.activeAccountNumber, 5)
        let first = list.accounts[0]
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.usageStatus, "ok")
        XCTAssertEqual(first.usage?.sevenDay?.pct, 100.0)
        XCTAssertEqual(first.usage?.scoped?.first?.name, "Fable")
        XCTAssertNotNil(first.usage?.sevenDay?.countdown)
    }

    func testNextRecoveryDecodesAndIsOptional() throws {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": 3, "accounts": [],
         "nextRecovery": {"number": 2, "at": "2026-08-30T09:00:00+00:00"}}
        """
        let list = try JSONDecoder().decode(AccountList.self, from: Data(json.utf8))
        XCTAssertNil(list.nextCandidate)
        XCTAssertEqual(list.nextRecovery?.number, 2)
        XCTAssertEqual(list.nextRecovery?.at, "2026-08-30T09:00:00+00:00")
        // Older engines omit the key entirely.
        let bare = """
        {"schemaVersion": 1, "activeAccountNumber": null, "accounts": []}
        """
        XCTAssertNil(try JSONDecoder()
            .decode(AccountList.self, from: Data(bare.utf8)).nextRecovery)
    }

    func testSentinelAccountHasNilUsageNotADecodeError() throws {
        let json = """
        {"schemaVersion": 1, "activeAccountNumber": null, "accounts": [
          {"number": 2, "email": "x@example.com", "organizationName": "",
           "organizationUuid": "", "isOrganization": false, "active": false,
           "usageStatus": "no_credentials", "usage": null}]}
        """
        let list = try JSONDecoder().decode(AccountList.self, from: Data(json.utf8))
        XCTAssertNil(list.accounts[0].usage)
        XCTAssertNil(list.activeAccountNumber)
        XCTAssertEqual(list.accounts[0].usageStatus, "no_credentials")
    }
}

final class ChillDepthTests: XCTestCase {
    func testBehindPaceScales() {
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 22, expectedPct: 31, ahead: false),
                       0.3, accuracy: 0.001)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 0, expectedPct: 40, ahead: false), 1)
    }

    func testZeroUnlessExplicitlyNotAhead() {
        // nil ahead means the engine sent no pace verdict — no effect,
        // symmetric with burnHeat's `ahead == true` guard.
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 10, expectedPct: 40, ahead: nil), 0)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 10, expectedPct: 40, ahead: true), 0)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 10, expectedPct: nil, ahead: false), 0)
        XCTAssertEqual(GaugeMath.chillDepth(usedPct: 50, expectedPct: 40, ahead: false), 0)
    }
}

/// Multi-engine seam (#8): engines that aren't cswap build these models
/// directly and the app caches them re-encoded, so they must round-trip.
final class ModelsCodableTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }

    func testAccountListRoundTripsThroughJSON() throws {
        let list = try JSONDecoder().decode(AccountList.self, from: fixture("list.json"))
        let again = try JSONDecoder().decode(
            AccountList.self, from: JSONEncoder().encode(list))
        XCTAssertEqual(again.accounts.count, list.accounts.count)
        XCTAssertEqual(again.activeAccountNumber, list.activeAccountNumber)
        let a = list.accounts[0], b = again.accounts[0]
        XCTAssertEqual(a.email, b.email)
        XCTAssertEqual(a.usage?.sevenDay?.pct, b.usage?.sevenDay?.pct)
        XCTAssertEqual(a.usage?.sevenDay?.resetsAt, b.usage?.sevenDay?.resetsAt)
        XCTAssertEqual(a.usage?.scoped?.first?.name, b.usage?.scoped?.first?.name)
        XCTAssertEqual(a.usage?.sevenDay?.aheadOfPace, b.usage?.sevenDay?.aheadOfPace)
    }

    func testMemberwiseInitNeedsOnlyIdentity() {
        let account = Account(number: 3, email: "x@example.com",
                              usage: Usage(fiveHour: UsageWindow(pct: 12)))
        XCTAssertEqual(account.usageStatus, "ok")
        XCTAssertNil(account.disabled)
        XCTAssertEqual(account.usage?.fiveHour?.pct, 12)
        let list = AccountList(activeAccountNumber: 3, accounts: [account])
        XCTAssertEqual(list.schemaVersion, 1)
    }
}
