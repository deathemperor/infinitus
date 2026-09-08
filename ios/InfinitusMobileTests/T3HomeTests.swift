import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// Home's session → `T3Thread` mapping (C-6/C-10) and its ages; the list
/// order itself is `T3ThreadList`'s, tested in InfinitusCore.
final class T3HomeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func facts(status: SessionFacts.Status = .ready, approvals: Bool = false, input: Bool = false,
                       settledOverride: AttentionStore.SettledOverride? = nil, settledAt: Date? = nil, unsettledAt: Date? = nil,
                       snoozedUntil: Date? = nil, pinnedAt: Date? = nil) -> SessionFacts {
        SessionFacts(status: status, hasPendingApprovals: approvals, hasPendingUserInput: input, hasPlan: false, latestTurn: nil,
                     planProgress: nil, latestUserMessageAt: nil, settledOverride: settledOverride, settledAt: settledAt,
                     unsettledAt: unsettledAt, snoozedUntil: snoozedUntil, snoozedAt: nil, pinnedAt: pinnedAt)
    }

    private func thread(_ status: String = "idle", facts: SessionFacts?) -> T3Thread {
        let s = SessionDetail(pid: 7, cwd: "/r/limitless", status: status, kind: "claude", startedAt: 900_000_000)
        return T3HomeThreads.thread(session: s, macId: "mac-2", title: "Hi", facts: facts, lastActivity: now, now: now)
    }

    func testRelativeTimeMatchesT3() {
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-30), now: now), "<1m")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-21 * 3600 - 59), now: now), "21h")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-3 * 86_400), now: now), "3d")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(60), now: now), "<1m")
    }

    func testIdentityAndStatusFromFacts() {
        let t = thread(facts: facts(status: .running, approvals: true, pinnedAt: now))
        XCTAssertEqual(t.key, "mac-2:7")
        XCTAssertEqual(t.projectId, "/r/limitless")
        XCTAssertEqual(t.createdAt, Date(timeIntervalSince1970: 900_000))
        XCTAssertEqual(t.pinnedAt, now)
        XCTAssertEqual(T3ThreadStatus(t), .approval)
        XCTAssertEqual(T3ThreadStatus(thread(facts: facts(status: .running))), .working)
        XCTAssertEqual(T3ThreadStatus(thread(facts: facts(status: .error))), .failed)
    }

    func testEngineWordDecidesWithoutFacts() {
        XCTAssertEqual(T3ThreadStatus(thread("busy", facts: nil)), .working)
        XCTAssertEqual(T3ThreadStatus(thread("waiting", facts: nil)), .approval)
        XCTAssertEqual(T3ThreadStatus(thread("idle", facts: nil)), .ready)
        XCTAssertNil(thread(facts: nil).settledOverride)
    }

    func testTimestampSettlementBecomesTheOverride() {
        XCTAssertEqual(thread(facts: facts(settledAt: now)).settledOverride, .settled)
        XCTAssertEqual(thread(facts: facts(settledAt: now.addingTimeInterval(-10), unsettledAt: now)).settledOverride, .active)
        XCTAssertEqual(thread(facts: facts(settledOverride: .active, settledAt: now)).settledOverride, .active)
        XCTAssertEqual(thread(facts: facts()).settledOverride, .active)
    }

    func testSnoozeCarriesOverForTheReducer() {
        let t = thread(facts: facts(snoozedUntil: now.addingTimeInterval(3600)))
        XCTAssertTrue(T3ThreadSettled.effectiveSnoozed(t, now: now))
        let raised = thread(facts: facts(approvals: true, snoozedUntil: now.addingTimeInterval(3600)))
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(raised, now: now))
    }
}
