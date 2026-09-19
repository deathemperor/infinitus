import XCTest
@testable import InfinitusCore

final class TeamDocsTests: XCTestCase {
    func testThreadsIndexPathIsAKind() {
        XCTAssertEqual(TeamKinds.expected(at: "m/abc/threads/index.json")?.kind, "threads")
        XCTAssertEqual(TeamKinds.expected(at: "m/abc/threads/index.json")?.from, "abc")
        XCTAssertNil(TeamKinds.expected(at: "m/abc/sessions/index.json"))
        XCTAssertEqual(TeamKinds.memberKinds, ["stats", "now", "threads", "transcripts", "fleet"])
        // Retired (#1422): still a readable kind with its path shape, so
        // old members' crashes.json envelopes keep decoding.
        XCTAssertEqual(TeamKinds.expected(at: "m/abc/crashes.json")?.kind, TeamKinds.crashes)
    }

    func testNowRoundTripsLiveThreads() throws {
        let now = TeamDocs.Now(at: 1, machine: "mac", live: [.init(id: "t1", title: "Fix", project: "repo", startedAt: 1, activityLine: nil)],
                               fleets: [], blockers: [], crashesToday: 0, sharesTo: [:], desktop: true)
        let back = try CanonicalJSON.decode(TeamDocs.Now.self, from: try CanonicalJSON.encode(now))
        XCTAssertEqual(back, now)
        XCTAssertEqual(back.live.first?.title, "Fix")
    }

    func testThreadsIndexRoundTrips() throws {
        var row = TeamDocs.ThreadRow(id: "t1", title: "Fix", project: "repo", status: "idle", createdAt: 1, updatedAt: 2, turns: 3)
        row.usage = .init(inputTokens: 10, outputTokens: 2, costUsd: nil, models: ["claude-opus-5"])
        let index = TeamDocs.ThreadsIndex(at: 5, threads: [row], fleets: [])
        let back = try CanonicalJSON.decode(TeamDocs.ThreadsIndex.self, from: try CanonicalJSON.encode(index))
        XCTAssertEqual(back, index)
    }
}
