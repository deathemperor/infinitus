import XCTest
@testable import InfinitusCore

final class T3ThreadStatusTests: XCTestCase {
    private func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private func thread(approvals: Bool = false, input: Bool = false, session: T3Thread.SessionStatus? = nil) -> T3Thread {
        T3Thread(id: "t", title: "T", createdAt: d("2026-06-01T00:00:00Z"), updatedAt: d("2026-06-01T00:00:00Z"),
                 hasPendingApprovals: approvals, hasPendingUserInput: input,
                 session: session.map { .init(status: $0, updatedAt: d("2026-06-01T00:00:00Z")) })
    }
    // threadListV2.ts resolveThreadListV2Status: approval > input > working > failed > ready
    func testPrecedence() {
        XCTAssertEqual(T3ThreadStatus(thread(approvals: true, input: true, session: .running)), .approval)
        XCTAssertEqual(T3ThreadStatus(thread(input: true, session: .running)), .input)
        XCTAssertEqual(T3ThreadStatus(thread(session: .running)), .working)
        XCTAssertEqual(T3ThreadStatus(thread(session: .starting)), .working)
        XCTAssertEqual(T3ThreadStatus(thread(session: .error)), .failed)
        XCTAssertEqual(T3ThreadStatus(thread(session: .idle)), .ready)
        XCTAssertEqual(T3ThreadStatus(thread()), .ready)
    }
    func testFromFacts() {
        func facts(_ s: SessionFacts.Status, approvals: Bool = false, input: Bool = false) -> SessionFacts {
            SessionFacts(status: s, hasPendingApprovals: approvals, hasPendingUserInput: input, hasPlan: false, latestTurn: nil,
                         planProgress: nil, latestUserMessageAt: nil, settledOverride: nil, settledAt: nil, unsettledAt: nil,
                         snoozedUntil: nil, snoozedAt: nil, pinnedAt: nil)
        }
        XCTAssertEqual(T3ThreadStatus(facts: facts(.running, approvals: true)), .approval)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.running, input: true)), .input)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.running)), .working)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.starting)), .working)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.error)), .failed)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.interrupted)), .ready)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.ready)), .ready)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.idle)), .ready)
        XCTAssertEqual(T3ThreadStatus(facts: facts(.stopped)), .ready)
    }
}
