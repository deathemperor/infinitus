import XCTest
@testable import InfinitusCore

final class LeaseTableTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func report(_ id: String, _ scopes: [ClientActivity.Scope], ttlMs: Int = 45_000) -> ClientActivity.Report {
        .init(clientId: id, visible: true, focused: true, recentlyInteracted: true, scopes: scopes, ttlMs: ttlMs)
    }

    func testAReportHoldsItsScopesUntilTheTTL() {
        let t = LeaseTable()
        t.report(report("phone", [.session(7), .stats]), now: t0)
        XCTAssertTrue(t.holds(.session(7), now: t0 + 44))
        XCTAssertTrue(t.holds(.stats, now: t0 + 44))
        XCTAssertFalse(t.holds(.session(8), now: t0 + 44))
        XCTAssertFalse(t.holds(.session(7), now: t0 + 46))
        XCTAssertEqual(t.clientCount(now: t0 + 46), 0)
    }

    func testSessionsCoversEveryPidAndLeasedPidsSaysSo() {
        let t = LeaseTable()
        t.report(report("phone", [.session(7)]), now: t0)
        XCTAssertEqual(t.leasedPids(now: t0), [7])
        t.report(report("local", [.sessions]), now: t0)
        XCTAssertTrue(t.holds(.session(99), now: t0))
        XCTAssertNil(t.leasedPids(now: t0))
        t.release(clientId: "local")
        XCTAssertEqual(t.leasedPids(now: t0), [7])
    }

    func testARepeatReplacesTheClientsScopesAndTTLIsCapped() {
        let t = LeaseTable()
        t.report(report("phone", [.session(7)]), now: t0)
        t.report(report("phone", [.session(8)], ttlMs: 3_600_000), now: t0)
        XCTAssertFalse(t.holds(.session(7), now: t0))
        XCTAssertTrue(t.holds(.session(8), now: t0 + 299))
        XCTAssertFalse(t.holds(.session(8), now: t0 + 301))
    }

    func testAZeroTTLReleases() {
        let t = LeaseTable()
        t.report(report("phone", [.sessions]), now: t0)
        t.report(report("phone", [.sessions], ttlMs: 0), now: t0)
        XCTAssertFalse(t.holds(.sessions, now: t0))
        XCTAssertEqual(t.clientCount(now: t0), 0)
    }

    func testHeldNamesEachClientsScopes() {
        let t = LeaseTable()
        t.report(report("p1", [.session(7), .stats]), now: t0)
        t.report(report("web", [.sessions, .fleets]), now: t0)
        XCTAssertEqual(t.held(now: t0), ["p1": ["session:7", "stats"], "web": ["fleets", "sessions"]])
        XCTAssertEqual(t.held(now: t0.addingTimeInterval(60)), [:])
    }

    func testNoLeasesMeansNothingIsHeld() {
        let t = LeaseTable()
        XCTAssertFalse(t.holds(.sessions, now: t0))
        XCTAssertEqual(t.leasedPids(now: t0), [])
    }

    func testReportDecodesTheT3Shape() throws {
        let r = try JSONDecoder().decode(ClientActivity.Report.self, from: Data(
            #"{"clientId":"p1","visible":true,"focused":false,"recentlyInteracted":true,"scopes":[{"type":"session","pid":7},{"type":"stats"}],"ttlMs":45000}"#.utf8))
        XCTAssertEqual(r.scopes, [.session(7), .stats])
        XCTAssertEqual(ClientActivity.path, "/client-activity")
    }
}
