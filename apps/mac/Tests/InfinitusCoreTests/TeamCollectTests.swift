import XCTest
@testable import InfinitusCore

/// A tiny Claude Code projects dir: two projects, one session each, one
/// sub-agent under the first. Shared by the publisher and reader tests
/// (repeated there — each test file stands alone).
enum TeamFixture {
    static let userLine = #"{"type":"user","cwd":"%CWD%","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"}}"#
    static let assistantLine = #"{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"%ID%","model":"claude-opus-5","usage":{"input_tokens":%IN%,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"#

    static func transcript(cwd: String, id: String, input: Int) -> String {
        userLine.replacingOccurrences(of: "%CWD%", with: cwd) + "\n"
            + assistantLine.replacingOccurrences(of: "%ID%", with: id).replacingOccurrences(of: "%IN%", with: String(input)) + "\n"
    }

    /// Returns the projects dir. `s1` in `/r/app` (10 input tokens) with
    /// sub-agent `agent-a1` (5), `s2` in `/r/secret` (10).
    @discardableResult
    static func write(into root: URL) throws -> URL {
        let projects = root.appendingPathComponent("projects")
        let app = projects.appendingPathComponent("-r-app")
        let secret = projects.appendingPathComponent("-r-secret")
        let sub = app.appendingPathComponent("s1/subagents")
        for dir in [app, secret, sub] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try transcript(cwd: "/r/app", id: "a1", input: 10).write(to: app.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try transcript(cwd: "/r/app", id: "a2", input: 5).write(to: sub.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try transcript(cwd: "/r/secret", id: "a3", input: 10).write(to: secret.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        return projects
    }
}

final class TeamCollectTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamcollect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func testTranscriptIdentity() {
        let main = TeamFold.transcriptIdentity("/h/.claude/projects/-r-app/s1.jsonl")
        XCTAssertEqual(main.session, "s1"); XCTAssertNil(main.agent); XCTAssertEqual(main.projectDir, "-r-app")
        let sub = TeamFold.transcriptIdentity("/h/.claude/projects/-r-app/s1/subagents/agent-a1.jsonl")
        XCTAssertEqual(sub.session, "s1"); XCTAssertEqual(sub.agent, "agent-a1"); XCTAssertEqual(sub.projectDir, "-r-app")
        // #346: pure string work, the same answers URL path math gave —
        // only the last extension goes, a dotless name stays whole.
        let dotted = TeamFold.transcriptIdentity("/h/.claude/projects/-r-app/2026-09-12T10.00.jsonl")
        XCTAssertEqual(dotted.session, "2026-09-12T10.00"); XCTAssertEqual(dotted.projectDir, "-r-app")
        XCTAssertEqual(TeamFold.transcriptIdentity("/h/.codex/sessions/2026/09/12/rollout").session, "rollout")
    }

    func testScanExposesEntriesAndCollectHonoursExclusions() throws {
        let projects = try TeamFixture.write(into: scratch)
        let scan = StatsScanner.scan(projectsDir: projects, cacheURL: nil, calendar: .current, maxAge: 10_000 * 86_400)
        XCTAssertEqual(scan.entries.count, 3)
        XCTAssertEqual(Set(scan.entries.values.compactMap(\.cwd)), ["/r/app", "/r/secret"])

        let all = TeamFold.collect(entries: scan.entries, exclusions: TeamExclusions())
        XCTAssertEqual(all.days["2026-09-04"]?.inputTokens, 25)
        // Three assistant lines land in the same minute (12:00:05Z), one output
        // token each: finalizePeak must run on the merged minuteTokens, not per-file.
        XCTAssertEqual(all.days["2026-09-04"]?.peakTokensPerMinute, 3)

        let some = TeamFold.collect(entries: scan.entries, exclusions: TeamExclusions(projects: ["/r/secret"]))
        XCTAssertEqual(some.days["2026-09-04"]?.inputTokens, 15)
        XCTAssertEqual(some.days["2026-09-04"]?.peakTokensPerMinute, 2)   // s1 + its sub-agent, secret excluded

        // A file whose cwd is unknown is still excluded through its project dir's slug.
        var blind = scan.entries
        for (path, var entry) in blind where path.contains("-r-secret") { entry.cwd = nil; blind[path] = entry }
        XCTAssertEqual(TeamFold.collect(entries: blind, exclusions: TeamExclusions(projects: ["/r/secret"])).days["2026-09-04"]?.inputTokens, 15)

        // A thread names its project by basename; the same exclusion catches it.
        XCTAssertTrue(TeamExclusions(projects: ["/r/secret"]).excludes(project: "secret"))
        XCTAssertFalse(TeamExclusions(projects: ["/r/secret"]).excludes(project: "app"))
    }
}
