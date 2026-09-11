import XCTest
@testable import InfinitusCore

final class OutboxTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func request(_ text: String) -> SessionInput.Request {
        SessionInput.Request(kind: .message, text: text)
    }

    func testEnqueueMergesIntoOneItemPerSession() throws {
        let box = Outbox(root: root)
        let first = try box.enqueue(macKey: "m", pid: 4, sessionId: "s", sessionName: "repo",
                                    request: request("one"), now: t0)
        let second = try box.enqueue(macKey: "m", pid: 4, sessionId: "s", sessionName: "repo",
                                     request: request("two"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.request.text, "one\n\ntwo")
        XCTAssertNotEqual(first.request.requestId, second.request.requestId)
        XCTAssertEqual(second.request.sessionId, "s")
        XCTAssertEqual(second.updatedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(box.items(macKey: "m").count, 1)
        _ = try box.enqueue(macKey: "m", pid: 5, sessionId: nil, sessionName: "other",
                            request: request("x"), now: t0)
        XCTAssertEqual(box.items(macKey: "m").map(\.pid), [4, 5])
        XCTAssertEqual(box.items(macKey: "other-mac").count, 0)
    }

    func testEnqueueKeepsAnIncomingRequestId() throws {
        let box = Outbox(root: root)
        let request = SessionInput.Request(kind: .message, text: "one", requestId: "already-sent")
        let item = try box.enqueue(macKey: "m", pid: 4, sessionId: "s", sessionName: "repo",
                                   request: request, now: t0)
        XCTAssertEqual(item.request.requestId, "already-sent")
    }

    func testReplaceAndRemove() throws {
        let box = Outbox(root: root)
        let item = try box.enqueue(macKey: "m", pid: 4, sessionId: "s", sessionName: "repo",
                                   request: request("one"), now: t0)
        try box.replace(id: item.id, request: request("edited"), now: t0.addingTimeInterval(1))
        XCTAssertEqual(box.items(macKey: "m").first?.request.text, "edited")
        XCTAssertNotNil(box.items(macKey: "m").first?.request.requestId)
        box.remove(id: item.id)
        XCTAssertEqual(box.items(macKey: "m").count, 0)
    }

    func testFlushStateMachine() async throws {
        let box = Outbox(root: root)
        let a = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("a"), now: t0)
        let b = try box.enqueue(macKey: "m", pid: 2, sessionId: nil, sessionName: "b", request: request("b"), now: t0.addingTimeInterval(1))
        let c = try box.enqueue(macKey: "m", pid: 3, sessionId: nil, sessionName: "c", request: request("c"), now: t0.addingTimeInterval(2))
        let d = try box.enqueue(macKey: "m", pid: 4, sessionId: nil, sessionName: "d", request: request("d"), now: t0.addingTimeInterval(3))
        var seenInFlight: [UUID] = []
        let results = await box.flush(macKey: "m", now: t0.addingTimeInterval(10)) { item in
            // inFlight must already be on disk when deliver runs
            if box.items(macKey: "m").first(where: { $0.id == item.id })?.state == .inFlight {
                seenInFlight.append(item.id)
            }
            switch item.pid {
            case 1: return .delivered
            case 2: return .refused("noSurface — no terminal")
            case 3: return .ended
            default: return .transport
            }
        }
        XCTAssertEqual(seenInFlight, [a.id, b.id, c.id, d.id])
        XCTAssertEqual(results.map(\.id), [a.id, b.id, c.id, d.id])
        let left = box.items(macKey: "m")
        XCTAssertEqual(left.map(\.pid), [2, 3, 4])                 // a removed
        XCTAssertEqual(left[0].state, .refused("noSurface — no terminal"))
        XCTAssertEqual(left[1].state, .ended)
        XCTAssertEqual(left[2].state, .queued)
        XCTAssertEqual(left[2].attempts, 1)
        XCTAssertEqual(left[2].request.queuedAt, t0.addingTimeInterval(3))   // updatedAt of d
    }

    func testTransportStopsThePass() async throws {
        let box = Outbox(root: root)
        _ = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("a"), now: t0)
        _ = try box.enqueue(macKey: "m", pid: 2, sessionId: nil, sessionName: "b", request: request("b"), now: t0.addingTimeInterval(1))
        var delivered: [Int32] = []
        _ = await box.flush(macKey: "m", now: t0) { item in delivered.append(item.pid); return .transport }
        XCTAssertEqual(delivered, [1])
        XCTAssertEqual(box.items(macKey: "m").map(\.state), [.queued, .queued])
    }

    func testRefusedAndEndedItemsAreSkippedAndInFlightRetriesSameId() async throws {
        let box = Outbox(root: root)
        let a = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("a"), now: t0)
        _ = await box.flush(macKey: "m", now: t0) { _ in .refused("no") }
        var calls = 0
        _ = await box.flush(macKey: "m", now: t0) { _ in calls += 1; return .delivered }
        XCTAssertEqual(calls, 0)
        // simulate a crash mid-send: an inFlight item on disk
        var stuck = box.items(macKey: "m")[0]
        stuck.state = .inFlight
        try box.save(stuck)
        let id = stuck.request.requestId
        var seen: String?
        _ = await box.flush(macKey: "m", now: t0) { item in seen = item.request.requestId; return .delivered }
        XCTAssertEqual(seen, id)
        XCTAssertEqual(box.items(macKey: "m").count, 0)
        _ = a
    }

    func testMergeDuringFlightSurvivesDelivery() async throws {
        let box = Outbox(root: root)
        _ = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("one"), now: t0)
        var deliveredId: String?
        let results = await box.flush(macKey: "m", now: t0) { item in
            deliveredId = item.request.requestId
            // A second message lands on the same session while this one is
            // in flight — it must not be lost when the first is delivered.
            _ = try? box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a",
                                 request: request("two"), now: t0.addingTimeInterval(1))
            return .delivered
        }
        XCTAssertEqual(results.map(\.delivery), [.delivered])
        let left = box.items(macKey: "m")
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0].state, .queued)
        XCTAssertEqual(left[0].request.text, "two")
        XCTAssertNotNil(deliveredId)
        XCTAssertNotEqual(left[0].request.requestId, deliveredId)
    }

    func testDiscardDuringFlightIsNotResurrected() async throws {
        let box = Outbox(root: root)
        let item = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("one"), now: t0)
        let results = await box.flush(macKey: "m", now: t0) { _ in
            // The user discards the message while it's in flight.
            box.remove(id: item.id)
            return .transport
        }
        XCTAssertEqual(results.map(\.delivery), [.transport])
        XCTAssertEqual(box.items(macKey: "m").count, 0)
    }

    func testMergeBeforeMarkInFlightIsNotClobbered() async throws {
        let box = Outbox(root: root)
        _ = try box.enqueue(macKey: "m", pid: 1, sessionId: nil, sessionName: "a", request: request("a"), now: t0)
        _ = try box.enqueue(macKey: "m", pid: 2, sessionId: nil, sessionName: "b", request: request("b"), now: t0.addingTimeInterval(1))
        var seen: [String] = []
        _ = await box.flush(macKey: "m", now: t0) { item in
            // While pid 1 is in flight, a message lands on pid 2 — after
            // the pass's `items()` snapshot, before pid 2 is marked in
            // flight. The mark-in-flight step must reload fresh under
            // the lock rather than trust that snapshot.
            if item.pid == 1 {
                _ = try? box.enqueue(macKey: "m", pid: 2, sessionId: nil, sessionName: "b",
                                     request: request("two"), now: t0.addingTimeInterval(2))
            }
            seen.append(item.request.text)
            return .delivered
        }
        XCTAssertEqual(seen, ["a", "b\n\ntwo"])
        XCTAssertEqual(box.items(macKey: "m").count, 0)
    }
}
