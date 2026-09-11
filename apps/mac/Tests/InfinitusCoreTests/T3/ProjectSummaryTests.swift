import XCTest
@testable import InfinitusCore

final class ProjectSummaryTests: XCTestCase {
    func testOneSummaryPerStandardizedCwdSortedByActivity() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let live = [ClaudeSessionRecord.fixture(pid: 1, cwd: "/Users/x/death/limitless/", startedAt: new),
                    ClaudeSessionRecord.fixture(pid: 2, cwd: "/Users/x/death/limitless", startedAt: old)]
        let past = [PastSession.fixture(cwd: "/Users/x/death/banyan", lastActivityAt: old)]
        let out = ProjectSummary.derive(live: live, past: past, profiles: [], recentCwds: ["/tmp/scratch"],
                                        branch: { $0.hasSuffix("limitless") ? "main" : nil })
        XCTAssertEqual(out.map(\.name), ["limitless", "banyan", "scratch"])
        XCTAssertEqual(out[0].cwd, "/Users/x/death/limitless")
        XCTAssertEqual(out[0].liveCount, 2)
        XCTAssertEqual(out[0].branch, "main")
        XCTAssertEqual(out[0].lastActivityAt, new)
        XCTAssertNil(out[2].lastActivityAt)
        XCTAssertEqual(out[0].id, ProjectSummary.projectId(cwd: "/Users/x/death/limitless/"))
    }

    func testProjectIdIsStableAndPathShaped() {
        XCTAssertEqual(ProjectSummary.projectId(cwd: "/a/b"), ProjectSummary.projectId(cwd: "/a/b/"))
        XCTAssertEqual(ProjectSummary.projectId(cwd: "/a/b").count, 16)
        XCTAssertNotEqual(ProjectSummary.projectId(cwd: "/a/b"), ProjectSummary.projectId(cwd: "/a/c"))
    }

    func testSnapshotDecodesWithoutProjects() throws {
        let json = #"{"capturedAt":"2026-09-08T00:00:00Z","machineName":"m","listJSON":"e30=","sessions":[]}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(MirrorSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.projects)
    }
}

extension ClaudeSessionRecord {
    /// `startedAt` maps to `statusUpdatedAt` — the record has no other
    /// Date field; `ProjectSummary.derive` reads the same one.
    static func fixture(pid: Int32, cwd: String, startedAt: Date) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: "s\(pid)", cwd: cwd, kind: "interactive",
                            status: "idle", messagingSocketPath: "", peerProtocol: 0,
                            name: nil, statusUpdatedAt: startedAt, entrypoint: nil)
    }
}

extension PastSession {
    static func fixture(cwd: String, lastActivityAt: Date) -> PastSession {
        PastSession(sessionId: "s", cwd: cwd, repo: URL(fileURLWithPath: cwd).lastPathComponent,
                    firstMessage: "", lastActivityAt: lastActivityAt, bytes: 0, live: false)
    }
}
