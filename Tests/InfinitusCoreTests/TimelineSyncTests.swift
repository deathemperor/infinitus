import XCTest
@testable import InfinitusCore

final class TimelineSyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func msg(_ id: String) -> SessionTimeline.Message {
        .init(id: id, role: .user, text: id, images: nil, sender: nil, turnId: "u1", streaming: false, createdAt: t0)
    }
    private var facts: SessionFacts { SessionFacts.derive(timeline: .init(), status: "idle", attention: .init()) }

    func testNoCursorOrForeignEpochGetsASnapshot() {
        let log = SequenceLog(epoch: "e1")
        let tl = SessionTimeline(messages: [msg("a")])
        _ = log.record(pid: 7, old: nil, new: tl)
        let fresh = TimelineSync.reply(log: log, pid: 7, afterSequence: nil, epoch: nil, timeline: tl, facts: facts)
        XCTAssertEqual(fresh.snapshot?.timeline, tl)
        XCTAssertNil(fresh.events)
        XCTAssertEqual(fresh.sequence, 1)
        XCTAssertEqual(fresh.epoch, "e1")
        XCTAssertTrue(fresh.synchronized)
        let foreign = TimelineSync.reply(log: log, pid: 7, afterSequence: 1, epoch: "old-launch", timeline: tl, facts: facts)
        XCTAssertNotNil(foreign.snapshot)
    }

    func testResumableCursorGetsTheEventsAfterIt() {
        let log = SequenceLog(epoch: "e1")
        let a = SessionTimeline(messages: [msg("a")])
        _ = log.record(pid: 7, old: nil, new: a)
        let b = SessionTimeline(messages: [msg("a"), msg("b")])
        _ = log.record(pid: 7, old: a, new: b)
        let r = TimelineSync.reply(log: log, pid: 7, afterSequence: 1, epoch: "e1", timeline: b, facts: facts)
        XCTAssertNil(r.snapshot)
        XCTAssertEqual(r.events?.map(\.id), ["b"])
        XCTAssertEqual(r.sequence, 2)
        let same = TimelineSync.reply(log: log, pid: 7, afterSequence: 2, epoch: "e1", timeline: b, facts: facts)
        XCTAssertEqual(same.events, [])
    }

    func testAGapBeyondTheRingFallsBackToASnapshot() {
        let log = SequenceLog(epoch: "e1", maxEvents: 1)
        var tl = SessionTimeline()
        for i in 1...3 {
            let next = SessionTimeline(messages: tl.messages + [msg("m\(i)")])
            _ = log.record(pid: 7, old: tl, new: next); tl = next
        }
        let r = TimelineSync.reply(log: log, pid: 7, afterSequence: 1, epoch: "e1", timeline: tl, facts: facts)
        XCTAssertNotNil(r.snapshot)
        XCTAssertNil(r.events)
    }

    func testReplyRoundTripsThroughJSON() throws {
        let log = SequenceLog(epoch: "e1")
        let tl = SessionTimeline(messages: [msg("a")])
        _ = log.record(pid: 7, old: nil, new: tl)
        let r = TimelineSync.reply(log: log, pid: 7, afterSequence: 0, epoch: "e1", timeline: tl, facts: facts)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(TimelineSync.self, from: try enc.encode(r)), r)
    }
}
