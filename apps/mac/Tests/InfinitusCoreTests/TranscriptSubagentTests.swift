import XCTest
@testable import InfinitusCore

/// `Transcript.findSubagentLimits` (#117): a session whose own transcript
/// keeps going but whose sub-agents hit the usage limit.
final class TranscriptSubagentTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-subagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let assistantTurn = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"uuid":"a-1"}"#

    private func limitStop(uuid: String, timestamp: Date) -> String {
        let ts = ISO8601DateFormatter().string(from: timestamp)
        return """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"limit hit"}]},"error":"rate_limit","isApiErrorMessage":true,"uuid":"\(uuid)","timestamp":"\(ts)"}
        """
    }

    private func writeTranscript(cwd: String, id: String, lines: [String]) throws {
        let url = Transcript.path(cwd: cwd, sessionId: id, claudeDir: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeAgentTranscript(cwd: String, id: String, agent: String, lines: [String],
                                      workflow: String? = nil) throws {
        let transcript = Transcript.path(cwd: cwd, sessionId: id, claudeDir: dir)
        var subagentsDir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        if let workflow {
            subagentsDir = subagentsDir.appendingPathComponent("workflows").appendingPathComponent(workflow)
        }
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let url = subagentsDir.appendingPathComponent("agent-\(agent).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testSubagentLimitFoundWhileParentKeepsGoing() throws {
        try writeTranscript(cwd: "/p", id: "s1", lines: [assistantTurn])
        try writeAgentTranscript(cwd: "/p", id: "s1", agent: "a",
                                 lines: [limitStop(uuid: "sub-1", timestamp: Date().addingTimeInterval(-5 * 60))])
        let sessions = [ClaudeSessionRecord(pid: 42, sessionId: "s1", cwd: "/p")]
        let hits = Transcript.findSubagentLimits(sessions: sessions, claudeDir: dir)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].session.sessionId, "s1")
        XCTAssertEqual(hits[0].session.pid, 42)
        XCTAssertEqual(hits[0].session.stopUuid, "sub-1")
        XCTAssertEqual(hits[0].agentFile, "agent-a.jsonl")
    }

    func testParentsOwnLimitStopOwnsTheNudgeInstead() throws {
        try writeTranscript(cwd: "/p", id: "s1",
                           lines: [limitStop(uuid: "parent-1", timestamp: Date())])
        try writeAgentTranscript(cwd: "/p", id: "s1", agent: "a",
                                 lines: [limitStop(uuid: "sub-1", timestamp: Date())])
        let sessions = [ClaudeSessionRecord(pid: 42, sessionId: "s1", cwd: "/p")]
        XCTAssertTrue(Transcript.findSubagentLimits(sessions: sessions, claudeDir: dir).isEmpty)
    }

    func testStaleSubagentStopIsIgnored() throws {
        try writeTranscript(cwd: "/p", id: "s1", lines: [assistantTurn])
        try writeAgentTranscript(cwd: "/p", id: "s1", agent: "a",
                                 lines: [limitStop(uuid: "sub-1", timestamp: Date().addingTimeInterval(-2 * 3600))])
        let sessions = [ClaudeSessionRecord(pid: 42, sessionId: "s1", cwd: "/p")]
        XCTAssertTrue(Transcript.findSubagentLimits(sessions: sessions, claudeDir: dir).isEmpty)
    }

    func testWorkflowNestedAgentIsFound() throws {
        try writeTranscript(cwd: "/p", id: "s1", lines: [assistantTurn])
        try writeAgentTranscript(cwd: "/p", id: "s1", agent: "b",
                                 lines: [limitStop(uuid: "sub-2", timestamp: Date().addingTimeInterval(-5 * 60))],
                                 workflow: "r1")
        let sessions = [ClaudeSessionRecord(pid: 42, sessionId: "s1", cwd: "/p")]
        let hits = Transcript.findSubagentLimits(sessions: sessions, claudeDir: dir)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].session.stopUuid, "sub-2")
        XCTAssertEqual(hits[0].agentFile, "agent-b.jsonl")
    }

    func testSubagentMessageText() {
        XCTAssertEqual(ResumeCoordinator.subagentMessage(account: "P2", pct: 30),
                       "[Infinitus] Your sub-agents hit a usage limit, but the account has been swapped: "
                       + "P2 has 70% headroom now. It is safe to continue right away — no need to wait for the reset.")
        XCTAssertEqual(ResumeCoordinator.subagentMessage(account: nil, pct: nil),
                       "[Infinitus] Your sub-agents hit a usage limit, but an account with headroom is active now. "
                       + "It is safe to continue right away — no need to wait for the reset.")
    }
}
