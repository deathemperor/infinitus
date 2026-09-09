import XCTest
@testable import InfinitusCore

final class FeedTailsTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("feedtails-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func line(_ n: Int) -> String {
        n % 2 == 1
            ? #"{"type":"user","uuid":"u\#(n)","timestamp":"2026-09-01T10:00:\#(String(format: "%02d", n)).000Z","message":{"content":"ask \#(n)"}}"#
            : #"{"type":"assistant","uuid":"a\#(n)","timestamp":"2026-09-01T10:00:\#(String(format: "%02d", n)).000Z","message":{"content":[{"type":"text","text":"answer \#(n)"}]}}"#
    }
    private func write(_ lines: [Int], pid: Int32) throws -> (ClaudeSessionRecord, URL) {
        let record = ClaudeSessionRecord(pid: pid, sessionId: "s\(pid)", cwd: "/tmp/x\(pid)")
        let url = Transcript.path(cwd: record.cwd, sessionId: record.sessionId, claudeDir: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.map(line).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return (record, url)
    }

    func testAHeldTailAnswersLikeAFreshReadAcrossAppends() throws {
        let (record, url) = try write([1, 2, 3, 4], pid: 7)
        let tails = FeedTails()
        XCTAssertEqual(tails.read(record: record, claudeDir: root, limit: 30)?.items.map(\.text),
                       SessionFeedReader.read(record: record, claudeDir: root, limit: 30)?.items.map(\.text))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(5) + "\n" + line(6) + "\n").utf8))
        try handle.close()
        let held = tails.read(record: record, claudeDir: root, limit: 30)
        XCTAssertEqual(held?.items.map(\.text), SessionFeedReader.read(record: record, claudeDir: root, limit: 30)?.items.map(\.text))
        XCTAssertEqual(held?.items.last?.text, "answer 6")
        XCTAssertEqual(held?.timeline, SessionFeedReader.read(record: record, claudeDir: root, limit: 30)?.timeline)
        XCTAssertEqual(tails.held, [7])
    }

    func testOnlyTheNewestPidsKeepATail() throws {
        let tails = FeedTails(cap: 2)
        for pid: Int32 in [1, 2, 3] {
            let (record, _) = try write([1, 2], pid: pid)
            XCTAssertEqual(tails.read(record: record, claudeDir: root, limit: 30)?.items.count, 2)
        }
        XCTAssertEqual(tails.held, [2, 3])
        let (first, _) = try write([1, 2], pid: 1)
        XCTAssertEqual(tails.read(record: first, claudeDir: root, limit: 30)?.items.count, 2, "a dropped pid reads fresh")
        XCTAssertEqual(tails.held, [3, 1])
    }
}
