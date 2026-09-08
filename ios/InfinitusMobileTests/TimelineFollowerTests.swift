import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// The `/timeline` fold (T3 clone C-1): snapshots replace, upserts merge
/// by id, tombstones drop, and the cursor follows the reply.
final class TimelineFollowerTests: XCTestCase {
    private func sync(_ json: String) throws -> TimelineFollower.State {
        TimelineFollower.apply(try NetworkFleetMirror.decodeTimeline(Data(json.utf8)), to: .init())
    }

    private static let turn = #"{"id":"t1","state":"completed","requestedAt":"2026-09-08T01:00:00Z","userMessageId":"u1"}"#
    private static let user = #"{"id":"u1","role":"user","text":"hi","turnId":"t1","streaming":false,"createdAt":"2026-09-08T01:00:00Z"}"#
    private static let assistant = #"{"id":"a1","role":"assistant","text":"hello","turnId":"t1","streaming":false,"createdAt":"2026-09-08T01:00:02Z"}"#
    private static let activity = #"{"id":"x1","tone":"tool","kind":"tool.call","summary":"Read a file","payload":{},"turnId":"t1","sequence":0,"createdAt":"2026-09-08T01:00:01Z"}"#
    private static let facts = #"{"status":"running","hasPendingApprovals":false,"hasPendingUserInput":false,"hasPlan":false}"#

    private static let snapshot = """
    {"epoch":"e1","sequence":3,"synchronized":true,"snapshot":{"timeline":{"turns":[\(turn)],"messages":[\(user)],"activities":[]},"facts":\(facts)}}
    """

    func testASnapshotReplacesTheTimelineAndMovesTheCursor() throws {
        let state = try sync(Self.snapshot)
        XCTAssertEqual(state.timeline.messages.map(\.id), ["u1"])
        XCTAssertEqual(state.facts?.status.rawValue, "running")
        XCTAssertEqual(state.epoch, "e1")
        XCTAssertEqual(state.sequence, 3)
        XCTAssertTrue(state.synchronized)
    }

    func testEventsUpsertByIdInWireOrder() throws {
        let start = try sync(Self.snapshot)
        let streaming = Self.assistant.replacingOccurrences(of: #""streaming":false"#, with: #""streaming":true"#)
        let reply = """
        {"epoch":"e1","sequence":6,"synchronized":true,"events":[
          {"sequence":4,"pid":1,"op":"upsert","entity":"activity","id":"x1","body":\(Self.activity)},
          {"sequence":5,"pid":1,"op":"upsert","entity":"message","id":"a1","body":\(streaming)},
          {"sequence":6,"pid":1,"op":"upsert","entity":"message","id":"a1","body":\(Self.assistant)}]}
        """
        let state = TimelineFollower.apply(try NetworkFleetMirror.decodeTimeline(Data(reply.utf8)), to: start)
        XCTAssertEqual(state.timeline.messages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(state.timeline.messages.last?.streaming, false)
        XCTAssertEqual(state.timeline.activities.map(\.id), ["x1"])
        XCTAssertEqual(state.sequence, 6)
        // The reducer's rows over the same state: the user message, the
        // activity, the assistant message with its meta.
        let input = T3ThreadScreen.timelineInput(state: state, hiddenActivityIds: [], expandedTurnIds: [], expandedWorkGroupIds: [])
        XCTAssertEqual(input.entries.map(\.id), ["message:u1", "activity:x1", "message:a1"])
        XCTAssertEqual(input.isWorking, state.facts?.status == .running)
        let kinds = T3TimelineRows.derive(input).map(\.kind)
        XCTAssertEqual(kinds.first, "message")
        XCTAssertTrue(kinds.contains("message") && kinds.count >= 2, "\(kinds)")
    }

    func testATombstoneDropsTheEntityAndAFactsEventReplacesFacts() throws {
        let start = try sync(Self.snapshot)
        let stopped = Self.facts.replacingOccurrences(of: "running", with: "stopped")
        let reply = """
        {"epoch":"e1","sequence":5,"synchronized":true,"events":[
          {"sequence":4,"pid":1,"op":"tombstone","entity":"message","id":"u1"},
          {"sequence":5,"pid":1,"op":"upsert","entity":"facts","id":"facts","body":\(stopped)}]}
        """
        let state = TimelineFollower.apply(try NetworkFleetMirror.decodeTimeline(Data(reply.utf8)), to: start)
        XCTAssertTrue(state.timeline.messages.isEmpty)
        XCTAssertEqual(state.facts?.status.rawValue, "stopped")
    }
}
