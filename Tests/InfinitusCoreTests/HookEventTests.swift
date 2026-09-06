import XCTest
@testable import InfinitusCore

final class HookEventTests: XCTestCase {
    func testPermissionPromptPushesWithItsMessage() {
        let event = HookEvent.parse(#"""
        {"session_id":"abc","cwd":"/Users/me/limitless","hook_event_name":"Notification",
         "notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}
        """#)
        XCTAssertEqual(event?.repo, "limitless")
        XCTAssertEqual(event?.needsHuman, true)
        XCTAssertEqual(event?.pushLine,
                       "waiting on you — limitless: Claude needs your permission to use Bash")
        XCTAssertEqual(event?.logLine,
                       "Notification — limitless (permission_prompt): Claude needs your permission to use Bash")
    }

    func testUserPromptSubmitCarriesThePrompt() {
        let event = HookEvent.parse(#"{"session_id":"abc","cwd":"/r","hook_event_name":"UserPromptSubmit","prompt":"Fix the crash"}"#)
        XCTAssertEqual(event?.prompt, "Fix the crash")
        XCTAssertNil(event?.pushLine)
    }

    func testMessagelessPromptFallsBackToThePollWording() {
        let event = HookEvent(name: "Notification", cwd: "/r/app", notificationType: "permission_prompt")
        XCTAssertEqual(event.pushLine, "waiting on you — app needs an answer")
    }

    func testStopAndInformationalNotificationsDoNotPush() {
        XCTAssertNil(HookEvent(name: "Stop", cwd: "/r/app").pushLine)
        XCTAssertNil(HookEvent(name: "Notification", cwd: "/r/app",
                               notificationType: "auth_success").pushLine)
        XCTAssertNil(HookEvent(name: "Notification", cwd: "/r/app",
                               notificationType: "idle_prompt").pushLine)
        XCTAssertEqual(HookEvent(name: "Stop").logLine, "Stop — a session")
    }

    func testGarbageIsNotAnEvent() {
        XCTAssertNil(HookEvent.parse("not json"))
        XCTAssertNil(HookEvent.parse(#"{"session_id":"x"}"#))
    }
}
