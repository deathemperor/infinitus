import XCTest
@testable import InfinitusCore

/// The terminal wire's Core frames and routes (#507 step 2): Codable
/// round-trips against upstream's literal field names, NDJSON framing,
/// validation caps, route parsing, the masked log line, history chunking
/// and resume planning. No host — that's step 3.
final class T3TerminalTests: XCTestCase {

    // MARK: - Frame Codable round-trip, field names verbatim

    func testSnapshotFrameFieldNames() throws {
        let frame = T3Terminal.Frame.snapshot(.init(history: "hi", status: .running, sequence: 12,
                                                    exitCode: nil, exitSignal: nil))
        let data = try frame.encodeLine()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "snapshot")
        XCTAssertEqual(object?["history"] as? String, "hi")
        XCTAssertEqual(object?["status"] as? String, "running")
        XCTAssertEqual(object?["sequence"] as? Int, 12)
        XCTAssertNil(object?["exitCode"])
        XCTAssertNil(object?["exitSignal"])
        let decoded = try JSONDecoder().decode(T3Terminal.Frame.self, from: data)
        XCTAssertEqual(decoded, frame)
    }

    func testOutputFrameFieldNames() throws {
        let json = Data(#"{"type":"output","data":"ls -la\n","sequence":42}"#.utf8)
        let frame = try JSONDecoder().decode(T3Terminal.Frame.self, from: json)
        XCTAssertEqual(frame, .output(.init(data: "ls -la\n", sequence: 42)))
        let reencoded = try JSONSerialization.jsonObject(with: frame.encodeLine()) as? [String: Any]
        XCTAssertEqual(reencoded?["data"] as? String, "ls -la\n")
        XCTAssertEqual(reencoded?["sequence"] as? Int, 42)
    }

    func testExitedFrameFieldNames() throws {
        let json = Data(#"{"type":"exited","exitCode":1,"exitSignal":null}"#.utf8)
        let frame = try JSONDecoder().decode(T3Terminal.Frame.self, from: json)
        XCTAssertEqual(frame, .exited(.init(exitCode: 1, exitSignal: nil)))
    }

    func testClosedFrameCarriesReviewRuledReason() throws {
        let withReason = Data(#"{"type":"closed","reason":"backpressure"}"#.utf8)
        let frame = try JSONDecoder().decode(T3Terminal.Frame.self, from: withReason)
        XCTAssertEqual(frame, .closed(.init(reason: T3Terminal.closedReasonBackpressure)))

        let bare = Data(#"{"type":"closed"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(T3Terminal.Frame.self, from: bare), .closed(.init(reason: nil)))
    }

    func testErrorFrameFieldNames() throws {
        let json = Data(#"{"type":"error","message":"shell died"}"#.utf8)
        let frame = try JSONDecoder().decode(T3Terminal.Frame.self, from: json)
        XCTAssertEqual(frame, .error(.init(message: "shell died")))
    }

    // MARK: - NDJSON

    func testEncodeLineEndsInNewlineEvenWhenDataContainsOne() throws {
        let frame = T3Terminal.Frame.output(.init(data: "a\nb", sequence: 1))
        let line = try frame.encodeLine()
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "the payload's embedded \\n must be JSON-escaped, not a second line")
        XCTAssertEqual(line.last, 0x0A)
    }

    func testDecodeLinesSplitsWholeFramesAndKeepsPartialTail() throws {
        let f1 = T3Terminal.Frame.output(.init(data: "one", sequence: 1))
        let f2 = T3Terminal.Frame.output(.init(data: "two", sequence: 2))
        var buffer = try f1.encodeLine()
        buffer.append(try f2.encodeLine())
        // A partial third line with no trailing newline yet.
        let partial = Data(#"{"type":"output","data":"thr"#.utf8)
        buffer.append(partial)

        let (frames, tail) = try T3Terminal.Frame.decodeLines(buffer)
        XCTAssertEqual(frames, [f1, f2])
        XCTAssertEqual(tail, partial)
    }

    func testDecodeLinesReassemblesAcrossAChunkBoundaryMidUTF8Scalar() throws {
        // "café" — é is the 2-byte UTF-8 scalar 0xC3 0xA9; cut the buffer
        // between those two bytes so neither chunk alone is valid UTF-8.
        let frame = T3Terminal.Frame.output(.init(data: "café", sequence: 5))
        let full = try frame.encodeLine()
        guard let leadByteIndex = full.firstIndex(of: 0xC3) else { return XCTFail("é's lead byte not found") }
        let cut = full.distance(from: full.startIndex, to: leadByteIndex) + 1
        let firstChunk = full.prefix(cut)
        let secondChunk = full.suffix(from: cut)

        let (framesA, tailA) = try T3Terminal.Frame.decodeLines(Data(firstChunk))
        XCTAssertEqual(framesA, [])
        XCTAssertEqual(tailA, Data(firstChunk))

        var reassembled = tailA
        reassembled.append(secondChunk)
        let (framesB, tailB) = try T3Terminal.Frame.decodeLines(reassembled)
        XCTAssertEqual(framesB, [frame])
        XCTAssertEqual(tailB, Data())
    }

    func testDecodeLinesSkipsEmptyLinesButThrowsOnGarbage() {
        let buffer = Data("\n{\"type\":\"nonsense\"}\n".utf8)
        XCTAssertThrowsError(try T3Terminal.Frame.decodeLines(buffer))
    }

    // MARK: - Validation caps at the edges

    func testOpenRequestColsRowsCapsAtTheEdges() {
        XCTAssertNil(T3Terminal.OpenRequest(cols: 1, rows: 1).validate())
        XCTAssertNil(T3Terminal.OpenRequest(cols: 500, rows: 200).validate())
        XCTAssertEqual(T3Terminal.OpenRequest(cols: 0, rows: 24).validate(), .colsOutOfRange)
        XCTAssertEqual(T3Terminal.OpenRequest(cols: 501, rows: 24).validate(), .colsOutOfRange)
        XCTAssertEqual(T3Terminal.OpenRequest(cols: 80, rows: 0).validate(), .rowsOutOfRange)
        XCTAssertEqual(T3Terminal.OpenRequest(cols: 80, rows: 201).validate(), .rowsOutOfRange)
    }

    func testResizeRequestSameCaps() {
        XCTAssertNil(T3Terminal.ResizeRequest(cols: 500, rows: 200).validate())
        XCTAssertEqual(T3Terminal.ResizeRequest(cols: 501, rows: 200).validate(), .colsOutOfRange)
        XCTAssertEqual(T3Terminal.ResizeRequest(cols: 500, rows: 201).validate(), .rowsOutOfRange)
    }

    func testWriteRequestByteCapAtTheEdge() {
        let atCap = String(repeating: "x", count: T3Terminal.maxWriteBytes)
        XCTAssertNil(T3Terminal.WriteRequest(data: atCap).validate())
        let overCap = atCap + "x"
        XCTAssertEqual(T3Terminal.WriteRequest(data: overCap).validate(), .dataTooLarge)
    }

    func testWriteRequestCapIsMeasuredInUTF8BytesNotCharacters() {
        // Each "é" is 2 UTF-8 bytes but 1 Character — a naive character
        // count would let this through at half the real byte cost.
        let count = T3Terminal.maxWriteBytes / 2 + 1
        let overCap = String(repeating: "é", count: count)
        XCTAssertEqual(T3Terminal.WriteRequest(data: overCap).validate(), .dataTooLarge)
    }

    // MARK: - Route build / parse round-trip

    private func request(_ target: String) -> MirrorTransport.Request {
        MirrorTransport.Request(method: "GET", target: target, headers: [:])
    }

    func testOpenRoute() {
        let path = T3Terminal.terminalPath(pid: 123)
        XCTAssertEqual(path, "/sessions/123/terminal")
        XCTAssertEqual(T3Terminal.parse(method: "POST", request: request(path)), .open(pid: 123))
        XCTAssertNil(T3Terminal.parse(method: "GET", request: request(path)))
    }

    func testStreamRouteRoundTripWithAndWithoutSince() {
        let path = T3Terminal.terminalStreamPath(pid: 7, id: T3Terminal.defaultTerminalId, since: 99)
        XCTAssertEqual(path, "/sessions/7/terminal/term-1/stream?since=99")
        XCTAssertEqual(T3Terminal.parse(method: "GET", request: request(path)),
                       .stream(pid: 7, id: "term-1", since: 99))

        let noSince = T3Terminal.terminalStreamPath(pid: 7, id: "term-1")
        XCTAssertEqual(noSince, "/sessions/7/terminal/term-1/stream")
        XCTAssertEqual(T3Terminal.parse(method: "GET", request: request(noSince)),
                       .stream(pid: 7, id: "term-1", since: nil))
    }

    func testWriteRoute() {
        let path = T3Terminal.terminalWritePath(pid: 7, id: "term-1")
        XCTAssertEqual(path, "/sessions/7/terminal/term-1/write")
        XCTAssertEqual(T3Terminal.parse(method: "POST", request: request(path)), .write(pid: 7, id: "term-1"))
    }

    func testResizeRoute() {
        let path = T3Terminal.terminalResizePath(pid: 7, id: "term-1")
        XCTAssertEqual(path, "/sessions/7/terminal/term-1/resize")
        XCTAssertEqual(T3Terminal.parse(method: "POST", request: request(path)), .resize(pid: 7, id: "term-1"))
    }

    func testCloseRouteIsDeleteOnTheBareTerminalPathNoSuffix() {
        let path = T3Terminal.terminalClosePath(pid: 7, id: "term-1")
        XCTAssertEqual(path, "/sessions/7/terminal/term-1")
        XCTAssertEqual(T3Terminal.parse(method: "DELETE", request: request(path)), .close(pid: 7, id: "term-1"))
        // Same path, wrong method: not a close.
        XCTAssertNil(T3Terminal.parse(method: "GET", request: request(path)))
    }

    func testUnknownRoutesParseToNil() {
        XCTAssertNil(T3Terminal.parse(method: "GET", request: request("/sessions/abc/terminal")))
        XCTAssertNil(T3Terminal.parse(method: "GET", request: request("/sessions/1/nope")))
    }

    // MARK: - Masked description (#507 review ruling 7)

    func testMaskedDescriptionNeverCarriesTheToken() {
        let target = "/sessions/7/terminal/term-1/stream?since=1&t=super-secret-token"
        let description = T3Terminal.maskedDescription(method: "GET", target: target)
        XCTAssertFalse(description.contains("super-secret-token"))
        XCTAssertTrue(description.contains("t=***"))
        XCTAssertTrue(description.contains("since=1"))

        let req = request(target)
        XCTAssertFalse(req.maskedDescription(method: "GET").contains("super-secret-token"))
    }

    // MARK: - History chunking

    func testHistoryChunksRespectByteCapOnAMultiByteBoundary() {
        // Every scalar is 3 bytes (e.g. "€"); a naive character-count cut
        // at a byte cap that isn't a multiple of 3 must still never split one.
        let history = String(repeating: "€", count: 100) // 300 bytes
        let chunks = T3Terminal.historyChunks(history, chunkLength: 10) // not a multiple of 3
        XCTAssertEqual(chunks.joined(), history)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf8.count, 10)
            XCTAssertFalse(chunk.isEmpty)
        }
    }

    func testHistoryChunksEmptyHistoryYieldsNoChunks() {
        XCTAssertEqual(T3Terminal.historyChunks(""), [])
    }

    func testSnapshotFramesSequenceIsCumulativeFromRingStart() {
        let history = String(repeating: "a", count: 25)
        let frames = T3Terminal.snapshotFrames(history: history, ringStart: 100, status: .running,
                                               chunkLength: 10)
        XCTAssertEqual(frames.map(\.history), ["aaaaaaaaaa", "aaaaaaaaaa", "aaaaa"])
        XCTAssertEqual(frames.map(\.sequence), [110, 120, 125])
        XCTAssertEqual(frames.last?.sequence, 100 + history.utf8.count)
        XCTAssertTrue(frames.allSatisfy { $0.status == .running })
    }

    func testSnapshotFramesEmptyHistoryStillYieldsOneFrame() {
        let frames = T3Terminal.snapshotFrames(history: "", ringStart: 50, status: .starting)
        XCTAssertEqual(frames, [.init(history: "", status: .starting, sequence: 50, exitCode: nil, exitSignal: nil)])
    }

    // MARK: - resumePlan on both sides of the ring

    func testResumePlanOnBothSidesOfTheRing() {
        XCTAssertEqual(T3Terminal.resumePlan(since: nil, ringStart: 100, ringEnd: 500), .snapshot)
        XCTAssertEqual(T3Terminal.resumePlan(since: 50, ringStart: 100, ringEnd: 500), .snapshot,
                       "older than the ring: a fresh snapshot, never a gap")
        XCTAssertEqual(T3Terminal.resumePlan(since: 100, ringStart: 100, ringEnd: 500), .outputFrom(100))
        XCTAssertEqual(T3Terminal.resumePlan(since: 300, ringStart: 100, ringEnd: 500), .outputFrom(300))
        XCTAssertEqual(T3Terminal.resumePlan(since: 500, ringStart: 100, ringEnd: 500), .outputFrom(500))
        XCTAssertEqual(T3Terminal.resumePlan(since: 501, ringStart: 100, ringEnd: 500), .snapshot,
                       "further ahead than the host has ever emitted: nonsense, fall back")
    }
}
