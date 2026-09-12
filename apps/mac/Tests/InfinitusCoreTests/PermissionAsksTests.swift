import XCTest
@testable import InfinitusCore

final class PermissionAsksTests: XCTestCase {
    private let payload = """
    {"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","cwd":"/r",
     "tool_input":{"command":"git push origin main","description":"push"},"permission_suggestions":[]}
    """

    func testParsesOnlyPermissionRequestsAndRendersTheInputBounded() {
        let request = PermissionAsks.Request.parse(payload)
        XCTAssertEqual(request, .init(sessionId: "s1", tool: "Bash", input: "git push origin main"))
        XCTAssertNil(PermissionAsks.Request.parse(payload.replacingOccurrences(of: "PermissionRequest", with: "PreToolUse")))
        XCTAssertNil(PermissionAsks.Request.parse("not json"))
        XCTAssertEqual(PermissionAsks.Request.render(tool: "Edit", input: ["file_path": "/r/A.swift", "old_string": "x"]), "/r/A.swift")
        XCTAssertEqual(PermissionAsks.Request.render(tool: "WebFetch", input: ["url": "u", "prompt": "p"]), "prompt, url")
        let long = PermissionAsks.Request.render(tool: "Bash", input: ["command": String(repeating: "a\n", count: 300)])
        XCTAssertEqual(long.count, 200)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertFalse(long.contains("\n"))
    }

    func testDecideThenWaitAnswersOnceAndClearsThePending() async {
        let asks = PermissionAsks()
        let ask = asks.register(.init(sessionId: "s1", tool: "Bash", input: "ls"), pid: 42, window: 10)
        XCTAssertEqual(asks.pending().map(\.id), [ask.id])
        XCTAssertTrue(asks.decide(ask.id, .allow))
        XCTAssertFalse(asks.decide(ask.id, .deny), "a second decision changes nothing")
        XCTAssertEqual(asks.pending(), [])
        let answer = await asks.wait(ask.id)
        XCTAssertEqual(answer.decision, .allow)
        let again = await asks.wait(ask.id)
        XCTAssertEqual(again.decision, .ask, "the ask is gone once the hook has read it")
    }

    func testWaitThenDecideResumesTheParkedHook() async {
        let asks = PermissionAsks()
        let ask = asks.register(.init(sessionId: "s1", tool: "Edit", input: "/r/A.swift"), pid: nil, window: 10)
        async let parked = asks.wait(ask.id)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(asks.decide(ask.id, .deny, message: "not now"))
        let answer = await parked
        XCTAssertEqual(answer.decision, .deny)
        XCTAssertEqual(answer.message, "not now")
        XCTAssertFalse(asks.decide(ask.id, .allow), "expiry or a late tap cannot resume it twice")
    }

    func testTheWindowClosingFallsThroughToAsk() async {
        let asks = PermissionAsks()
        let ask = asks.register(.init(sessionId: "s1", tool: "Bash", input: "ls"), pid: nil, window: 0.1)
        let answer = await asks.wait(ask.id)
        XCTAssertEqual(answer.decision, .ask)
        XCTAssertEqual(asks.pending(), [])
        XCTAssertFalse(asks.decide(ask.id, .allow))
        let unknown = await asks.wait("nope")
        XCTAssertEqual(unknown.decision, .ask)
    }

    func testRemoteIsPerSession() {
        let asks = PermissionAsks()
        XCTAssertFalse(asks.isRemote(sessionId: "s1"))
        asks.setRemote(true, sessionId: "s1")
        XCTAssertTrue(asks.isRemote(sessionId: "s1"))
        XCTAssertFalse(asks.isRemote(sessionId: "s2"))
        asks.setRemote(false, sessionId: "s1")
        XCTAssertFalse(asks.isRemote(sessionId: "s1"))
    }
}
