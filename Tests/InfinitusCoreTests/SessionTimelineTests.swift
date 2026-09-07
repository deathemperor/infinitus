import XCTest
@testable import InfinitusCore

/// The T3-shaped timeline built from a transcript (#223 phase 1).
final class SessionTimelineTests: XCTestCase {
    /// Decoded lines of `Fixtures/timeline/<name>.jsonl`.
    func entries(_ name: String) throws -> [[String: Any]] {
        let url = Bundle.module.url(forResource: "Fixtures/timeline/\(name)", withExtension: "jsonl")!
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { SessionFeedReader.decodeLine(String($0)) }
    }
    func lines(_ raw: [String]) -> [[String: Any]] { raw.compactMap(SessionFeedReader.decodeLine) }
    func build(_ e: [[String: Any]], status: String? = "idle", statusUpdatedAt: Date? = nil,
               agents: [String: SessionFeedItem.Agent] = [:]) -> SessionTimeline {
        SessionTimelineBuilder.build(entries: e, status: status, statusUpdatedAt: statusUpdatedAt, agents: agents)
    }

    // MARK: Task 1 — types
    func testTimelineRoundTripsAndKeepsAnUnknownKind() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = Activity(id: "x:0", tone: .info, kind: "future.kind", summary: "later", detail: nil,
                         payload: ["n": .number(1)], turnId: "u1", sequence: 0, createdAt: t0)
        let m = Message(id: "u1", role: .user, text: "hi", images: nil, sender: nil, turnId: "u1", streaming: false, createdAt: t0)
        let turn = Turn(id: "u1", state: .completed, requestedAt: t0, startedAt: nil, completedAt: t0,
                        userMessageId: "u1", assistantMessageId: nil)
        let tl = SessionTimeline(turns: [turn], messages: [m], activities: [a])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SessionTimeline.self, from: try enc.encode(tl))
        XCTAssertEqual(back, tl)
        XCTAssertEqual(back.activities.first?.kind, "future.kind")
        XCTAssertEqual(back.activity(id: "x:0")?.summary, "later")
        XCTAssertEqual(back.message(id: "u1")?.text, "hi")
        XCTAssertEqual(back.turn(id: "u1")?.state, .completed)
        XCTAssertEqual(back.latestTurn?.id, "u1")
    }

    func testEmptyTimelineDecodesFromMissingFields() throws {
        let tl = try JSONDecoder().decode(SessionTimeline.self, from: Data("{}".utf8))
        XCTAssertTrue(tl.turns.isEmpty && tl.messages.isEmpty && tl.activities.isEmpty)
        XCTAssertNil(tl.latestTurn)
    }
}
