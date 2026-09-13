import XCTest
@testable import InfinitusCore

final class ThreadPhasePushTests: XCTestCase {
    func testParsesTheDesktopsShapeAndRendersOneLine() throws {
        let push = try XCTUnwrap(ThreadPhasePush.parse(
            #"{"kind":"thread.phase","threadId":"t1","title":" Fix the login race ","phase":"waiting_for_approval"}"#))
        XCTAssertEqual(push.threadId, "t1")
        XCTAssertEqual(push.line, "Fix the login race — waiting for approval")
        let done = try XCTUnwrap(ThreadPhasePush.parse(
            #"{"kind":"thread.phase","threadId":"t1","title":"Fix the login race","phase":"completed","detail":"3 files"}"#))
        XCTAssertEqual(done.line, "Fix the login race — finished: 3 files")
        XCTAssertEqual(ThreadPhasePush.parse(#"{"kind":"thread.phase","threadId":"t2","title":"","phase":"failed"}"#)?.line,
                       "a thread — failed")
        XCTAssertEqual(ThreadPhasePush.parse(#"{"kind":"thread.phase","threadId":"t2","title":"X","phase":"needs_review"}"#)?.line,
                       "X — needs review")
    }

    func testRefusesAnyOtherShape() {
        XCTAssertNil(ThreadPhasePush.parse(#"{"kind":"thread.turn","threadId":"t1","phase":"completed"}"#))
        XCTAssertNil(ThreadPhasePush.parse(#"{"kind":"thread.phase","title":"no id","phase":"completed"}"#))
        XCTAssertNil(ThreadPhasePush.parse(#"{"kind":"thread.phase","threadId":"t1","title":"no phase"}"#))
        XCTAssertNil(ThreadPhasePush.parse("not json"))
    }
}
