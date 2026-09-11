import XCTest
@testable import InfinitusCore

final class SessionInputWireTests: XCTestCase {
    func testOldJSONWithoutTheNewKeysDecodes() throws {
        let json = #"{"kind":"message","text":"hi"}"#.data(using: .utf8)!
        let request = try JSONDecoder().decode(SessionInput.Request.self, from: json)
        XCTAssertEqual(request.text, "hi")
        XCTAssertNil(request.requestId)
        XCTAssertNil(request.queuedAt)
        XCTAssertNil(request.sessionId)
    }

    func testNewFieldsRoundTrip() throws {
        let queued = Date(timeIntervalSince1970: 1_700_000_000)
        let request = SessionInput.Request(kind: .message, text: "later", requestId: "r-1",
                                           queuedAt: queued, sessionId: "s-1")
        let data = try JSONEncoder().encode(request)
        let back = try JSONDecoder().decode(SessionInput.Request.self, from: data)
        XCTAssertEqual(back, request)
        XCTAssertEqual(back.requestId, "r-1")
        XCTAssertEqual(back.queuedAt, queued)
        XCTAssertEqual(back.sessionId, "s-1")
    }
}
