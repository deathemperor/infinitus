import XCTest
@testable import InfinitusCore

final class ToolApprovalTests: XCTestCase {
    func testSessionModeAnswersBeforeTheRules() {
        let approvals = ToolApprovals()
        XCTAssertFalse(approvals.allows(sessionId: "s", tool: "Edit", command: nil))
        approvals.setMode("acceptEdits", sessionId: "s")
        XCTAssertTrue(approvals.allows(sessionId: "s", tool: "Edit", command: nil))
        XCTAssertTrue(approvals.allows(sessionId: "s", tool: "Write", command: nil))
        XCTAssertFalse(approvals.allows(sessionId: "s", tool: "Bash", command: "rm -rf /"))
        XCTAssertFalse(approvals.allows(sessionId: "other", tool: "Edit", command: nil))
        approvals.setMode("bypassPermissions", sessionId: "s")
        XCTAssertEqual(approvals.reason(sessionId: "s", tool: "Bash", command: "rm -rf /"), "the session's Full access mode")
        approvals.setMode(nil, sessionId: "s")
        XCTAssertNil(approvals.mode(for: "s"))
        XCTAssertFalse(approvals.allows(sessionId: "s", tool: "Edit", command: nil))
        approvals.add(.init(tool: "Edit"), sessionId: "s")
        XCTAssertEqual(approvals.reason(sessionId: "s", tool: "Edit", command: nil), "the phone's session rule")
    }

    func testBashRulesNarrowToTheCommandsFirstWord() {
        let rule = ToolApproval.Rule.from(tool: "Bash", input: "git status --short")
        XCTAssertEqual(rule.prefix, "git")
        XCTAssertTrue(rule.matches(tool: "Bash", command: "git push origin main"))
        XCTAssertTrue(rule.matches(tool: "Bash", command: "FOO=1 git log"))
        XCTAssertFalse(rule.matches(tool: "Bash", command: "rm -rf /"))
        XCTAssertFalse(rule.matches(tool: "Edit", command: nil))
        XCTAssertEqual(rule.label, "Bash git …")
    }

    func testOtherToolsAllowAnyInput() {
        let rule = ToolApproval.Rule.from(tool: "Edit", input: "/r/Sources/A.swift")
        XCTAssertNil(rule.prefix)
        XCTAssertTrue(rule.matches(tool: "Edit", command: nil))
        XCTAssertFalse(rule.matches(tool: "Write", command: nil))
    }

    func testWireFormRoundTripsAndRejectsGarbage() {
        let text = ToolApproval.encode(tool: "Bash", input: "swift test\n--filter X")
        XCTAssertEqual(ToolApproval.decode(text), ToolApproval.Rule(tool: "Bash", prefix: "swift"))
        XCTAssertNil(ToolApproval.decode(""))
        XCTAssertNil(ToolApproval.decode("\ninput without a tool"))
    }

    func testRulesAreScopedToTheSession() {
        let store = ToolApprovals()
        store.add(.from(tool: "Bash", input: "git status"), sessionId: "a")
        XCTAssertTrue(store.allows(sessionId: "a", tool: "Bash", command: "git diff"))
        XCTAssertFalse(store.allows(sessionId: "b", tool: "Bash", command: "git diff"))
        store.add(.from(tool: "Bash", input: "git status"), sessionId: "a")
        XCTAssertEqual(store.rules(for: "a").count, 1)
    }

    func testPreToolUsePayloadCarriesTheToolAndCommand() {
        let event = HookEvent.parse(#"{"session_id":"s","cwd":"/r","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status","description":"x"}}"#)
        XCTAssertEqual(event?.toolName, "Bash")
        XCTAssertEqual(event?.toolCommand, "git status")
        let edit = HookEvent.parse(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/r/a"}}"#)
        XCTAssertEqual(edit?.toolName, "Edit")
        XCTAssertNil(edit?.toolCommand)
    }
}
