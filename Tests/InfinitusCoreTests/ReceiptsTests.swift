import XCTest
@testable import InfinitusCore

final class ReceiptsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstCallIsAMissThenInFlightThenAHit() {
        let r = Receipts()
        XCTAssertEqual(r.begin(commandId: "c1", target: "/sessions/7/input", pid: 7, now: t0), .miss)
        XCTAssertEqual(r.begin(commandId: "c1", target: "/sessions/7/input", pid: 7, now: t0), .inFlight)
        r.finish(commandId: "c1", reply: Data("ok".utf8), now: t0)
        XCTAssertEqual(r.begin(commandId: "c1", target: "/sessions/7/input", pid: 7, now: t0 + 1), .hit(Data("ok".utf8)))
    }

    func testSameIdDifferentTargetConflicts() {
        let r = Receipts()
        _ = r.begin(commandId: "c1", target: "/sessions/7/input", pid: 7, now: t0)
        r.finish(commandId: "c1", reply: Data(), now: t0)
        XCTAssertEqual(r.begin(commandId: "c1", target: "/sessions/8/input", pid: 8, now: t0), .conflict)
    }

    func testAbandonLetsARetryRunAgain() {
        let r = Receipts()
        _ = r.begin(commandId: "c1", target: "t", pid: 7, now: t0)
        r.abandon(commandId: "c1")
        XCTAssertEqual(r.begin(commandId: "c1", target: "t", pid: 7, now: t0), .miss)
    }

    func testTombstoneStopsAPidsRetriesAndDropForgetsThem() {
        let r = Receipts()
        _ = r.begin(commandId: "c1", target: "t", pid: 7, now: t0); r.finish(commandId: "c1", reply: Data(), now: t0)
        _ = r.begin(commandId: "c2", target: "t", pid: 7, now: t0)
        r.tombstone(pid: 7)
        XCTAssertEqual(r.begin(commandId: "c1", target: "t", pid: 7, now: t0), .tombstoned)
        XCTAssertEqual(r.begin(commandId: "c2", target: "t", pid: 7, now: t0), .tombstoned)
        r.drop(pid: 7)
        XCTAssertEqual(r.begin(commandId: "c1", target: "t", pid: 7, now: t0), .miss)
    }

    func testTTLAndCapExpireOldReceipts() {
        let r = Receipts(cap: 2, ttl: 60)
        _ = r.begin(commandId: "old", target: "t", pid: 1, now: t0); r.finish(commandId: "old", reply: Data(), now: t0)
        XCTAssertEqual(r.begin(commandId: "old", target: "t", pid: 1, now: t0 + 61), .miss)
        r.finish(commandId: "old", reply: Data(), now: t0 + 61)
        _ = r.begin(commandId: "b", target: "t", pid: 1, now: t0 + 62); r.finish(commandId: "b", reply: Data(), now: t0 + 62)
        _ = r.begin(commandId: "c", target: "t", pid: 1, now: t0 + 63); r.finish(commandId: "c", reply: Data(), now: t0 + 63)
        XCTAssertEqual(r.begin(commandId: "old", target: "t", pid: 1, now: t0 + 64), .miss)   // evicted by the cap
        XCTAssertEqual(r.begin(commandId: "c", target: "t", pid: 1, now: t0 + 64), .hit(Data()))
    }

    func testServeRunsOnceReplaysA200AndForgetsTheRest() {
        let r = Receipts()
        let ok = MirrorTransport.jsonResponse(Data("{}".utf8))
        var runs = 0
        XCTAssertEqual(r.serve(commandId: "c1", target: "t", pid: 7) { runs += 1; return ok }, ok)
        XCTAssertEqual(r.serve(commandId: "c1", target: "t", pid: 7) { runs += 1; return ok }, ok)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(r.serve(commandId: "c1", target: "u", pid: 7) { ok }.prefix(12), Data("HTTP/1.1 409".utf8))
        // A non-200 reply is not kept: the retry runs again.
        let refused = MirrorTransport.conflictResponse(Data())
        XCTAssertEqual(r.serve(commandId: "c2", target: "t", pid: 7) { runs += 1; return refused }, refused)
        XCTAssertEqual(r.serve(commandId: "c2", target: "t", pid: 7) { runs += 1; return refused }, refused)
        XCTAssertEqual(runs, 3)
        // Nil is the route's 404, and it is not kept either.
        XCTAssertEqual(r.serve(commandId: "c3", target: "t", pid: 7) { nil }, MirrorTransport.notFoundResponse())
        XCTAssertEqual(r.begin(commandId: "c3", target: "t", pid: 7), .miss)
        // Without a commandId there is no receipt at all.
        XCTAssertEqual(r.serve(commandId: nil, target: "t", pid: 7) { runs += 1; return ok }, ok)
        XCTAssertEqual(r.serve(commandId: nil, target: "t", pid: 7) { runs += 1; return ok }, ok)
        XCTAssertEqual(runs, 5)
        r.tombstone(pid: 7)
        XCTAssertEqual(r.serve(commandId: "c1", target: "t", pid: 7) { ok }.prefix(12), Data("HTTP/1.1 410".utf8))
    }

    func testRequestsDecodeCommandId() throws {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(SessionInput.Request.self, from: Data(#"{"kind":"message","text":"hi","commandId":"c1"}"#.utf8)).commandId, "c1")
        XCTAssertEqual(try dec.decode(SessionStart.Request.self, from: Data(#"{"cwd":"/x","commandId":"c2"}"#.utf8)).commandId, "c2")
        XCTAssertEqual(try dec.decode(SessionAttention.Request.self, from: Data(#"{"action":"pin","commandId":"c3"}"#.utf8)).commandId, "c3")
        XCTAssertNil(try dec.decode(SessionInput.Request.self, from: Data(#"{"kind":"message","text":"hi"}"#.utf8)).commandId)
    }
}
