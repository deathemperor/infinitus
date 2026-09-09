import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// `usageLimits.ts` (upstream 6c583620f) case for case: pace against the
/// clock, the countdown phrasing, quota left, and the pooled columns.
final class T3UsageLimitsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-03T11:00:00Z")!

    private func window(used: Double, resetIn: TimeInterval? = 2 * 3600, kind: T3UsageLimits.Window.Kind = .session,
                        expected: Double? = nil) -> T3UsageLimits.Window {
        T3UsageLimits.Window(kind: kind, id: kind == .session ? "session" : "weekly", label: "Session", usedPct: used,
                             resetsAt: resetIn.map { now.addingTimeInterval($0) },
                             length: kind == .session ? T3UsageLimits.sessionSeconds : T3UsageLimits.weekSeconds,
                             expectedPct: expected)
    }

    func testPacePlacesTheClockThreeFifthsThroughAFiveHourWindowWithTwoHoursLeft() {
        XCTAssertEqual(window(used: 40).elapsedShare(now: now)!, 0.6, accuracy: 0.001)
        XCTAssertEqual(T3UsageLimits.pace(window(used: 40), now: now), .under)
        XCTAssertEqual(T3UsageLimits.pace(window(used: 62), now: now), .on)
        XCTAssertEqual(T3UsageLimits.pace(window(used: 80), now: now), .ahead)
        XCTAssertNil(T3UsageLimits.pace(window(used: 40, resetIn: nil), now: now))
        // The engine's own expectation outranks the clock.
        XCTAssertEqual(T3UsageLimits.pace(window(used: 40, expected: 30), now: now), .ahead)
    }

    func testTheResetReadsAsACountdown() {
        XCTAssertEqual(T3UsageLimits.resetsIn(window(used: 40), now: now), "resets in 2h 0m")
        XCTAssertEqual(T3UsageLimits.resetsIn(window(used: 40, resetIn: 3 * 86400 + 3 * 3600 + 1800), now: now), "resets in 3d 3h")
        XCTAssertEqual(T3UsageLimits.resetsIn(window(used: 40, resetIn: 0), now: now), "resets now")
        XCTAssertNil(T3UsageLimits.resetsIn(window(used: 40, resetIn: nil), now: now))
        XCTAssertEqual(T3UsageLimits.formatDuration(12 * 60 + 30), "12m")
    }

    func testRemainingInvertsAndClampsTheReportedUsage() {
        XCTAssertEqual(window(used: 40).remainingPct, 60)
        XCTAssertEqual(window(used: 0).remainingPct, 100)
        XCTAssertEqual(window(used: 130).remainingPct, 0)
        XCTAssertEqual(window(used: 33.4).remainingPct, 67)
    }

    func testAccountNamesFallBackToEmailInitials() {
        XCTAssertEqual(T3UsageLimits.name(alias: "Work", email: "a@b.com"), "Work")
        XCTAssertEqual(T3UsageLimits.name(alias: " ", email: "dev@gmail.com"), "DG")
        XCTAssertEqual(T3UsageLimits.name(alias: nil, email: ""), "Account")
    }

    func testPoolsKeepAccountColumnsAlignedAndOrderBySoonestSessionReset() {
        let late = T3UsageLimits.Member(number: 1, name: "B", email: "b@x", plan: nil, disabled: false,
                                        windows: [window(used: 80, resetIn: 3 * 3600), window(used: 20, resetIn: 86400, kind: .weekly)])
        let soon = T3UsageLimits.Member(number: 2, name: "A", email: "a@x", plan: nil, disabled: false,
                                        windows: [window(used: 40, resetIn: 3600)])
        let pools = T3UsageLimits.pools([late, soon], now: now)
        XCTAssertEqual(pools.map(\.kind), [.session, .weekly])
        XCTAssertEqual(pools[0].columns.map(\.member.number), [2, 1])
        XCTAssertEqual(pools[0].remainingPct, 40)
        XCTAssertEqual(pools[0].resets.map(\.member.number), [2, 1])
        XCTAssertEqual(pools[0].resets.map(\.restoresPct), [20, 40])
        // The weekly pool leaves a gap where the soon account has no weekly window.
        XCTAssertEqual(pools[1].columns.map { $0.window == nil }, [true, false])
        XCTAssertEqual(pools[1].remainingPct, 80)
    }
}
