import XCTest
@testable import InfinitusCore

final class SessionAccountSummaryTests: XCTestCase {
    private func account(_ number: Int, email: String, fiveHourPct: Double = 0,
                         active: Bool = false, disabled: Bool? = nil) -> Account {
        Account(number: number, email: email, active: active,
                usage: Usage(fiveHour: UsageWindow(pct: fiveHourPct)), disabled: disabled)
    }

    func testSwapdSessionReportsTheActiveAccount() {
        let session = SessionDetail(pid: 42, cwd: "/tmp", status: "busy", kind: "interactive", startedAt: 0)
        let fleet = EngineFleet(engineID: "swapd", provider: .claude,
                                 accounts: [account(1, email: "a@x.com"), account(2, email: "b@x.com", active: true)],
                                 activeNumber: 2,
                                 liveSessions: LiveSessions(busy: 1, total: 1, sessions: [session]))
        let summary = SessionAccountLookup.summarize(pid: 42, fleets: [fleet])
        XCTAssertEqual(summary?.kind, .swap)
        XCTAssertEqual(summary?.account?.number, 2)
    }

    func testCLIProxySessionReportsPerRequestRoutingWithEveryAccount() {
        // CLIProxyAPI fleets never populate liveSessions (ProxyMapping) —
        // a session found nowhere else falls back to the primary fleet,
        // which is what actually happens today (only swapd ever reports
        // liveSessions per SessionsScreen.fleetsWithSessions).
        let proxyFleet = EngineFleet(engineID: CLIProxyEngine.engineID, provider: .claude,
                                      accounts: [account(1, email: "a@x.com", fiveHourPct: 10),
                                                 account(2, email: "b@x.com", fiveHourPct: 90),
                                                 account(3, email: "c@x.com", disabled: true)],
                                      activeNumber: nil, liveSessions: nil)
        let summary = SessionAccountLookup.summarize(pid: 7, fleets: [proxyFleet])
        XCTAssertEqual(summary?.kind, .proxy)
        XCTAssertEqual(summary?.proxyAccounts.count, 3)
        XCTAssertEqual(summary?.proxyAliveCount, 2)   // account 3 is disabled
        XCTAssertEqual(summary?.proxyLowestHeadroom?.number, 2)  // 90% used = least headroom
    }

    func testUnknownEngineFallsBackToPrimaryFleetsActiveAccount() {
        let fleet = EngineFleet(engineID: "some-future-engine", provider: .claude,
                                 accounts: [account(1, email: "a@x.com", active: true)],
                                 activeNumber: 1, liveSessions: nil)
        let summary = SessionAccountLookup.summarize(pid: 99, fleets: [fleet])
        XCTAssertEqual(summary?.kind, .unknownFleet)
        XCTAssertEqual(summary?.account?.number, 1)
    }

    func testNoFleetsYieldsNilSummary() {
        XCTAssertNil(SessionAccountLookup.summarize(pid: 1, fleets: []))
    }

    func testHeadroomColorBands() {
        XCTAssertEqual(AccountHeadroom.colorName(forPct: 10), "green")
        XCTAssertEqual(AccountHeadroom.colorName(forPct: 85), "orange")
        XCTAssertEqual(AccountHeadroom.colorName(forPct: 100), "red")
    }
}
