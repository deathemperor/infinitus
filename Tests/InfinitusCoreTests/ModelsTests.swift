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
        XCTAssertEqual(list.liveSessions?.busy, 4)
        XCTAssertEqual(list.liveSessions?.idle, 7)
        XCTAssertEqual(list.liveSessions?.unknown, 2)
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

    func testConfigListCarriesSpecMetadata() throws {
        let cfg = try JSONDecoder().decode(ConfigList.self, from: fixture("config.json"))
        let threshold = cfg.settings.first { $0.key == "autoswitch.threshold" }!
        XCTAssertEqual(threshold.kind, "float")
        XCTAssertEqual(threshold.lo, 50.0)
        XCTAssertEqual(threshold.hi, 99.9)
        XCTAssertFalse(threshold.help.isEmpty)
        let strategy = cfg.settings.first { $0.key == "autoswitch.strategy" }!
        XCTAssertTrue(strategy.choices?.contains("consume-first") ?? false)
        if case .string(let d) = strategy.defaultValue { XCTAssertEqual(d, "best") }
        else { XCTFail("default should be a string") }
    }

    func testHeterogeneousSettingValuesDecode() throws {
        let cfg = try JSONDecoder().decode(ConfigList.self, from: fixture("config.json"))
        let kinds = Set(cfg.settings.map(\.kind))
        XCTAssertTrue(kinds.contains("bool"))
        XCTAssertTrue(kinds.contains("float"))
        // Every value decoded into some JSONValue without throwing — the
        // point of the enum. Spot-check a bool round-trips as a bool.
        let resume = cfg.settings.first { $0.key == "autoswitch.resumeStoppedSessions" }!
        if case .bool = resume.value {} else { XCTFail("bool value expected") }
    }

    /// The owned status overlay (#151): the actor's word replaces the
    /// roster's empty one, the counts follow, everything else is untouched.
    func testLiveSessionsOverlayRewritesRowsAndCounts() {
        let live = LiveSessions(busy: 1, total: 3, idle: 0, waiting: 0, shell: 0, unknown: 2, sessions: [
            SessionDetail(pid: 1, cwd: "/a", status: "busy", kind: "interactive", startedAt: 0),
            SessionDetail(pid: 2, cwd: "/b", status: "unknown", kind: "interactive", startedAt: 0),
            SessionDetail(pid: 3, cwd: "/c", status: "unknown", kind: "interactive", startedAt: 0),
        ])
        let out = live.overlaying { pid in pid == 2 ? "waiting" : pid == 3 ? "idle" : nil }
        XCTAssertEqual(out.sessions?.map(\.status), ["busy", "waiting", "idle"])
        XCTAssertEqual([out.busy, out.idle, out.waiting, out.unknown, out.total], [1, 1, 1, 0, 3])
        XCTAssertEqual(live.overlaying { _ in nil }, live)
        XCTAssertEqual(LiveSessions(busy: 0, total: 0).overlaying { _ in "busy" }, LiveSessions(busy: 0, total: 0))
    }
}

final class ChillDepthTests: XCTestCase {
    func testSessionRowsTakeTheSessionIdByPidAndDecodeWithout() throws {
        let rows = LiveSessions(busy: 1, total: 2, sessions: [
            SessionDetail(pid: 1, cwd: "/a", status: "busy", kind: "interactive", startedAt: 0),
            SessionDetail(pid: 2, cwd: "/b", status: "idle", kind: "interactive", startedAt: 0),
        ])
        let tagged = rows.tagging(sessionIds: [1: "s-one", 9: "stranger"])
        XCTAssertEqual(tagged.sessions?.map(\.sessionId), ["s-one", nil])
        XCTAssertEqual(tagged.busy, 1)
        XCTAssertEqual(rows.tagging(sessionIds: [:]), rows)
        // An engine row (or an older Mac's snapshot) has no such key.
        let engineRow = try JSONDecoder().decode(
            SessionDetail.self, from: Data(#"{"pid":7,"cwd":"/c","status":"busy","kind":"interactive","startedAt":1}"#.utf8))
        XCTAssertNil(engineRow.sessionId)
        let wire = try JSONDecoder().decode(SessionDetail.self, from: try JSONEncoder().encode(tagged.sessions![0]))
        XCTAssertEqual(wire.sessionId, "s-one")
    }

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
        XCTAssertEqual(again.liveSessions?.busy, list.liveSessions?.busy)
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
