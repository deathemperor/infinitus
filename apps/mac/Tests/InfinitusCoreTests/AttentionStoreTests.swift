import XCTest
@testable import InfinitusCore

/// Rules are T3's (`apps/server/src/orchestration/decider.ts` and
/// `projector.ts`, t3code acc0a219e), cited per test.
final class AttentionStoreTests: XCTestCase {
    private var url: URL!
    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-\(UUID().uuidString)/attention.json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingFileReadsAsEmpty() {
        XCTAssertEqual(AttentionStore(url: url).entry(sessionId: "s1"), .init())
    }

    func testSettlePersistsAcrossInstances() {
        AttentionStore(url: url).apply(.settle, sessionId: "s1", until: nil, now: t0)
        let again = AttentionStore(url: url).entry(sessionId: "s1")
        XCTAssertEqual(again.settledOverride, .settled)
        XCTAssertEqual(again.settledAt, t0)
    }

    func testSettleKeepsTheFirstSettledAtAndClearsPinAndSnooze() {
        // decider.ts 493-515: re-settle keeps settledAt; 544-575: settle
        // emits unpinned + unsnoozed.
        let store = AttentionStore(url: url)
        store.apply(.pin, sessionId: "s1", until: nil, now: t0)
        store.apply(.snooze, sessionId: "s1", until: t0 + 3600, now: t0)
        store.apply(.settle, sessionId: "s1", until: nil, now: t0 + 1)
        let e = store.apply(.settle, sessionId: "s1", until: nil, now: t0 + 2)
        XCTAssertEqual(e, .init(settledOverride: .settled, settledAt: t0 + 1))
    }

    func testUnsettleMarksActiveAndStampsReentryOnce() {
        // projector.ts 416-436: override "active", settledAt null,
        // unsettledAt = now unless already active.
        let store = AttentionStore(url: url)
        store.apply(.settle, sessionId: "s1", until: nil, now: t0)
        let first = store.apply(.unsettle, sessionId: "s1", until: nil, now: t0 + 1)
        XCTAssertEqual(first, .init(settledOverride: .active, unsettledAt: t0 + 1))
        let second = store.apply(.unsettle, sessionId: "s1", until: nil, now: t0 + 2)
        XCTAssertEqual(second.unsettledAt, t0 + 1)
    }

    func testSnoozeStoresUntilAndFirstSnoozedAtAndUnsnoozeClearsBoth() {
        // decider.ts 650-669: re-snooze keeps snoozedAt.
        let store = AttentionStore(url: url)
        let e1 = store.apply(.snooze, sessionId: "s1", until: t0 + 3600, now: t0)
        XCTAssertEqual(e1, .init(snoozedUntil: t0 + 3600, snoozedAt: t0))
        let e2 = store.apply(.snooze, sessionId: "s1", until: t0 + 7200, now: t0 + 10)
        XCTAssertEqual(e2, .init(snoozedUntil: t0 + 7200, snoozedAt: t0))
        XCTAssertEqual(store.apply(.unsnooze, sessionId: "s1", until: nil, now: t0), .init())
    }

    func testPinKeepsTheFirstPinDateAndWakesASettledSnoozedSession() {
        // decider.ts 713 (existing pinnedAt wins), 738-770 (pin un-settles
        // and unsnoozes).
        let store = AttentionStore(url: url)
        store.apply(.settle, sessionId: "s1", until: nil, now: t0)
        store.apply(.snooze, sessionId: "s1", until: t0 + 3600, now: t0)
        let pinned = store.apply(.pin, sessionId: "s1", until: nil, now: t0 + 1)
        XCTAssertEqual(pinned, .init(settledOverride: .active, unsettledAt: t0 + 1, pinnedAt: t0 + 1))
        XCTAssertEqual(store.apply(.pin, sessionId: "s1", until: nil, now: t0 + 60).pinnedAt, t0 + 1)
        XCTAssertNil(store.apply(.unpin, sessionId: "s1", until: nil, now: t0).pinnedAt)
    }

    func testAnEmptyEntryLeavesTheFile() throws {
        let store = AttentionStore(url: url)
        store.apply(.pin, sessionId: "s1", until: nil, now: t0)
        store.apply(.unpin, sessionId: "s1", until: nil, now: t0)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("s1"))
    }

    func testCorruptFileReadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AttentionStore(url: url).entry(sessionId: "s1"), .init())
    }
}
