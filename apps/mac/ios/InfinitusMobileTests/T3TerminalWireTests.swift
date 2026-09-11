import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// The phone's reading of Core's terminal stream (#507).
final class T3TerminalWireTests: XCTestCase {
    func testKnownFramesDecodeAndCarryTheResumeOffset() throws {
        let snapshot = try T3TerminalWire.decodeLine(Data(#"{"type":"snapshot","history":"$ ","status":"running","sequence":2}"#.utf8))
        XCTAssertEqual(snapshot, .snapshot(.init(history: "$ ", status: .running, sequence: 2)))
        XCTAssertEqual(snapshot?.resumeSequence, 2)
        let output = try T3TerminalWire.decodeLine(Data(#"{"type":"output","data":"ls","sequence":4}"#.utf8))
        XCTAssertEqual(output?.resumeSequence, 4)
        let closed = try T3TerminalWire.decodeLine(Data(#"{"type":"closed","reason":"backpressure"}"#.utf8))
        XCTAssertEqual(closed, .closed(.init(reason: T3Terminal.closedReasonBackpressure)))
        XCTAssertNil(closed?.resumeSequence)
    }

    func testUnknownFrameIsSkippedNotFatal() throws {
        XCTAssertNil(try T3TerminalWire.decodeLine(Data(#"{"type":"activity","hasRunningSubprocess":true,"label":"vim"}"#.utf8)))
    }

    func testMalformedKnownFrameThrows() {
        XCTAssertThrowsError(try T3TerminalWire.decodeLine(Data(#"{"type":"output","sequence":"x"}"#.utf8)))
    }

    @MainActor
    func testChunkedSnapshotResetsOnceThenAppends() {
        let controller = T3TerminalController(font: .monospacedSystemFont(ofSize: 10, weight: .regular))
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        controller.feed(.output(.init(data: "stale", sequence: 5)))
        controller.awaitingSnapshot = true
        controller.feed(.snapshot(.init(history: "one ", status: .running, sequence: 4)))
        controller.feed(.snapshot(.init(history: "two", status: .running, sequence: 7)))
        let line = controller.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        XCTAssertEqual(line, "one two")
        XCTAssertEqual(controller.phase, .running)
    }
}
