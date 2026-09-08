import XCTest
@testable import InfinitusCore

/// `T3TimelineInput.make` (Task 9): `SessionTimeline` (+ owned pending) → the
/// rows reducer's `Input` — the same shape `AppModel`'s mirror route derives
/// per pid, trimmed to what `T3TimelineRows.derive` reads.
final class T3TimelineInputTests: XCTestCase {
    private func timeline(state: SessionTimeline.Turn.State, startedAt: Date?, requestedAt: Date) -> SessionTimeline {
        SessionTimeline(
            turns: [.init(id: "t1", state: state, requestedAt: requestedAt, startedAt: startedAt,
                          completedAt: state == .running ? nil : requestedAt.addingTimeInterval(5),
                          userMessageId: "u1", assistantMessageId: state == .running ? nil : "a1")],
            messages: [.init(id: "u1", role: .user, text: "hi", images: nil, sender: nil, turnId: "t1",
                             streaming: false, createdAt: requestedAt)],
            activities: [])
    }

    func testRunningTurnIsWorking() {
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let startedAt = requestedAt.addingTimeInterval(1)
        let t = timeline(state: .running, startedAt: startedAt, requestedAt: requestedAt)
        let input = T3TimelineInput.make(timeline: t, pending: [], facts: nil,
                                         expandedTurnIds: [], expandedWorkGroupIds: [])
        XCTAssertTrue(input.isWorking)
        XCTAssertEqual(input.runningTurnId, "t1")
        XCTAssertEqual(input.activeTurnStartedAt, startedAt)
        XCTAssertEqual(input.latestTurn?.turnId, "t1")
        XCTAssertEqual(input.latestTurn?.state, .running)
        XCTAssertEqual(input.turnDiffSummaries, [])
        XCTAssertFalse(input.supportsConversationRollback)
    }

    /// No `startedAt` on the running turn: falls back to `requestedAt`.
    func testRunningTurnFallsBackToRequestedAt() {
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let t = timeline(state: .running, startedAt: nil, requestedAt: requestedAt)
        let input = T3TimelineInput.make(timeline: t, pending: [], facts: nil,
                                         expandedTurnIds: [], expandedWorkGroupIds: [])
        XCTAssertEqual(input.activeTurnStartedAt, requestedAt)
    }

    func testCompletedTurnIsNotWorking() {
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let t = timeline(state: .completed, startedAt: requestedAt, requestedAt: requestedAt)
        let input = T3TimelineInput.make(timeline: t, pending: [], facts: nil,
                                         expandedTurnIds: [], expandedWorkGroupIds: [])
        XCTAssertFalse(input.isWorking)
        XCTAssertNil(input.runningTurnId)
        XCTAssertNil(input.activeTurnStartedAt)
    }

    /// `facts?.status == .running` alone (no running turn yet, an owned
    /// session's first prompt in flight) still marks `isWorking`.
    func testFactsRunningWithoutARunningTurnStillWorks() {
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let t = timeline(state: .completed, startedAt: requestedAt, requestedAt: requestedAt)
        let facts = SessionFacts(status: .running, hasPendingApprovals: false, hasPendingUserInput: false,
                                 hasPlan: false, latestTurn: nil, planProgress: nil, latestUserMessageAt: nil,
                                 settledOverride: nil, settledAt: nil, unsettledAt: nil, snoozedUntil: nil,
                                 snoozedAt: nil, pinnedAt: nil)
        let input = T3TimelineInput.make(timeline: t, pending: [], facts: facts,
                                         expandedTurnIds: [], expandedWorkGroupIds: [])
        XCTAssertTrue(input.isWorking)
        // No running turn in the timeline itself, so nothing to point at.
        XCTAssertNil(input.runningTurnId)
        XCTAssertNil(input.activeTurnStartedAt)
    }

    func testExpandedSetsPassThrough() {
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let t = timeline(state: .completed, startedAt: requestedAt, requestedAt: requestedAt)
        let input = T3TimelineInput.make(timeline: t, pending: [], facts: nil,
                                         expandedTurnIds: ["t1"], expandedWorkGroupIds: ["g1"])
        XCTAssertEqual(input.expandedTurnIds, ["t1"])
        XCTAssertEqual(input.expandedWorkGroupIds, ["g1"])
    }

    /// A pending approval folds into `entries` the same way the phone's
    /// mirror does (`T3TimelineEntry.entries(from:pending:)`), not twice.
    func testPendingApprovalFoldsIntoEntries() {
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let t = timeline(state: .completed, startedAt: requestedAt, requestedAt: requestedAt)
        let pending = PendingRequest(requestId: "req-1", toolName: "Write", toolUseId: "tu-1",
                                     description: "Write PLAN.md", inputJSON: "{}", suggestionsJSON: nil,
                                     questions: [], receivedAt: requestedAt.addingTimeInterval(6))
        let input = T3TimelineInput.make(timeline: t, pending: [pending], facts: nil,
                                         expandedTurnIds: [], expandedWorkGroupIds: [])
        let work = input.entries.compactMap { entry -> T3WorkLogEntry? in
            if case let .work(_, _, w) = entry { return w } else { return nil }
        }
        XCTAssertEqual(work.map(\.sourceActivityKind), ["approval.requested"])
        XCTAssertEqual(work.first?.tone, .info)
        // The raw timeline itself is untouched — folding happened inside `make`.
        XCTAssertTrue(t.activities.isEmpty)
    }
}
