import XCTest
@testable import InfinitusCore

/// `SessionTail` (#346): the first read is `SessionProgress.read`'s tail,
/// every later one only the bytes appended since.
final class SessionTailTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/-p"), withIntermediateDirectories: true)
        url = Transcript.path(cwd: "/p", sessionId: "s", claudeDir: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func user(_ text: String) -> String {
        #"{"type":"user","timestamp":"2026-09-01T09:59:00.000Z","message":{"content":"\#(text)"}}"#
    }

    private func read(_ file: String, tokens: Int, at: String = "2026-09-01T10:00:00.000Z") -> String {
        #"{"type":"assistant","timestamp":"\#(at)","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/\#(file)"}}],"usage":{"output_tokens":\#(tokens)}}}"#
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testFirstAdvanceIsTheReadAndLaterOnesTakeOnlyTheAppendedLines() throws {
        try (user("Fix the flaky test") + "\n" + read("Foo.swift", tokens: 3) + "\n").write(to: url, atomically: true, encoding: .utf8)
        var tail = SessionTail(url: url)
        XCTAssertTrue(tail.advance())
        let whole = SessionProgress.read(sessionId: "s", cwd: "/p", claudeDir: dir)
        let first = tail.progress()
        XCTAssertEqual(first.nowDoing, whole.nowDoing)
        XCTAssertEqual(first.outputTokens, 3)
        XCTAssertEqual(first.goal, "Fix the flaky test")
        XCTAssertFalse(tail.advance(), "nothing appended")

        try append(read("Bar.swift", tokens: 5, at: "2026-09-01T10:01:00.000Z") + "\n")
        XCTAssertTrue(tail.advance())
        XCTAssertEqual(tail.entries.count, 3)
        let next = tail.progress()
        XCTAssertEqual(next.nowDoing, "Reading Bar.swift")
        XCTAssertEqual(next.outputTokens, 8)
        XCTAssertEqual(next.lastActivityAt, UsageHistory.parseISO("2026-09-01T10:01:00.000Z"))
        XCTAssertEqual(next.goal, "Fix the flaky test")
    }

    func testAPartialTrailingLineWaitsForItsNewline() throws {
        try (user("Go") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var tail = SessionTail(url: url)
        XCTAssertTrue(tail.advance())
        let offset = tail.offset
        let line = read("Foo.swift", tokens: 2)
        try append(String(line.prefix(40)))
        XCTAssertFalse(tail.advance())
        XCTAssertEqual(tail.offset, offset)
        try append(String(line.dropFirst(40)) + "\n")
        XCTAssertTrue(tail.advance())
        XCTAssertEqual(tail.progress().outputTokens, 2)
    }

    func testTheWindowDropsTheOldestEntriesAndAFirstReadStartsAtTheLastMaxBytes() throws {
        let lines = (1...6).map { read("f\($0).swift", tokens: $0) }
        let lineBytes = lines[0].utf8.count + 1
        try (user("Go") + "\n" + lines.prefix(4).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        // Room for two whole lines: the first read lands mid-line three,
        // whose torn remainder is skipped like `read` skips it.
        var tail = SessionTail(url: url, maxBytes: lineBytes * 2 + 10)
        XCTAssertTrue(tail.advance())
        XCTAssertEqual(tail.entries.count, 2)
        XCTAssertEqual(tail.progress().outputTokens, 3 + 4)
        XCTAssertEqual(tail.progress().goal, "Go", "the goal comes from the head, outside the window")

        try append(lines[4] + "\n" + lines[5] + "\n")
        XCTAssertTrue(tail.advance())
        XCTAssertEqual(tail.entries.count, 2)
        XCTAssertEqual(tail.progress().outputTokens, 5 + 6)
        XCTAssertEqual(tail.progress().nowDoing, "Reading f6.swift")
    }

    func testAShrunkFileStartsOver() throws {
        try (user("Old goal") + "\n" + read("Foo.swift", tokens: 3) + "\n" + read("Bar.swift", tokens: 4) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        var tail = SessionTail(url: url)
        XCTAssertTrue(tail.advance())
        XCTAssertEqual(tail.progress().outputTokens, 7)
        try (user("New goal") + "\n" + read("Baz.swift", tokens: 1) + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(tail.advance())
        XCTAssertEqual(tail.entries.count, 2)
        XCTAssertEqual(tail.progress().outputTokens, 1)
        XCTAssertEqual(tail.progress().goal, "New goal")
    }

    func testAMissingFileIsNoProgressUntilItAppears() throws {
        var tail = SessionTail(url: url)
        XCTAssertFalse(tail.advance())
        XCTAssertNil(tail.progress().lastActivityAt)
        try (user("Go") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(tail.advance())
        XCTAssertEqual(tail.progress().goal, "Go")
    }
}
