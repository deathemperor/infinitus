import XCTest
@testable import InfinitusCore

/// The terminal host's ring (#507 step 3): the `sequence` bookkeeping the
/// wire's resume depends on, the UTF-8 boundaries a pty read splits, and
/// eviction. No PTY — the host's fds are not what this checks.
final class TerminalRingTests: XCTestCase {

    // MARK: - Sequence bookkeeping

    func testSequenceIsCumulativeBytesEmitted() {
        var ring = TerminalRing(capacity: 1024)
        XCTAssertEqual(ring.start, 0)
        XCTAssertEqual(ring.end, 0)
        XCTAssertEqual(ring.append(Data("hello".utf8))?.sequence, 5)
        XCTAssertEqual(ring.append(Data(" world".utf8))?.sequence, 11)
        XCTAssertEqual(ring.end, 11)
        XCTAssertEqual(ring.start, 0)
        XCTAssertEqual(ring.history, "hello world")
    }

    func testSequenceCountsBytesNotCharacters() {
        var ring = TerminalRing(capacity: 1024)
        // "é" is two UTF-8 bytes, "🙂" four.
        XCTAssertEqual(ring.append(Data("é🙂".utf8))?.sequence, 6)
        XCTAssertEqual(ring.end, 6)
    }

    func testAppendReturnsOnlyTheNewText() {
        var ring = TerminalRing(capacity: 1024)
        _ = ring.append(Data("one".utf8))
        XCTAssertEqual(ring.append(Data("two".utf8))?.text, "two")
    }

    // MARK: - A scalar split across two pty reads

    func testSplitScalarIsHeldBackUntilItCompletes() {
        var ring = TerminalRing(capacity: 1024)
        let bytes = Array("é".utf8)   // 0xC3 0xA9
        XCTAssertNil(ring.append(Data([bytes[0]])))
        XCTAssertEqual(ring.pendingBytes, 1)
        XCTAssertEqual(ring.end, 0, "a half character has not been emitted")
        let out = ring.append(Data([bytes[1]]))
        XCTAssertEqual(out?.text, "é")
        XCTAssertEqual(out?.sequence, 2)
        XCTAssertEqual(ring.pendingBytes, 0)
        XCTAssertEqual(ring.history, "é")
    }

    func testTrailingPartialScalarIsHeldBackWithTheTextBeforeIt() {
        var ring = TerminalRing(capacity: 1024)
        var chunk = Data("ok ".utf8)
        chunk.append(Array("🙂".utf8)[0])
        let out = ring.append(chunk)
        XCTAssertEqual(out?.text, "ok ")
        XCTAssertEqual(out?.sequence, 3)
        XCTAssertEqual(ring.pendingBytes, 1)
        XCTAssertEqual(ring.append(Data(Array("🙂".utf8)[1...]))?.text, "🙂")
        XCTAssertEqual(ring.end, 7)
    }

    func testFlushPendingGivesUpAHalfCharacterOnExit() {
        var ring = TerminalRing(capacity: 1024)
        XCTAssertNil(ring.append(Data([Array("é".utf8)[0]])))
        let flushed = ring.flushPending()
        XCTAssertEqual(flushed?.sequence, 1)
        XCTAssertEqual(flushed?.text, "\u{FFFD}")
        XCTAssertNil(ring.flushPending(), "nothing left to give up")
    }

    func testInvalidBytesAreNotHeldForever() {
        var ring = TerminalRing(capacity: 1024)
        // 0xFF is not a lead byte of anything: emit it, never hold it.
        XCTAssertEqual(ring.append(Data([0xFF]))?.sequence, 1)
        XCTAssertEqual(ring.pendingBytes, 0)
    }

    // MARK: - Eviction

    func testEvictionMovesStartAndKeepsTheTail() {
        var ring = TerminalRing(capacity: 8)
        // Trimming is batched at capacity + capacity/4, so push well past it.
        for _ in 0..<10 { _ = ring.append(Data("abcd".utf8)) }
        XCTAssertEqual(ring.end, 40)
        XCTAssertLessThanOrEqual(ring.history.utf8.count, 10)
        XCTAssertGreaterThanOrEqual(ring.history.utf8.count, 8)
        XCTAssertEqual(ring.start, ring.end - ring.history.utf8.count)
        XCTAssertTrue(ring.history.hasSuffix("abcd"))
    }

    func testEvictionNeverLeavesTheRingStartingMidCharacter() {
        var ring = TerminalRing(capacity: 8)
        for _ in 0..<12 { _ = ring.append(Data("🙂".utf8)) }
        XCTAssertFalse(ring.history.contains("\u{FFFD}"), "history starts on a scalar boundary")
        XCTAssertEqual(ring.start, ring.end - ring.history.utf8.count)
    }

    // MARK: - Replay for a resume

    func testSliceReplaysFromASequenceTheRingStillHolds() {
        var ring = TerminalRing(capacity: 1024)
        _ = ring.append(Data("first".utf8))
        let mark = ring.end
        _ = ring.append(Data("second".utf8))
        XCTAssertEqual(ring.slice(from: mark), "second")
        XCTAssertEqual(ring.slice(from: ring.end), "", "caught up: nothing to replay")
        XCTAssertEqual(ring.slice(from: 0), "firstsecond")
    }

    func testSliceRefusesAnEvictedOrImpossibleSequence() {
        var ring = TerminalRing(capacity: 8)
        for _ in 0..<10 { _ = ring.append(Data("abcd".utf8)) }
        XCTAssertNil(ring.slice(from: 0), "evicted")
        XCTAssertNil(ring.slice(from: ring.end + 1), "further ahead than anything emitted")
    }

    /// The pair the wire's resume is decided from — the ring's own bounds
    /// feed `T3Terminal.resumePlan` unchanged.
    func testRingBoundsDriveResumePlan() {
        var ring = TerminalRing(capacity: 8)
        for _ in 0..<10 { _ = ring.append(Data("abcd".utf8)) }
        XCTAssertEqual(T3Terminal.resumePlan(since: 0, ringStart: ring.start, ringEnd: ring.end), .snapshot)
        XCTAssertEqual(T3Terminal.resumePlan(since: ring.end, ringStart: ring.start, ringEnd: ring.end),
                       .outputFrom(ring.end))
    }

    func testDefaultCapacityIsTheWiresRingSize() {
        XCTAssertEqual(TerminalRing().capacity, T3Terminal.ringBytes)
    }
}
