import XCTest
@testable import InfinitusCore

/// The row's attention rank, plan line and shelves from facts (#223 phase 3).
final class SessionListPresentationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func facts(_ status: SessionFacts.Status = .ready, approvals: Bool = false, input: Bool = false,
                       turnEnded: Date? = nil, plan: SessionFacts.PlanProgress? = nil,
                       settledOverride: AttentionStore.SettledOverride? = nil, settledAt: Date? = nil,
                       unsettledAt: Date? = nil, snoozedUntil: Date? = nil, snoozedAt: Date? = nil) -> SessionFacts {
        let turn = turnEnded.map {
            SessionTimeline.Turn(id: "u1", state: .completed, requestedAt: t0, startedAt: t0, completedAt: $0,
                                 userMessageId: "u1", assistantMessageId: nil)
        }
        return SessionFacts(status: status, hasPendingApprovals: approvals, hasPendingUserInput: input, hasPlan: plan != nil,
                            latestTurn: turn, planProgress: plan, latestUserMessageAt: nil,
                            settledOverride: settledOverride, settledAt: settledAt, unsettledAt: unsettledAt,
                            snoozedUntil: snoozedUntil, snoozedAt: snoozedAt, pinnedAt: nil)
    }

    func testRankOrder() {
        typealias P = SessionListPresentation
        XCTAssertEqual(P.attention(facts(.running, approvals: true, input: true), fallbackStatus: nil), .approval)
        XCTAssertEqual(P.attention(facts(.running, input: true), fallbackStatus: nil), .input)
        XCTAssertEqual(P.attention(facts(.running), fallbackStatus: nil), .working)
        XCTAssertEqual(P.attention(facts(.starting), fallbackStatus: nil), .working)
        XCTAssertEqual(P.attention(facts(.error), fallbackStatus: nil), .failed)
        XCTAssertEqual(P.attention(facts(.interrupted), fallbackStatus: nil), .failed)
        XCTAssertEqual(P.attention(facts(.ready), fallbackStatus: "busy"), .ready, "facts beat the status word")
    }

    func testNoFactsFallsBackToTheStatusWord() {
        typealias P = SessionListPresentation
        XCTAssertEqual(P.attention(nil, fallbackStatus: "busy"), .working)
        XCTAssertEqual(P.attention(nil, fallbackStatus: "waiting"), .approval)
        XCTAssertEqual(P.attention(nil, fallbackStatus: "idle"), .ready)
        XCTAssertEqual(P.attention(nil, fallbackStatus: nil), .ready)
    }

    func testStatusWordSpeaksTheEngineVocabulary() {
        typealias P = SessionListPresentation
        XCTAssertEqual(P.statusWord(.approval, raw: "busy"), "waiting")
        XCTAssertEqual(P.statusWord(.input, raw: "idle"), "waiting")
        XCTAssertEqual(P.statusWord(.working, raw: "idle"), "busy")
        XCTAssertEqual(P.statusWord(.failed, raw: "idle"), "failed")
        XCTAssertEqual(P.statusWord(.ready, raw: "shell"), "shell")
    }

    func testPlanLine() {
        XCTAssertNil(SessionListPresentation.planLine(nil))
        XCTAssertNil(SessionListPresentation.planLine(facts(plan: .init(step: nil, completed: 0, total: 0))))
        XCTAssertEqual(SessionListPresentation.planLine(facts(plan: .init(step: "Wire the phone", completed: 2, total: 5))), "2 of 5 · Wire the phone")
        XCTAssertEqual(SessionListPresentation.planLine(facts(plan: .init(step: nil, completed: 5, total: 5))), "5 of 5")
    }

    func testSnoozeEndsAtItsTimeOrWhenTheSessionRaisesItsHand() {
        typealias P = SessionListPresentation
        let later = t0.addingTimeInterval(3600)
        XCTAssertTrue(P.isSnoozed(facts(snoozedUntil: later, snoozedAt: t0), now: t0.addingTimeInterval(10)))
        XCTAssertFalse(P.isSnoozed(facts(snoozedUntil: later, snoozedAt: t0), now: later), "woke on time")
        XCTAssertFalse(P.isSnoozed(facts(approvals: true, snoozedUntil: later, snoozedAt: t0), now: t0), "an approval wakes it")
        XCTAssertFalse(P.isSnoozed(facts(turnEnded: t0.addingTimeInterval(60), snoozedUntil: later, snoozedAt: t0), now: t0.addingTimeInterval(70)), "a finished turn wakes it")
        XCTAssertTrue(P.isSnoozed(facts(turnEnded: t0.addingTimeInterval(-60), snoozedUntil: later, snoozedAt: t0), now: t0), "an older turn does not")
    }

    func testShelvesFollowWhatTheStoreWrites() {
        // The client rules read the fields AttentionStore.apply sets; a
        // real store round-trip pins them together.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-\(UUID().uuidString)/attention.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        typealias P = SessionListPresentation
        let store = AttentionStore(url: url)
        let tl = SessionTimeline()
        func facts(_ e: AttentionStore.Entry) -> SessionFacts { SessionFacts.derive(timeline: tl, status: nil, attention: e) }
        XCTAssertTrue(P.isSettled(facts(store.apply(.settle, sessionId: "s", until: nil, now: t0))))
        XCTAssertFalse(P.isSettled(facts(store.apply(.unsettle, sessionId: "s", until: nil, now: t0.addingTimeInterval(1)))))
        let hour = t0.addingTimeInterval(3600)
        XCTAssertTrue(P.isSnoozed(facts(store.apply(.snooze, sessionId: "s", until: hour, now: t0)), now: t0.addingTimeInterval(2)))
        XCTAssertFalse(P.isSnoozed(facts(store.apply(.unsnooze, sessionId: "s", until: nil, now: t0)), now: t0.addingTimeInterval(3)))
    }

    func testSettledOverrideWinsThenTimestamps() {
        typealias P = SessionListPresentation
        XCTAssertTrue(P.isSettled(facts(settledOverride: .settled)))
        XCTAssertFalse(P.isSettled(facts(settledOverride: .active, settledAt: t0)))
        XCTAssertTrue(P.isSettled(facts(settledAt: t0)))
        XCTAssertFalse(P.isSettled(facts(settledAt: t0, unsettledAt: t0.addingTimeInterval(1))))
        XCTAssertTrue(P.isSettled(facts(settledAt: t0.addingTimeInterval(1), unsettledAt: t0)))
        XCTAssertFalse(P.isSettled(facts()))
    }
}
