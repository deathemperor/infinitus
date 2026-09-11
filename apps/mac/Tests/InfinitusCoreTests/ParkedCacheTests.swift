import XCTest
@testable import InfinitusCore

final class ParkedCacheTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parked-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func snapshot(at seconds: TimeInterval) -> MirrorSnapshot {
        MirrorSnapshot(capturedAt: Date(timeIntervalSince1970: seconds), machineName: "mac",
                       listJSON: Data("{}".utf8), sessions: [])
    }

    private func feed(stamp: String) -> SessionFeed {
        SessionFeed(pid: 4, sessionId: "s", cwd: "/w", status: "idle", waiting: false,
                    items: [], name: "w", stamp: stamp)
    }

    func testSnapshotRoundTrip() throws {
        let cache = ParkedCache(root: root)
        XCTAssertNil(cache.loadSnapshot())
        try cache.saveSnapshot(snapshot(at: 10))
        XCTAssertEqual(cache.loadSnapshot()?.capturedAt, Date(timeIntervalSince1970: 10))
    }

    func testUnchangedCapturedAtDoesNotRewrite() throws {
        let cache = ParkedCache(root: root)
        try cache.saveSnapshot(snapshot(at: 10))
        let file = root.appendingPathComponent("snapshot.json")
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        try cache.saveSnapshot(snapshot(at: 10))
        let second = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(first, second)
        try cache.saveSnapshot(snapshot(at: 11))
        XCTAssertEqual(cache.loadSnapshot()?.capturedAt, Date(timeIntervalSince1970: 11))
    }

    func testTailRoundTripAndClear() throws {
        let cache = ParkedCache(root: root)
        XCTAssertNil(cache.loadTail(pid: 4))
        try cache.saveTail(feed(stamp: "a"), pid: 4)
        XCTAssertEqual(cache.loadTail(pid: 4)?.stamp, "a")
        try cache.saveTail(feed(stamp: "b"), pid: 4)
        XCTAssertEqual(cache.loadTail(pid: 4)?.stamp, "b")
        cache.clear()
        XCTAssertNil(cache.loadTail(pid: 4))
        XCTAssertNil(cache.loadSnapshot())
    }

    func testCorruptFileIsSkipped() throws {
        let cache = ParkedCache(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: root.appendingPathComponent("snapshot.json"))
        XCTAssertNil(cache.loadSnapshot())
    }
}
