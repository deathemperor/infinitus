import XCTest
@testable import InfinitusCore

final class T3WorkspaceStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func record(pid: Int32, id: String, cwd: String = "/w/a", status: String? = "idle") -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: id, cwd: cwd, status: status, statusUpdatedAt: now)
    }
    private func facts(_ status: SessionFacts.Status = .ready, pinnedAt: Date? = nil, snoozedUntil: Date? = nil,
                       settled: AttentionStore.SettledOverride? = nil) -> SessionFacts {
        SessionFacts(status: status, hasPendingApprovals: false, hasPendingUserInput: false, hasPlan: false,
                     latestTurn: nil, planProgress: nil, latestUserMessageAt: nil, settledOverride: settled,
                     settledAt: settled == nil ? nil : now, unsettledAt: nil, snoozedUntil: snoozedUntil,
                     snoozedAt: snoozedUntil == nil ? nil : now, pinnedAt: pinnedAt)
    }
    private func inputs(_ pairs: [(ClaudeSessionRecord, SessionFacts)], projects: [ProjectSummary] = []) -> T3WorkspaceInputs {
        T3WorkspaceInputs(records: pairs.map(\.0), facts: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.pid, $0.1) }),
                          progress: [:], startedAt: [:], projects: projects)
    }

    func testApplyBuildsThreadsAndProjects() {
        var s = T3WorkspaceState()
        let summary = ProjectSummary(id: ProjectSummary.projectId(cwd: "/w/a"), name: "a", cwd: "/w/a", branch: nil, liveCount: 1, lastActivityAt: nil)
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())], projects: [summary]), now: now)
        XCTAssertEqual(s.threads.map(\.id), ["s1"])
        XCTAssertEqual(s.threads[0].projectId, summary.id)
        XCTAssertEqual(s.projects.map(\.id), [summary.id])
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(s.groups[0].members.map(\.id), [summary.id])
    }

    func testPidWithoutFactsIsSkipped() {
        var s = T3WorkspaceState()
        s.apply(T3WorkspaceInputs(records: [record(pid: 1, id: "s1"), record(pid: 2, id: "s2")],
                                  facts: [1: facts()], progress: [:], startedAt: [:], projects: []), now: now)
        XCTAssertEqual(s.threads.map(\.id), ["s1"])
    }

    func testSelectionSurvivesPidChangeAndClearsWhenGone() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())]), now: now)
        s.select("s1", now: now)
        XCTAssertEqual(s.pid(of: "s1"), 1)
        XCTAssertEqual(s.lastVisitedAt["s1"], now)
        s.apply(inputs([(record(pid: 9, id: "s1"), facts())]), now: now)   // resumed under a new pid
        XCTAssertEqual(s.selectedThreadId, "s1")
        XCTAssertEqual(s.pid(of: "s1"), 9)
        s.apply(inputs([]), now: now)
        XCTAssertNil(s.selectedThreadId)
        XCTAssertNil(s.selectedThread)
    }

    func testSectionsPinnedActiveSnoozedSettled() {
        var s = T3WorkspaceState()
        s.apply(inputs([
            (record(pid: 1, id: "pinned"), facts(pinnedAt: now)),
            (record(pid: 2, id: "active", status: "busy"), facts(.running)),
            (record(pid: 3, id: "snoozed"), facts(snoozedUntil: now.addingTimeInterval(3600))),
            (record(pid: 4, id: "settled"), facts(settled: .settled)),
        ]), now: now)
        let sections = s.sidebarSections(now: now)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .active, .snoozed, .settled])
        XCTAssertEqual(sections.map { $0.threads.map(\.id) }, [["pinned"], ["active"], ["snoozed"], ["settled"]])
    }

    func testEmptySectionsAreOmitted() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 2, id: "active", status: "busy"), facts(.running))]), now: now)
        XCTAssertEqual(s.sidebarSections(now: now).map(\.kind), [.active])
    }

    func testScopeAndSearchFilterVisibleThreads() {
        var s = T3WorkspaceState()
        let a = ProjectSummary(id: ProjectSummary.projectId(cwd: "/w/a"), name: "a", cwd: "/w/a", branch: nil, liveCount: 1, lastActivityAt: nil)
        s.apply(inputs([
            (record(pid: 1, id: "s1", cwd: "/w/a"), facts()),
            (record(pid: 2, id: "s2", cwd: "/w/b"), facts()),
        ], projects: [a]), now: now)
        s.scope = .project(id: a.id)
        XCTAssertEqual(s.visibleThreads(now: now).map(\.id), ["s1"])
        s.scope = .all
        s.search = "B"   // titles fall back to the cwd's last path component: "a", "b"
        XCTAssertEqual(s.visibleThreads(now: now).map(\.id), ["s2"])
        XCTAssertEqual(s.sidebarSections(now: now).flatMap { $0.threads.map(\.id) }, ["s2"])
    }

    func testAdjacentThreadWalksTheVisibleOrder() {
        var s = T3WorkspaceState()
        s.apply(inputs([
            (record(pid: 1, id: "pinned"), facts(pinnedAt: now)),
            (record(pid: 2, id: "active"), facts()),
        ]), now: now)
        s.select("pinned", now: now)
        XCTAssertEqual(s.adjacentThreadId(.next, now: now), "active")
        XCTAssertNil(s.adjacentThreadId(.previous, now: now))
        s.select(nil, now: now)
        XCTAssertEqual(s.adjacentThreadId(.next, now: now), "pinned")
    }

    func testToggleTurnAndGroupAreScopedToTheSelectedThread() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1"), facts()), (record(pid: 2, id: "s2"), facts())]), now: now)
        s.select("s1", now: now)
        s.toggleTurn("t1"); s.toggleWorkGroup("g1")
        XCTAssertEqual(s.expandedTurnIds["s1"], ["t1"])
        XCTAssertEqual(s.expandedWorkGroupIds["s1"], ["g1"])
        XCTAssertNil(s.expandedTurnIds["s2"])
        s.toggleTurn("t1")
        XCTAssertEqual(s.expandedTurnIds["s1"], [])
    }

    // B-1 review #4: a session with no birth signal (no startedAt/turn/statusUpdatedAt)
    // falls back to `now` in the bridge; the reducer must freeze that first-seen
    // createdAt/updatedAt so the thread doesn't re-sort/re-diff on every tick.
    func testApplyRemembersFirstSeenCreatedAtForARecordLessThread() {
        var s = T3WorkspaceState()
        let birthless = ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/w/a", status: nil, statusUpdatedAt: nil)
        let f = facts()
        s.apply(T3WorkspaceInputs(records: [birthless], facts: [1: f], progress: [:], startedAt: [:], projects: []), now: now)
        let first = s.threads[0]
        s.apply(T3WorkspaceInputs(records: [birthless], facts: [1: f], progress: [:], startedAt: [:], projects: []),
                now: now.addingTimeInterval(1))
        XCTAssertEqual(s.threads[0], first)
        XCTAssertEqual(s.threads[0].createdAt, first.createdAt)
    }

    // A real statusUpdatedAt (not the bridge's `now` fallback) is a genuine signal;
    // createdAt still freezes to the first-seen value, but updatedAt stays free to move.
    func testApplyFreezesCreatedAtButNotAGenuineStatusUpdatedAt() {
        var s = T3WorkspaceState()
        let r1 = ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/w/a", status: "idle", statusUpdatedAt: now)
        let f = facts()
        s.apply(T3WorkspaceInputs(records: [r1], facts: [1: f], progress: [:], startedAt: [:], projects: []), now: now)
        XCTAssertEqual(s.threads[0].createdAt, now)
        XCTAssertEqual(s.threads[0].updatedAt, now)
        let later = now.addingTimeInterval(1)
        let r2 = ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/w/a", status: "busy", statusUpdatedAt: later)
        s.apply(T3WorkspaceInputs(records: [r2], facts: [1: f], progress: [:], startedAt: [:], projects: []), now: later)
        XCTAssertEqual(s.threads[0].createdAt, now)      // still the first-seen value
        XCTAssertEqual(s.threads[0].updatedAt, later)     // but the real status change is not frozen
    }
}
