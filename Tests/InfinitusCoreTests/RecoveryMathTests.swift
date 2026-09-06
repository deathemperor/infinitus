import XCTest
import InfinitusCore

private func account(_ json: String) throws -> Account {
    try JSONDecoder().decode(Account.self, from: Data(json.utf8))
}

private let base = #""email": "dev@example.com", "organizationName": "o", "organizationUuid": "u", "isOrganization": true"#

final class RecoveryMathTests: XCTestCase {
    // #227: the spotlighted reviver is the corrected pick, only with no
    // candidate and a plausible future reset.
    func testReviverOnlyWhileAllDeadAndPlausible() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let far = ISO8601DateFormatter().string(from: now.addingTimeInterval(400 * 24 * 3600))
        let rec = NextRecovery(number: 2, at: soon)
        XCTAssertEqual(RecoveryMath.reviver(nextCandidate: nil, nextRecovery: rec, now: now)?.number, 2)
        XCTAssertNil(RecoveryMath.reviver(nextCandidate: 1, nextRecovery: rec, now: now))
        XCTAssertNil(RecoveryMath.reviver(nextCandidate: nil, nextRecovery: nil, now: now))
        XCTAssertNil(RecoveryMath.reviver(nextCandidate: nil, nextRecovery: NextRecovery(number: 2, at: far), now: now))
        XCTAssertNil(RecoveryMath.reviver(nextCandidate: nil, nextRecovery: NextRecovery(number: 2, at: "garbage"), now: now))
    }

    // (a) the reported bug: the active account is both dead and the
    // soonest reviver, but the engine's advisory (mirrored by
    // `_next_recovery`'s active-skip) would have named a later account.
    // RecoveryMath.nextRecovery must not exclude the active account.
    func testActiveAccountWinsWhenSoonest() throws {
        let active = try account(#"{"number": 1, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-02T00:27:00Z"}, "sevenDay": {"pct": 40, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let other = try account(#"{"number": 2, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-02T01:07:23Z"}, "sevenDay": {"pct": 40, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let result = RecoveryMath.nextRecovery(accounts: [active, other])
        XCTAssertEqual(result?.number, 1)
        XCTAssertEqual(result?.at, "2026-09-02T00:27:00Z")
    }

    // (b) disabled accounts are skipped even if they'd otherwise win.
    func testDisabledAccountsSkipped() throws {
        let disabled = try account(#"{"number": 3, \#(base), "active": false, "disabled": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-01-01T00:00:00Z"}}}"#)
        let alive = try account(#"{"number": 4, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let result = RecoveryMath.nextRecovery(accounts: [disabled, alive])
        XCTAssertEqual(result?.number, 4)
    }

    // (c) a maxed window with no resetsAt makes the account unrankable —
    // it's skipped, not treated as "resets immediately".
    func testUnrankableMaxedWindowSkipsAccount() throws {
        let unrankable = try account(#"{"number": 5, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100}}}"#)
        let rankable = try account(#"{"number": 6, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        let result = RecoveryMath.nextRecovery(accounts: [unrankable, rankable])
        XCTAssertEqual(result?.number, 6)
    }

    // (g) #226: the reviver is ranked by parsed date, and a reset that no
    // real window could have (epoch-shaped, decades out, garbage) makes
    // the account unrankable rather than the soonest — the phone showed
    // a 31-year countdown for the account whose string sorted first.
    func testImplausibleResetIsUnrankable() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z")!
        let real = try account(#"{"number": 1, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-06T13:00:00.254457+00:00"}}}"#)
        let farOut = try account(#"{"number": 2, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2057-05-16T08:28:25Z"}}}"#)
        let epoch = try account(#"{"number": 3, \#(base), "active": false, "usageStatus": "ok", "usage": {"scoped": [{"pct": 100, "resetsAt": "1788000000", "model": "Fable"}]}}"#)
        XCTAssertEqual(RecoveryMath.nextRecovery(accounts: [farOut, epoch, real], now: now)?.number, 1)
        XCTAssertEqual(RecoveryMath.nextRecovery(accounts: [farOut, epoch], now: now), nil)
        XCTAssertNil(RecoveryMath.revival(of: farOut, now: now))
        XCTAssertNil(RecoveryMath.revival(of: epoch, now: now))
        // A scoped window counts, and the LAST maxed window is the revival.
        let scopedLater = try account(#"{"number": 4, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-06T12:30:00Z"}, "scoped": [{"pct": 100, "resetsAt": "2026-09-08T11:00:00.324579+00:00", "model": "Fable"}]}}"#)
        XCTAssertEqual(RecoveryMath.revival(of: scopedLater, now: now)?.iso, "2026-09-08T11:00:00.324579+00:00")
        XCTAssertEqual(RecoveryMath.nextRecovery(accounts: [scopedLater, real], now: now)?.number, 1)
        // Fallback to the engine's word still applies when nobody ranks.
        let engineValue = NextRecovery(number: 2, at: "2057-05-16T08:28:25Z")
        XCTAssertEqual(RecoveryMath.corrected(engine: engineValue, accounts: [farOut], activeNumber: nil, now: now)?.number, 2)
    }

    // (d) corrected() must not invent an all-dead premise: nil engine
    // value stays nil even if every account looks dead client-side.
    func testCorrectedNilWhenEngineNil() throws {
        let dead = try account(#"{"number": 7, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-05T00:00:00Z"}}}"#)
        XCTAssertNil(RecoveryMath.corrected(engine: nil, accounts: [dead], activeNumber: 7))
    }

    // (e) falls back to the engine's value when the client can't rank
    // anyone (e.g. all maxed windows are unrankable).
    func testCorrectedFallsBackWhenUnrankable() throws {
        let unrankable = try account(#"{"number": 8, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100}}}"#)
        let engineValue = NextRecovery(number: 8, at: "2026-09-05T00:00:00Z")
        let result = RecoveryMath.corrected(engine: engineValue, accounts: [unrankable], activeNumber: 8)
        XCTAssertEqual(result?.number, 8)
        XCTAssertEqual(result?.at, "2026-09-05T00:00:00Z")
    }

    // (f) the engine names a reviver whenever no OTHER account is a
    // switch target — with the active account healthy that is not
    // "all limited" (user 2026-09-04: "All accounts down" over a
    // working fleet). corrected() returns nil; a limited active account
    // keeps the advisory; no active account keeps it too.
    func testCorrectedNilWhileTheActiveAccountIsHealthy() throws {
        let healthy = try account(#"{"number": 5, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 25, "resetsAt": "2026-09-04T15:59:59Z"}, "sevenDay": {"pct": 5, "resetsAt": "2026-09-11T00:59:59Z"}}}"#)
        let limited = try account(#"{"number": 4, \#(base), "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-04T14:00:00Z"}}}"#)
        let engineValue = NextRecovery(number: 4, at: "2026-09-04T14:00:00Z")
        XCTAssertNil(RecoveryMath.corrected(engine: engineValue, accounts: [healthy, limited], activeNumber: 5))
        let activeLimited = try account(#"{"number": 5, \#(base), "active": true, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 100, "resetsAt": "2026-09-04T16:00:00Z"}}}"#)
        XCTAssertEqual(RecoveryMath.corrected(engine: engineValue, accounts: [activeLimited, limited], activeNumber: 5)?.number, 4)
        XCTAssertEqual(RecoveryMath.corrected(engine: engineValue, accounts: [healthy, limited], activeNumber: nil)?.number, 4)
    }
}
