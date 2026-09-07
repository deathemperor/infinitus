import XCTest
@testable import InfinitusCore

final class SessionAttentionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var store: AttentionStore!
    private var url: URL!
    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("attn-\(UUID().uuidString)/a.json")
        store = AttentionStore(url: url)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    private var waiting: SessionTimeline {
        .init(turns: [.init(id: "u1", state: .running, requestedAt: t0, startedAt: t0, completedAt: nil,
                            userMessageId: "u1", assistantMessageId: nil)],
              activities: [.init(id: "perm:a", tone: .approval, kind: "approval.requested", summary: "Bash", detail: nil,
                                 payload: ["requestId": .string("perm:a"), "toolName": .string("Bash")],
                                 turnId: "u1", sequence: 0, createdAt: t0)])
    }

    func testSettleAppliesAndAnswersWithFreshFacts() {
        let out = SessionAttention.apply(.init(action: .settle, until: nil), sessionId: "s1", timeline: .init(),
                                         status: "idle", store: store, now: t0)
        guard case .applied(let facts) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(facts.settledOverride, .settled)
        XCTAssertEqual(facts.settledAt, t0)
        XCTAssertEqual(facts.status, .idle)
        XCTAssertEqual(store.entry(sessionId: "s1").settledAt, t0)
    }

    func testSnoozeRefusesWhileWaitingOnYou() {
        // T3 decider.ts 626-640: "has a pending approval or user-input
        // request and cannot be snoozed".
        let out = SessionAttention.apply(.init(action: .snooze, until: t0 + 60), sessionId: "s1", timeline: waiting,
                                         status: "waiting", store: store, now: t0)
        XCTAssertEqual(out, .refused("waiting"))
        XCTAssertNil(store.entry(sessionId: "s1").snoozedUntil)
    }

    func testSnoozeNeedsAFutureUntil() {
        // T3 decider.ts 618-624: snoozedUntil must be after now.
        XCTAssertEqual(SessionAttention.apply(.init(action: .snooze, until: nil), sessionId: "s1", timeline: .init(),
                                              status: "idle", store: store, now: t0), .badRequest)
        XCTAssertEqual(SessionAttention.apply(.init(action: .snooze, until: t0), sessionId: "s1", timeline: .init(),
                                              status: "idle", store: store, now: t0), .badRequest)
        guard case .applied(let facts) = SessionAttention.apply(.init(action: .snooze, until: t0 + 1), sessionId: "s1",
                                                                timeline: .init(), status: "idle", store: store, now: t0)
        else { return XCTFail("future until should apply") }
        XCTAssertEqual(facts.snoozedUntil, t0 + 1)
    }

    func testRequestDecodesWithoutUntilAndWithACommandId() throws {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(SessionAttention.Request.self, from: Data(#"{"action":"pin"}"#.utf8)),
                       .init(action: .pin, until: nil))
        XCTAssertEqual(try dec.decode(SessionAttention.Request.self, from: Data(#"{"action":"pin","commandId":"c1"}"#.utf8)),
                       .init(action: .pin, until: nil, commandId: "c1"))
    }
}
