import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// `/usage-limits` (upstream `usageLimits.ts` isUsageLimitsCommand) and the
/// report the composer card shows for a session's account(s).
final class T3ComposerLimitsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-03T11:00:00Z")!

    func testOnlyTheBareCommandIsAnsweredLocally() {
        XCTAssertTrue(T3ComposerLimits.isCommand("/usage-limits"))
        XCTAssertTrue(T3ComposerLimits.isCommand("  /Usage-Limits\n"))
        XCTAssertFalse(T3ComposerLimits.isCommand("/usage-limits now"))
        XCTAssertFalse(T3ComposerLimits.isCommand("/usage"))
    }

    private func account(_ number: Int, alias: String, pct: Double, disabled: Bool? = nil, active: Bool = false) -> Account {
        Account(number: number, email: "\(alias.lowercased())@x.com", active: active,
                usage: Usage(fiveHour: UsageWindow(pct: pct, resetsAt: "2026-09-03T13:00:00Z")), alias: alias, plan: "Max", disabled: disabled)
    }

    func testACswapSessionReportsItsOneActiveAccount() {
        let session = SessionDetail(pid: 42, cwd: "/tmp", status: "busy", kind: "interactive", startedAt: 0)
        let fleet = EngineFleet(engineID: "cswap", provider: .claude,
                                accounts: [account(1, alias: "Home", pct: 10), account(2, alias: "Work", pct: 62, active: true)],
                                activeNumber: 2, liveSessions: LiveSessions(busy: 1, total: 1, sessions: [session]))
        let report = T3ComposerLimits.report(SessionAccountLookup.summarize(pid: 42, fleets: [fleet]), provider: .claude, now: now)!
        XCTAssertEqual(report.members.map(\.name), ["Work"])
        XCTAssertEqual(report.members[0].windows.map(\.remainingPct), [38])
        XCTAssertEqual(report.members[0].plan, "Max")
    }

    func testAProxySessionReportsEveryAccount() {
        let fleet = EngineFleet(engineID: CLIProxyEngine.engineID, provider: .claude,
                                accounts: [account(1, alias: "A", pct: 10), account(2, alias: "B", pct: 90), account(3, alias: "C", pct: 0, disabled: true)],
                                activeNumber: nil, liveSessions: nil)
        let report = T3ComposerLimits.report(SessionAccountLookup.summarize(pid: 7, fleets: [fleet]), provider: .claude, now: now)!
        XCTAssertEqual(report.members.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(report.members.map(\.disabled), [false, false, true])
    }

    func testNoFleetsMeansNoReport() {
        XCTAssertNil(T3ComposerLimits.report(SessionAccountLookup.summarize(pid: 1, fleets: []), provider: .claude, now: now))
    }
}
