import XCTest
@testable import InfinitusCore

/// The presentation reducer over the phase-1 fixtures (#223 phase 2):
/// every row as one compact line, so a change in grouping, folding or
/// labels shows up as a diff.
final class ThreadFeedPresentationTests: XCTestCase {
    func entries(_ name: String) throws -> [[String: Any]] {
        let url = Bundle.module.url(forResource: "Fixtures/timeline/\(name)", withExtension: "jsonl")!
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { SessionFeedReader.decodeLine(String($0)) }
    }
    func timeline(_ name: String, status: String = "idle", drop: Set<String> = []) throws -> SessionTimeline {
        let e = try entries(name).filter { !drop.contains($0["uuid"] as? String ?? "") }
        return SessionTimelineBuilder.build(entries: e, status: status)
    }
    func lines(_ rows: [ThreadFeedRow]) -> [String] {
        rows.map { r in
            switch r.kind {
            case .message(let m):
                return "msg:\(m.id) \(m.role.rawValue)\(m.streaming ? "*" : "") \(m.text.split(separator: "\n").first ?? "")"
            case .activityGroup(let es):
                return "group:\(r.id) " + es.map { "\($0.kind)/\($0.status.rawValue)" }.joined(separator: ",")
            case .workToggle(let t):
                return "toggle:\(r.id) \"\(t.summary)\" [\(t.hiddenCount)]\(t.hasFailure ? "!" : "")\(t.live ? "~" : "")\(t.expanded ? "+" : "")"
            case .turnFold(let f):
                return "fold:\(r.id) \"\(f.label)\" [\(f.hiddenCount)]\(f.expanded ? "+" : "")"
            case .thinking:
                return "thinking:\(r.id)"
            case .agentSpawn(let a):
                return "agents:\(r.id) \"\(a.title)\" " + a.members.map { "\($0.title)\($0.running ? "…" : "")\($0.failed ? "!" : "")" }.joined(separator: ",")
            }
        }
    }
    func rows(_ name: String, status: String = "idle", drop: Set<String> = [], turns: Set<String> = [],
              groups: Set<String> = []) throws -> [String] {
        lines(ThreadFeedPresentation.derive(try timeline(name, status: status, drop: drop),
                                            expandedTurnIds: turns, expandedWorkGroupIds: groups))
    }

    // MARK: fixtures

    func testPlainTurnsAreMessagesOnly() throws {
        XCTAssertEqual(try rows("plain"), [
            "msg:u1 user fix the build",
            "msg:a1 assistant Looking into it.",
            "msg:u2 user thanks",
            "msg:a3 assistant Anytime.",
        ])
    }

    func testToolsFoldBehindTheTurnAndSummarizeWhenExpanded() throws {
        XCTAssertEqual(try rows("tools"), [
            "msg:u1 user run the tests and fix",
            "fold:turn-fold:u1 \"Worked for 13s\" [1]",
            "msg:a4 assistant Push failed; tests pass.",
        ])
        XCTAssertEqual(try rows("tools", turns: ["u1"]), [
            "msg:u1 user run the tests and fix",
            "fold:turn-fold:u1 \"Worked for 13s\" [1]+",
            "toggle:work-toggle:work-group:tool:u1:t1 \"Ran 2 commands and changed 1 file\" [3]!",
            "msg:a4 assistant Push failed; tests pass.",
        ])
        XCTAssertEqual(try rows("tools", turns: ["u1"], groups: ["work-group:tool:u1:t1"]).dropFirst(2).prefix(2), [
            "toggle:work-toggle:work-group:tool:u1:t1 \"Ran 2 commands and changed 1 file\" [3]!+",
            "group:work-details:work-group:tool:u1:t1 tool.completed/success,tool.completed/success,tool.completed/failure",
        ])
    }

    func testWorkingTurnNeverFoldsAndThinksWhenNothingIsLive() throws {
        // The group is not the tail (a message follows) → no shimmer, thinking row.
        XCTAssertEqual(try rows("tools", status: "busy"), [
            "msg:u1 user run the tests and fix",
            "toggle:work-toggle:work-group:tool:u1:t1 \"Ran 2 commands and changed 1 file\" [3]!",
            "msg:a4 assistant* Push failed; tests pass.",
            "thinking:live-activity-row",
        ])
        // Tail group whose last call failed hands the live slot to Thinking.
        XCTAssertEqual(try rows("tools", status: "busy", drop: ["a4"]).suffix(2), [
            "toggle:work-toggle:work-group:tool:u1:t1 \"Ran 2 commands and changed 1 file\" [3]!",
            "thinking:live-activity-row",
        ])
        // A running call at the tail shimmers under the one live id, in the present tense.
        XCTAssertEqual(try rows("tools", status: "busy", drop: ["a4", "r3"]).suffix(1), [
            "toggle:live-activity-row \"Running git\" [3]~",
        ])
        // …and keeps that id right after it returns.
        XCTAssertEqual(try rows("tools", status: "busy", drop: ["a4", "a3", "r3"]).suffix(1), [
            "toggle:live-activity-row \"Changed File.swift\" [2]~",
        ])
    }

    func testInterruptAndErrorTurns() throws {
        XCTAssertEqual(try rows("interrupted"), [
            "msg:u1 user delete everything",
            "fold:turn-fold:u1 \"You stopped after 4s\" [0]",
            "msg:u2 user just the cache",
            "group:activity:a2 runtime.error/failure",
        ])
    }

    func testStandaloneRowsStayVisible() throws {
        XCTAssertEqual(try rows("limit").dropFirst(), ["group:activity:a1 runtime.warning/neutral"])
        XCTAssertEqual(try rows("compact").dropFirst(), ["group:activity:c1 context-compaction/neutral"])
        XCTAssertEqual(try rows("peer").dropFirst(), ["group:activity:s1 runtime.warning/neutral"])
    }

    func testPlanUpdatesGroupAsUpdates() throws {
        XCTAssertEqual(try rows("todo", turns: ["u1"]).dropFirst(), [
            "fold:turn-fold:u1 \"Worked for 1s\" [1]+",
            "toggle:work-toggle:work-group:tool:u1:td1 \"1 of 3 steps\" [1]",
        ])
    }

    func testSubAgentsBecomeOneCard() throws {
        XCTAssertEqual(try rows("agent", turns: ["u1"]), [
            "msg:u1 user research it",
            "fold:turn-fold:u1 \"Worked for 4m 59s\" [1]+",
            "agents:agent-spawn:u1:ag1 \"Ran 1 subagent\" Map session feed rendering",
        ])
        XCTAssertEqual(try rows("agent", status: "busy", drop: ["r1"]).suffix(2), [
            "agents:agent-spawn:u1:ag1 \"Kicked off 1 subagent\" Map session feed rendering…",
            "thinking:live-activity-row",
        ])
    }

    // MARK: labels

    func testGroupSummaryCountsEditsByFile() {
        func entry(_ id: String, _ action: WorkEntry.Action, files: [String] = []) -> WorkEntry {
            WorkEntry(id: id, kind: "tool.completed", tone: .tool, summary: id, detail: nil, status: .success, action: action,
                      toolLike: true, toolCallId: id, requestId: nil, changedFiles: files, payload: [:], turnId: "t", createdAt: Date())
        }
        XCTAssertEqual(ThreadFeedPresentation.summarizeGroup([
            entry("a", .read), entry("b", .read), entry("c", .edit, files: ["x.swift"]), entry("d", .edit, files: ["x.swift"]),
            entry("e", .command),
        ]), "Read 2 files, changed 1 file, and ran 1 command")
        XCTAssertEqual(ThreadFeedPresentation.summarizeGroup([entry("a", .codeSearch), entry("b", .other)]),
                       "Searched code 1 time and used 1 tool")
    }

    func testCommandProgramSkipsWrappers() {
        XCTAssertEqual(ThreadFeedPresentation.commandProgram("cd ~/x && FOO=1 sudo /usr/bin/git push"), "git")
        XCTAssertEqual(ThreadFeedPresentation.commandProgram("swift test --filter X"), "swift")
        XCTAssertNil(ThreadFeedPresentation.commandProgram("   "))
    }

    func testDurations() {
        XCTAssertEqual(ThreadFeedPresentation.formatDuration(8), "8s")
        XCTAssertEqual(ThreadFeedPresentation.formatDuration(134), "2m 14s")
        XCTAssertEqual(ThreadFeedPresentation.formatDuration(120), "2m")
        XCTAssertEqual(ThreadFeedPresentation.formatDuration(3720), "1h 2m")
    }

    func testRowsRoundTripAsJSON() throws {
        let rows = ThreadFeedPresentation.derive(try timeline("tools", status: "busy"), expandedTurnIds: ["u1"],
                                                 now: Date(timeIntervalSince1970: 1_700_000_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode([ThreadFeedRow].self, from: try enc.encode(rows)), rows)
    }
}
