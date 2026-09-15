import XCTest
@testable import InfinitusCore

final class TeamChunkerTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamchunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testPacksCompleteLinesIntoBoundedChunks() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        try "aaaa\nbbbb\ncccc\ndddd\neeee\n".write(to: file, atomically: true, encoding: .utf8)   // 5 lines × 5 bytes
        let (chunks, offset) = try TeamChunker.chunks(of: file, from: 0, maxBytes: 12, redact: { $0 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF8.self) }, ["aaaa\nbbbb\n", "cccc\ndddd\n", "eeee\n"])
        XCTAssertEqual(offset, 25)
        // Nothing new: no chunks, same offset.
        let again = try TeamChunker.chunks(of: file, from: offset, maxBytes: 12, redact: { $0 })
        XCTAssertEqual(again.chunks, [])
        XCTAssertEqual(again.offset, 25)
    }

    func testPartialTrailingLineWaitsAndRedactionApplies() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        try "one secret\ntwo".write(to: file, atomically: true, encoding: .utf8)
        let first = try TeamChunker.chunks(of: file, from: 0, redact: { $0.replacingOccurrences(of: "secret", with: "[x]") })
        XCTAssertEqual(first.chunks.map { String(decoding: $0, as: UTF8.self) }, ["one [x]\n"])
        XCTAssertEqual(first.offset, 11)   // the unterminated "two" is not consumed
        try FileHandle(forWritingTo: file).seekToEndAndWrite(Data(" done\n".utf8))
        let second = try TeamChunker.chunks(of: file, from: first.offset, redact: { $0 })
        XCTAssertEqual(second.chunks.map { String(decoding: $0, as: UTF8.self) }, ["two done\n"])
        XCTAssertEqual(second.offset, 20)
    }

    func testOversizedLineIsItsOwnChunk() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        let big = String(repeating: "x", count: 40)
        try "ab\n\(big)\ncd\n".write(to: file, atomically: true, encoding: .utf8)
        let (chunks, _) = try TeamChunker.chunks(of: file, from: 0, maxBytes: 10, redact: { $0 })
        XCTAssertEqual(chunks.map { $0.count }, [3, 41, 3])
    }

    func testReadCapSlicesAcrossCalls() throws {
        let file = scratch.appendingPathComponent("t.jsonl")
        try "aaaa\nbbbb\ncccc\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try TeamChunker.chunks(of: file, from: 0, readCap: 7, redact: { $0 })
        XCTAssertEqual(first.chunks.map { String(decoding: $0, as: UTF8.self) }, ["aaaa\n"])
        XCTAssertEqual(first.offset, 5)
        let second = try TeamChunker.chunks(of: file, from: first.offset, readCap: 100, redact: { $0 })
        XCTAssertEqual(second.chunks.map { String(decoding: $0, as: UTF8.self) }, ["bbbb\ncccc\n"])
    }

    func testMissingFileYieldsNothing() throws {
        let r = try TeamChunker.chunks(of: scratch.appendingPathComponent("nope.jsonl"), from: 3, redact: { $0 })
        XCTAssertEqual(r.chunks, []); XCTAssertEqual(r.offset, 3)
    }

    func testPublishStateRoundTrips() throws {
        let teamDir = scratch.appendingPathComponent("team")
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir), TeamPublishState())
        var s = TeamPublishState()
        s.transcripts["s1"] = TeamPublishState.Cursor(seq: 2, offset: 4096)
        s.hashes["days/2026-09-04.json"] = "abc"
        try s.save(teamDir: teamDir)
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir), s)
    }
}

private extension FileHandle {
    func seekToEndAndWrite(_ data: Data) throws {
        try seekToEnd()
        try write(contentsOf: data)
        try close()
    }
}
