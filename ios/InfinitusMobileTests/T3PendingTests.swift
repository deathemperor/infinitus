import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// The thread's live prompt (C-3): read off the timeline, gone once
/// resolved, and its answers encoded the way Claude Code records them.
final class T3PendingTests: XCTestCase {
    private func activity(_ id: String, kind: String, seq: Int, payload: [String: JSONValue]) -> SessionTimeline.Activity {
        .init(id: id, tone: .approval, kind: kind, summary: "s", detail: nil, payload: payload,
              turnId: "t1", sequence: seq, createdAt: Date(timeIntervalSince1970: 1))
    }

    func testAnUnresolvedApprovalIsLiveAndRendersItsBashCommand() {
        let t = SessionTimeline(activities: [
            activity("perm:a", kind: "approval.requested", seq: 0,
                     payload: ["requestId": .string("perm:a"), "toolName": .string("Bash"),
                               "input": .object(["command": .string("git status --short")])]),
        ])
        let live = T3Pending.derive(t)
        XCTAssertEqual(live.approval?.toolName, "Bash")
        XCTAssertEqual(live.approval?.detail, "git status --short")
        XCTAssertEqual(live.approval?.rule.label, "Bash git …")
        XCTAssertEqual(live.approval?.sessionApproval, "Bash\ngit status --short")
        XCTAssertEqual(live.activityIds, ["perm:a"])
        XCTAssertNil(live.userInput)
    }

    func testAResolvedQuestionIsNotLive() {
        let questions: JSONValue = .array([.object([
            "id": .string("Which?"), "question": .string("Which?"), "header": .string("Pick"), "multiSelect": .bool(false),
            "options": .array([.object(["label": .string("A"), "description": .string("first")])]),
        ])])
        let asked = activity("perm:q", kind: "user-input.requested", seq: 0,
                             payload: ["requestId": .string("perm:q"), "questions": questions])
        XCTAssertEqual(T3Pending.derive(SessionTimeline(activities: [asked])).userInput?.questions.first?.options.first?.description, "first")
        XCTAssertEqual(T3Pending.derive(SessionTimeline(activities: [asked])).userInput?.owned, false)
        XCTAssertEqual(T3Pending.derive(SessionTimeline(activities: [asked])).userInput?.questions.first?.allowCustomAnswer, true,
                       "the flag is opt-out")
        let withdrawn: JSONValue = .array([.object([
            "id": .string("Which?"), "question": .string("Which?"), "multiSelect": .bool(false), "allowCustomAnswer": .bool(false),
            "options": .array([.object(["label": .string("A")])]),
        ])])
        let noCustom = activity("8", kind: "user-input.requested", seq: 0, payload: ["requestId": .string("8"), "questions": withdrawn])
        XCTAssertEqual(T3Pending.derive(SessionTimeline(activities: [noCustom])).userInput?.questions.first?.allowCustomAnswer, false)
        let owned = activity("7", kind: "user-input.requested", seq: 0, payload: ["requestId": .string("7"), "questions": questions])
        XCTAssertEqual(T3Pending.derive(SessionTimeline(activities: [owned])).userInput?.owned, true)
        let answered = activity("perm:q/resolved", kind: "user-input.resolved", seq: 1,
                                payload: ["requestId": .string("perm:q"), "answers": .string("A")])
        XCTAssertEqual(T3Pending.derive(SessionTimeline(activities: [asked, answered])), T3Pending.Live())
    }

    func testAnswersNeedEveryQuestionAndJoinMultiSelects() {
        let q1 = T3Pending.Question(id: "Color?", question: "Color?", header: "", multiSelect: true,
                                    options: [.init(label: "Red", description: ""), .init(label: "Blue", description: "")])
        let q2 = T3Pending.Question(id: "Size?", question: "Size?", header: "", multiSelect: false, options: [])
        XCTAssertNil(T3Pending.encodeAnswers([q1, q2], picks: ["Color?": ["Red", "Blue"]], custom: [:]))
        XCTAssertEqual(T3Pending.encodeAnswers([q1, q2], picks: ["Color?": ["Red", "Blue"]], custom: ["Size?": " large "]),
                       #"{"Color?":"Red, Blue","Size?":"large"}"#)
        // A typed answer stands in for the picks; it is never appended to them.
        XCTAssertEqual(T3Pending.encodeAnswers([q1, q2], picks: ["Color?": ["Red"]], custom: ["Color?": "teal", "Size?": "large"]),
                       #"{"Color?":"teal","Size?":"large"}"#)
    }

    func testATypedAnswerCountsOnlyWhereItIsDeliverable() {
        let multi = T3Pending.Question(id: "Color?", question: "Color?", header: "", multiSelect: true,
                                       options: [.init(label: "Red", description: ""), .init(label: "Blue", description: "")])
        let single = T3Pending.Question(id: "Size?", question: "Size?", header: "", multiSelect: false, options: [])
        // A multi-select's text carrying the separator would be split into
        // non-options by the Mac and rejected: not an answer, Submit stays off.
        XCTAssertNil(T3Pending.encodeAnswers([multi], picks: [:], custom: ["Color?": "red, or blue"]))
        XCTAssertTrue(T3Pending.separatorInMultiSelectText(multi, custom: ["Color?": "red, or blue"]))
        XCTAssertFalse(T3Pending.separatorInMultiSelectText(multi, custom: ["Color?": "red,or blue"]))
        XCTAssertFalse(T3Pending.separatorInMultiSelectText(single, custom: ["Size?": "large, please"]))
        // The same text on a single-select is one answer.
        XCTAssertEqual(T3Pending.encodeAnswers([single], picks: [:], custom: ["Size?": "large, please"]),
                       #"{"Size?":"large, please"}"#)
        // A question that withdrew the custom answer ignores typed text.
        var noCustom = single
        noCustom.allowCustomAnswer = false
        XCTAssertNil(T3Pending.encodeAnswers([noCustom], picks: [:], custom: ["Size?": "large"]))
        XCTAssertNil(T3Pending.typedAnswer(noCustom, custom: ["Size?": "large"]))
        XCTAssertFalse(T3Pending.separatorInMultiSelectText(T3Pending.Question(id: "m", question: "m", header: "", multiSelect: true,
                                                                                options: [], allowCustomAnswer: false),
                                                            custom: ["m": "a, b"]))
    }
}
