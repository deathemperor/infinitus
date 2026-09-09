import XCTest
@testable import InfinitusMobile

/// The attach stream's frames (#507), upstream `terminal.ts` names.
final class T3TerminalWireTests: XCTestCase {
    private func frame(_ json: String) throws -> T3TerminalWire.Frame { try T3TerminalWire.Frame.decode(Data(json.utf8)) }

    func testDecodesEveryFrame() throws {
        XCTAssertEqual(try frame(#"{"type":"snapshot","snapshot":{"terminalId":"default","status":"running","history":"$ ","sequence":7,"exitCode":null,"exitSignal":null}}"#),
                       .snapshot(.init(terminalId: "default", status: "running", history: "$ ", sequence: 7, exitCode: nil, exitSignal: nil)))
        XCTAssertEqual(try frame(#"{"type":"output","data":"ls\r\n","sequence":8}"#), .output(data: "ls\r\n", sequence: 8))
        XCTAssertEqual(try frame(#"{"type":"exited","exitCode":0,"exitSignal":null}"#), .exited(exitCode: 0, exitSignal: nil))
        XCTAssertEqual(try frame(#"{"type":"closed","reason":"backpressure"}"#), .closed(reason: "backpressure"))
        XCTAssertEqual(try frame(#"{"type":"closed"}"#), .closed(reason: nil))
        XCTAssertEqual(try frame(#"{"type":"error","message":"spawn failed"}"#), .error(message: "spawn failed"))
    }

    func testUnknownFrameIsSkippedNotFatal() throws {
        XCTAssertEqual(try frame(#"{"type":"activity","hasRunningSubprocess":true,"label":"vim"}"#), .other(type: "activity"))
    }

    func testSequenceIsTheResumeCursor() throws {
        XCTAssertEqual(try frame(#"{"type":"output","data":"x","sequence":12}"#).sequence, 12)
        XCTAssertNil(try frame(#"{"type":"closed"}"#).sequence)
    }

    func testPaths() {
        XCTAssertEqual(T3TerminalWire.terminalPath(pid: 42), "/sessions/42/terminal")
        XCTAssertEqual(T3TerminalWire.streamPath(pid: 42, id: "default"), "/sessions/42/terminal/default/stream")
        XCTAssertEqual(T3TerminalWire.closePath(pid: 42, id: "default"), "/sessions/42/terminal/default")
    }
}
