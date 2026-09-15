import XCTest
@testable import InfinitusCore

final class TeamThreadSourcesTests: XCTestCase {
    /// Two threads of one project: one running with a usage rollup, one
    /// idle and older; a third archived under a project the shell does not list.
    let shellJSON = """
    {"projects":[{"id":"p1","title":"Infinitus","workspaceRoot":"/w/infinitus"}],
     "threads":[{"id":"t1","projectId":"p1","title":"Running one","latestTurn":{"turnId":"u1","state":"running","startedAt":"2026-09-12T00:00:01Z"},
                 "session":{"status":"running"},"createdAt":"2026-09-11T00:00:00Z","updatedAt":"2026-09-12T00:00:02Z","archivedAt":null,
                 "usage":{"source":"provider","turns":3,"inputTokens":100,"outputTokens":20,"costUsd":0.5,"models":["claude-opus-5"]}},
                {"id":"t2","projectId":"p1","title":"Idle one","latestTurn":{"turnId":"u2","state":"completed"},"session":null,
                 "createdAt":"2026-09-10T00:00:00Z","updatedAt":"2026-09-10T00:00:03Z","hasPendingApprovals":true},
                {"id":"t3","projectId":"gone","title":"Old","latestTurn":null,"session":null,"updatedAt":"2026-09-01T00:00:00Z","archivedAt":"2026-09-02T00:00:00Z"}]}
    """

    func testThreadsAreIndexRowsNewestFirstAndTheLiveOnesAreListed() throws {
        let shell = try JSONDecoder().decode(DesktopAPI.Shell.self, from: Data(shellJSON.utf8))
        let (rows, live) = TeamThreadSources.threads(shell, now: 5)
        XCTAssertEqual(rows.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(rows.map(\.project), ["infinitus", "infinitus", "gone"], "the workspace root's basename; an unknown project id as itself")
        XCTAssertEqual(rows.map(\.status), ["running", "waiting", "archived"])
        XCTAssertEqual(rows[0].createdAt, 1_789_084_800); XCTAssertEqual(rows[0].updatedAt, 1_789_171_202)
        XCTAssertEqual(rows[0].turns, 3)
        XCTAssertEqual(rows[0].usage, .init(inputTokens: 100, outputTokens: 20, costUsd: 0.5, models: ["claude-opus-5"]))
        XCTAssertNil(rows[1].usage); XCTAssertEqual(rows[1].turns, 0)
        XCTAssertEqual(live.map(\.id), ["t1", "t2"], "a turn in flight, or one waiting on the person")
        XCTAssertEqual(live[0].startedAt, 1_789_171_201); XCTAssertNil(live[0].activityLine)
        XCTAssertEqual(live[1].activityLine, "Waiting for approval")
    }

    func testTranscriptRowsFollowTheMessages() throws {
        let json = """
        {"id":"t1","projectId":"p1","title":"Running one","latestTurn":null,"session":null,
         "messages":[{"id":"m1","role":"user","text":"hi","createdAt":"2026-09-12T00:00:00.500Z"},{"id":"m2","role":"assistant","text":"hello"}]}
        """
        let thread = try JSONDecoder().decode(DesktopAPI.Thread.self, from: Data(json.utf8))
        let transcript = TeamThreadSources.transcript(thread, project: "infinitus")
        XCTAssertEqual(transcript.threadId, "t1"); XCTAssertEqual(transcript.project, "infinitus")
        XCTAssertEqual(transcript.rows, [.init(role: "user", text: "hi", at: 1_789_171_200), .init(role: "assistant", text: "hello", at: nil)])
        XCTAssertEqual(transcript.chunkPath(seq: 2), "transcripts/t1/2.jsonl")
        XCTAssertNil(TeamThreadSources.unix("yesterday"))
    }
}
