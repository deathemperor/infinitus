import XCTest
@testable import InfinitusCore

/// A progress tail keeps only what the parser reads of each entry (#499):
/// the slimmed and the whole decode parse to the same progress, the bulk
/// (thinking, signatures, attachments, tool descriptions) is gone, and
/// the feed reader's tail is left whole.
final class SessionTailSlimTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/-p"), withIntermediateDirectories: true)
        url = Transcript.path(cwd: "/p", sessionId: "s", claudeDir: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let thinking = String(repeating: "pondering the flaky test ", count: 40)
    private static let signature = String(repeating: "c2lnbmF0dXJl", count: 50)
    private static let filler = String(repeating: "more detail ", count: 30)
    private static let lines: [String] = [
        #"{"type":"user","timestamp":"2026-09-01T09:58:00.000Z","uuid":"u0","message":{"role":"user","content":"<system-reminder>injected</system-reminder>"}}"#,
        #"{"type":"user","timestamp":"2026-09-01T09:59:00.000Z","gitBranch":"main","message":{"role":"user","content":"\n  Fix the flaky test\nIt fails on CI only. \#(filler)END-OF-PROMPT"}}"#,
        #"{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","gitBranch":"main","message":{"model":"claude-x","content":[{"type":"thinking","thinking":"\#(thinking)","signature":"\#(signature)"},{"type":"text","text":"Looking at the test.\nThen the fixture. \#(filler)END-OF-REPLY"}],"usage":{"input_tokens":900,"cache_read_input_tokens":8000,"output_tokens":5}}}"#,
        #"{"type":"assistant","timestamp":"2026-09-01T10:00:10.000Z","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"aws sts get-caller-identity --profile prod","description":"Who am I"}}],"usage":{"output_tokens":7}}}"#,
        #"{"type":"user","timestamp":"2026-09-01T10:00:20.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Error when retrieving token from sso: Token has expired and refresh failed","is_error":true}]},"toolUseResult":{"stdout":"","stderr":"long stderr copy"}}"#,
        #"{"type":"assistant","timestamp":"2026-09-01T10:00:30.000Z","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"Read the test","status":"completed","activeForm":"Reading the test"},{"content":"Fix it","status":"in_progress","activeForm":"Fixing it"}]}}],"usage":{"output_tokens":9}}}"#,
        #"{"type":"user","timestamp":"2026-09-01T10:00:40.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"Todos updated"},{"type":"image","source":{"type":"base64","data":"AAAA"}}]}]}}"#,
        #"{"type":"assistant","timestamp":"2026-09-01T10:01:00.000Z","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t3","name":"Grep","input":{"pattern":"flaky","path":"/p"}}],"usage":{"output_tokens":2}}}"#,
        #"{"type":"assistant","timestamp":"2026-09-01T10:01:10.000Z","message":{"model":"claude-x","content":[{"type":"tool_use","id":"t4","name":"Edit","input":{"file_path":"/p/Tests/Flaky.swift","old_string":"a","new_string":"b"}}],"usage":{"output_tokens":4}}}"#,
        #"{"type":"summary","summary":"Flaky test fix","leafUuid":"x"}"#,
        #"{"type":"system","subtype":"api_error","timestamp":"2026-09-01T10:02:00.000Z","content":"429"}"#,
        #"{"type":"assistant","timestamp":"2026-09-01T10:02:01.000Z","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: rate limited"}]}}"#,
    ]

    func testSlimmedTailParsesLikeTheWholeDecode() throws {
        try (Self.lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var tail = SessionTail(url: url)
        XCTAssertTrue(tail.advance())
        let now = Date(timeIntervalSince1970: 1_756_720_000)
        let slimmed = SessionProgress.parse(entries: tail.entries, now: now)
        let whole = SessionProgress.parse(entries: SessionProgress.jsonEntries(Self.lines), now: now)
        XCTAssertEqual(slimmed, whole)
        XCTAssertEqual(slimmed.goal, "Fix the flaky test")
        XCTAssertEqual(slimmed.nowDoing, "API Error: rate limited")
        XCTAssertEqual(slimmed.todos, SessionProgress.Todos(done: 1, total: 2, activeForm: "Fixing it"))
        XCTAssertEqual(slimmed.awsLoginProfile, "prod")
        XCTAssertEqual(slimmed.outputTokens, 27)
        XCTAssertEqual(slimmed.model, "claude-x")
        XCTAssertEqual(slimmed.gitBranch, "main")
        XCTAssertEqual(slimmed.title, "Flaky test fix")
        XCTAssertTrue(slimmed.retrying)

        let kept = String(decoding: try JSONSerialization.data(withJSONObject: tail.entries), as: UTF8.self)
        for gone in [Self.thinking, Self.signature, "Who am I", "long stderr copy", "base64", "old_string",
                     "cache_read_input_tokens", "END-OF-PROMPT", "END-OF-REPLY", "\"uuid\""] {
            XCTAssertFalse(kept.contains(gone), "still holds \(gone.prefix(30))")
        }
        XCTAssertTrue(kept.contains("Token has expired"), "tool results stay whole for the sign-in detectors")
    }

    func testFeedTailKeepsEntriesWhole() throws {
        try (Self.lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var tail = SessionTail(url: url, maxBytes: 512 * 1024, scansAgents: false, slims: false)
        XCTAssertTrue(tail.advance())
        let kept = String(decoding: try JSONSerialization.data(withJSONObject: tail.entries), as: UTF8.self)
        XCTAssertTrue(kept.contains(Self.thinking))
    }
}
