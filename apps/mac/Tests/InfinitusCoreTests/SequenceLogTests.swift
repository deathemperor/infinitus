import XCTest
@testable import InfinitusCore

final class SequenceLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func turn(_ id: String, _ state: SessionTimeline.Turn.State) -> SessionTimeline.Turn {
        .init(id: id, state: state, requestedAt: t0, startedAt: nil, completedAt: nil, userMessageId: id, assistantMessageId: nil)
    }
    private func msg(_ id: String, _ text: String) -> SessionTimeline.Message {
        .init(id: id, role: .user, text: text, images: nil, sender: nil, turnId: "u1", streaming: false, createdAt: t0)
    }

    func testFirstRecordUpsertsEverythingInOrder() {
        let log = SequenceLog(epoch: "e1")
        let tl = SessionTimeline(turns: [turn("u1", .running)], messages: [msg("u1", "hi")])
        XCTAssertEqual(log.record(pid: 7, old: nil, new: tl), 2)
        let events = log.events(pid: 7, after: 0)
        XCTAssertEqual(events?.map(\.sequence), [1, 2])
        XCTAssertEqual(events?.map(\.entity), [.turn, .message])
        XCTAssertEqual(events?.first?.body?.objectValue?["state"]?.stringValue, "running")
        XCTAssertEqual(log.current, 2)
    }

    func testOnlyChangedEntitiesAndTombstonesAreEmitted() {
        let log = SequenceLog(epoch: "e1")
        let a = SessionTimeline(turns: [turn("u1", .running)], messages: [msg("u1", "hi"), msg("a1", "…")])
        _ = log.record(pid: 7, old: nil, new: a)
        let b = SessionTimeline(turns: [turn("u1", .completed)], messages: [msg("u1", "hi")])
        XCTAssertEqual(log.record(pid: 7, old: a, new: b), 2)
        let tail = log.events(pid: 7, after: 3)
        XCTAssertEqual(tail?.map { "\($0.op.rawValue):\($0.entity.rawValue):\($0.id)" },
                       ["upsert:turn:u1", "tombstone:message:a1"])
        XCTAssertNil(tail?.last?.body)
    }

    func testFactsRowOnlyWhenChanged() {
        let log = SequenceLog(epoch: "e1")
        let f = SessionFacts.derive(timeline: .init(), status: "idle", attention: .init())
        XCTAssertTrue(log.record(pid: 7, facts: f))
        XCTAssertFalse(log.record(pid: 7, facts: f))
        XCTAssertEqual(log.events(pid: 7, after: 0)?.map(\.id), ["facts"])
    }

    func testEventsAfterCurrentIsEmptyAndBeyondTheBufferIsNil() {
        let log = SequenceLog(epoch: "e1", maxEvents: 3)
        for i in 1...5 {
            _ = log.record(pid: 7, old: nil, new: .init(messages: [msg("m\(i)", "x")]))
        }
        XCTAssertEqual(log.current, 5)
        XCTAssertEqual(log.events(pid: 7, after: 5), [])
        XCTAssertEqual(log.events(pid: 7, after: 2)?.map(\.sequence), [3, 4, 5])
        XCTAssertNil(log.events(pid: 7, after: 1))
    }

    func testByteCapEvictsOldestAndDropForgetsAPid() {
        let log = SequenceLog(epoch: "e1", maxBytes: 300)
        for i in 1...4 {
            _ = log.record(pid: 7, old: nil, new: .init(messages: [msg("m\(i)", String(repeating: "x", count: 100))]))
        }
        XCTAssertNil(log.events(pid: 7, after: 0))
        XCTAssertNotNil(log.events(pid: 7, after: 3))
        log.drop(pid: 7)
        XCTAssertNil(log.events(pid: 7, after: 3))
        XCTAssertEqual(log.events(pid: 7, after: log.current), [])
    }

    func testSequencesAreGlobalAcrossPids() {
        let log = SequenceLog(epoch: "e1")
        _ = log.record(pid: 1, old: nil, new: .init(messages: [msg("a", "x")]))
        _ = log.record(pid: 2, old: nil, new: .init(messages: [msg("b", "x")]))
        XCTAssertEqual(log.events(pid: 2, after: 0)?.map(\.sequence), [2])
        XCTAssertEqual(log.events(pid: 2, after: 1)?.map(\.sequence), [2])
    }
}
