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

    /// The whole payload Claude Code pipes into `hooks/event.sh` for a
    /// prompt — the fields Infinitus doesn't act on must not upset the
    /// parse, since this is what a checkpoint is born from (#486 slice 3).
    func testTheFullUserPromptSubmitPayloadTheHookForwards() {
        let event = HookEvent.parse(#"""
        {"session_id":"9f4c1e2a-1111-4b6d-8e33-abcdef012345",
         "transcript_path":"/home/me/.claude/projects/-home-me-limitless/9f4c1e2a.jsonl",
         "cwd":"/home/me/limitless","permission_mode":"acceptEdits",
         "hook_event_name":"UserPromptSubmit","prompt":"port the control socket to Linux"}
        """#)
        XCTAssertEqual(event?.name, "UserPromptSubmit")
        XCTAssertEqual(event?.sessionId, "9f4c1e2a-1111-4b6d-8e33-abcdef012345")
        XCTAssertEqual(event?.cwd, "/home/me/limitless")
        XCTAssertEqual(event?.prompt, "port the control socket to Linux")
        XCTAssertEqual(event?.repo, "limitless")
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
