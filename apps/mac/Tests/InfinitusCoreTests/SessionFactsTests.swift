import XCTest
@testable import InfinitusCore

final class SessionFactsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func turn(_ state: SessionTimeline.Turn.State, id: String = "u1") -> SessionTimeline.Turn {
        .init(id: id, state: state, requestedAt: t0, startedAt: t0, completedAt: state == .running ? nil : t0 + 5,
              userMessageId: id, assistantMessageId: nil)
    }
    private func activity(_ kind: String, id: String, tone: SessionTimeline.Activity.Tone = .info,
                          payload: [String: JSONValue] = [:], seq: Int = 0) -> SessionTimeline.Activity {
        .init(id: id, tone: tone, kind: kind, summary: kind, detail: nil, payload: payload,
              turnId: "u1", sequence: seq, createdAt: t0)
    }

    func testBusyRecordIsRunning() {
        let f = SessionFacts.derive(timeline: .init(turns: [turn(.running)]), status: "busy", attention: .init())
        XCTAssertEqual(f.status, .running)
        XCTAssertEqual(f.latestTurn?.id, "u1")
    }

    func testIdleRecordMapsByTheLatestTurn() {
        XCTAssertEqual(SessionFacts.derive(timeline: .init(), status: "idle", attention: .init()).status, .idle)
        XCTAssertEqual(SessionFacts.derive(timeline: .init(turns: [turn(.completed)]), status: "idle", attention: .init()).status, .ready)
        XCTAssertEqual(SessionFacts.derive(timeline: .init(turns: [turn(.interrupted)]), status: nil, attention: .init()).status, .interrupted)
        XCTAssertEqual(SessionFacts.derive(timeline: .init(turns: [turn(.error)]), status: "shell", attention: .init()).status, .error)
    }

    func testPendingFlagsComeFromTheClosedSetReducer() {
        let tl = SessionTimeline(turns: [turn(.running)], activities: [
            activity("approval.requested", id: "perm:a", tone: .approval,
                     payload: ["requestId": .string("perm:a"), "toolName": .string("Bash")], seq: 0),
            activity("user-input.requested", id: "perm:q", tone: .approval,
                     payload: ["requestId": .string("perm:q"),
                               "questions": .array([.object(["id": .string("x"), "question": .string("x"),
                                                             "options": .array([.object(["label": .string("y")])])])])], seq: 1),
            activity("user-input.resolved", id: "perm:q/resolved", tone: .approval,
                     payload: ["requestId": .string("perm:q")], seq: 2),
        ])
        let f = SessionFacts.derive(timeline: tl, status: "waiting", attention: .init())
        XCTAssertTrue(f.hasPendingApprovals)
        XCTAssertFalse(f.hasPendingUserInput)
    }

    func testPlanProgressReadsTheLatestPlanActivity() {
        let steps: JSONValue = .array([.object(["text": .string("write tests"), "status": .string("completed")]),
                                       .object(["text": .string("implement"), "status": .string("in_progress")]),
                                       .object(["text": .string("ship"), "status": .string("pending")])])
        let tl = SessionTimeline(turns: [turn(.running)], activities: [
            activity("turn.plan.updated", id: "p0", payload: ["steps": .array([]), "completed": .number(0), "total": .number(1)], seq: 0),
            activity("turn.plan.updated", id: "p1", payload: ["steps": steps, "completed": .number(1), "total": .number(3)], seq: 1),
        ])
        let f = SessionFacts.derive(timeline: tl, status: "busy", attention: .init())
        XCTAssertTrue(f.hasPlan)
        XCTAssertEqual(f.planProgress, .init(step: "implement", completed: 1, total: 3))
    }

    func testNoPlanMeansNoProgress() {
        let f = SessionFacts.derive(timeline: .init(turns: [turn(.completed)]), status: "idle", attention: .init())
        XCTAssertFalse(f.hasPlan)
        XCTAssertNil(f.planProgress)
    }

    func testLatestUserMessageAtAndAttentionPassThrough() {
        let tl = SessionTimeline(turns: [turn(.completed)], messages: [
            .init(id: "u0", role: .user, text: "a", images: nil, sender: nil, turnId: "u0", streaming: false, createdAt: t0 - 10),
            .init(id: "a0", role: .assistant, text: "b", images: nil, sender: nil, turnId: "u0", streaming: false, createdAt: t0 - 5),
            .init(id: "u1", role: .user, text: "c", images: nil, sender: nil, turnId: "u1", streaming: false, createdAt: t0),
        ])
        let att = AttentionStore.Entry(settledOverride: .active, settledAt: nil, unsettledAt: t0 + 1,
                                       snoozedUntil: t0 + 2, snoozedAt: t0 + 3, pinnedAt: t0 + 4)
        let f = SessionFacts.derive(timeline: tl, status: "idle", attention: att)
        XCTAssertEqual(f.latestUserMessageAt, t0)
        XCTAssertEqual(f.settledOverride, .active)
        XCTAssertNil(f.settledAt)
        XCTAssertEqual(f.unsettledAt, t0 + 1)
        XCTAssertEqual(f.snoozedUntil, t0 + 2)
        XCTAssertEqual(f.snoozedAt, t0 + 3)
        XCTAssertEqual(f.pinnedAt, t0 + 4)
    }

    func testFactsRoundTripThroughJSON() throws {
        let f = SessionFacts.derive(timeline: .init(turns: [turn(.completed)]), status: "idle",
                                    attention: .init(settledOverride: .settled, settledAt: t0))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(f)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""settledOverride":"settled""#))
        XCTAssertEqual(try dec.decode(SessionFacts.self, from: data), f)
    }
}
