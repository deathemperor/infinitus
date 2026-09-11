import XCTest
@testable import InfinitusCore

final class TokenRatesTests: XCTestCase {
    private var dir: URL!
    // Real clock: the scanner skips transcripts whose mtime predates the week.
    private let now = Date().timeIntervalSince1970

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-rates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func stamp(_ t: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }
    private func line(_ t: Double, id: String, model: String = "claude-fable-5",
                      input: Int = 10, output: Int = 100, read: Int = 1000, write: Int = 500) -> String {
        """
        {"type":"assistant","timestamp":"\(stamp(t))","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(read),"cache_creation_input_tokens":\(write)},"content":[{"type":"text","text":"x"}]}}
        """
    }
    private var file: URL { dir.appendingPathComponent("proj/session.jsonl") }
    private var cacheURL: URL { dir.appendingPathComponent("cache.json") }

    func testCountsTurnsOncePricesThemAndWindowsThem() throws {
        let lines = [
            #"{"type":"user","timestamp":"\#(stamp(now - 60))","message":{"role":"user","content":"hi"}}"#,
            line(now - 120, id: "m1"),                 // last hour
            line(now - 119, id: "m1"),                 // same turn, second block
            line(now - 3 * 3600, id: "m2"),            // last day
            line(now - 2 * 86_400, id: "m3", model: "claude-mystery-9"),  // last week, unpriced
            line(now - 10 * 86_400, id: "m4"),         // outside the week
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let r = TokenRateScanner.scan(projectsDir: dir, cacheURL: cacheURL, now: now)
        XCTAssertEqual(r.files, 1)
        XCTAssertEqual(r.lastHour.messages, 1)
        XCTAssertEqual(r.lastHour.tokens, 1610)
        // fable: 10*10 + 100*50 + 1000*1 + 500*12.5 = 12350 / 1e6
        XCTAssertEqual(r.lastHour.usd, 0.01235, accuracy: 1e-9)
        XCTAssertEqual(r.lastDay.messages, 2)
        XCTAssertEqual(r.lastWeek.messages, 3)
        XCTAssertEqual(r.lastWeek.usd, 0.0247, accuracy: 1e-9, "the unpriced turn adds tokens, not dollars")
        XCTAssertEqual(r.lastWeek.tokens, 3 * 1610)
        XCTAssertEqual(r.unpricedModels, ["claude-mystery-9"])
    }

    func testIncrementalAppendParsesOnlyNewBytesAndWaitsForPartialLines() throws {
        try (line(now - 100, id: "m1") + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = TokenRateScanner.scan(projectsDir: dir, cacheURL: cacheURL, now: now)
        // Append one complete turn and a half-written one.
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        let partial = line(now - 30, id: "m3")
        try h.write(contentsOf: Data((line(now - 50, id: "m2") + "\n" + String(partial.prefix(40))).utf8))
        try h.close()
        var r = TokenRateScanner.scan(projectsDir: dir, cacheURL: cacheURL, now: now)
        XCTAssertEqual(r.lastHour.messages, 2)
        // Finish the partial line → picked up next pass, nothing double-counted.
        let h2 = try FileHandle(forWritingTo: file)
        try h2.seekToEnd()
        try h2.write(contentsOf: Data((String(partial.dropFirst(40)) + "\n").utf8))
        try h2.close()
        r = TokenRateScanner.scan(projectsDir: dir, cacheURL: cacheURL, now: now)
        XCTAssertEqual(r.lastHour.messages, 3)
        // Same size → served from the cache untouched.
        r = TokenRateScanner.scan(projectsDir: dir, cacheURL: cacheURL, now: now)
        XCTAssertEqual(r.lastHour.messages, 3)
    }
}
