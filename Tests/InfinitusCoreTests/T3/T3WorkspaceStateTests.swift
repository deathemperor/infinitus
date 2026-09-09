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

    // B-3 review: `.group` scope filters by every member id, not just one
    // physical project — two same-named checkouts must both show up.
    func testGroupScopeFiltersByMembership() {
        var s = T3WorkspaceState()
        let a = ProjectSummary(id: ProjectSummary.projectId(cwd: "/w/app"), name: "app", cwd: "/w/app", branch: nil, liveCount: 1, lastActivityAt: nil)
        let b = ProjectSummary(id: ProjectSummary.projectId(cwd: "/other/app"), name: "app", cwd: "/other/app", branch: nil, liveCount: 1, lastActivityAt: nil)
        let c = ProjectSummary(id: ProjectSummary.projectId(cwd: "/w/c"), name: "c", cwd: "/w/c", branch: nil, liveCount: 1, lastActivityAt: nil)
        s.apply(inputs([
            (record(pid: 1, id: "s1", cwd: "/w/app"), facts()),
            (record(pid: 2, id: "s2", cwd: "/other/app"), facts()),
            (record(pid: 3, id: "s3", cwd: "/w/c"), facts()),
        ], projects: [a, b, c]), now: now)
        XCTAssertEqual(s.groups.count, 2)   // "app" merges by folder name; "c" stands alone
        let appGroup = s.groups.first { $0.members.count == 2 }!
        s.scope = .group(ids: appGroup.members.map(\.id))
        XCTAssertEqual(Set(s.visibleThreads(now: now).map(\.id)), ["s1", "s2"])
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
    // createdAt still freezes to the first-seen value (startedAt is always nil,
    // #223 — a real latestTurn.requestedAt/statusUpdatedAt is the newest turn/status
    // change, not a creation time), but updatedAt stays free to move.
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

    // E3: a birthless thread's updatedAt used to be pinned to the (also frozen)
    // createdAt forever, because the bridge's own `updatedAt = max(lastActivityAt,
    // createdAt=now)` always picked `now`. Freezing the clock fed into the bridge,
    // rather than post-patching its output, lets real progress activity win the max.
    func testApplyLetsRealActivityMoveABirthlessThreadsUpdatedAt() {
        var s = T3WorkspaceState()
        let birthless = ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/w/a", status: nil, statusUpdatedAt: nil)
        let f = facts()
        let activity = now.addingTimeInterval(0.5)
        let progress = [Int32(1): SessionProgress(lastActivityAt: activity)]
        s.apply(T3WorkspaceInputs(records: [birthless], facts: [1: f], progress: progress, startedAt: [:], projects: []), now: now)
        XCTAssertEqual(s.threads[0].updatedAt, activity)
        s.apply(T3WorkspaceInputs(records: [birthless], facts: [1: f], progress: progress, startedAt: [:], projects: []),
                now: now.addingTimeInterval(1))
        XCTAssertEqual(s.threads[0].updatedAt, activity)
        XCTAssertEqual(s.threads[0].createdAt, now)
    }

    // B: memory for a thread that leaves must not leak forward — a resumed
    // session with the same id gets a fresh first-seen date, not the stale one.
    func testApplyPrunesMemoryForThreadsThatLeaveAndComeBack() {
        var s = T3WorkspaceState()
        let birthless = ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/w/a", status: nil, statusUpdatedAt: nil)
        let f = facts()
        s.apply(T3WorkspaceInputs(records: [birthless], facts: [1: f], progress: [:], startedAt: [:], projects: []), now: now)
        s.select("s1", now: now)
        XCTAssertEqual(s.lastVisitedAt["s1"], now)
        s.apply(T3WorkspaceInputs(records: [], facts: [:], progress: [:], startedAt: [:], projects: []), now: now)
        XCTAssertNil(s.lastVisitedAt["s1"])
        let later = now.addingTimeInterval(100)
        s.apply(T3WorkspaceInputs(records: [birthless], facts: [1: f], progress: [:], startedAt: [:], projects: []), now: later)
        XCTAssertEqual(s.threads[0].createdAt, later)   // fresh first-seen, not the stale `now`
    }

    // E7: ClaudeSessions.list does not dedupe; a resume overlap or a missing
    // field can yield two records for one session under different pids.
    func testApplyDedupesRecordsWithTheSameSessionIdKeepingTheNewer() {
        var s = T3WorkspaceState()
        let older = ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/w/a", status: "idle", statusUpdatedAt: now)
        let newer = ClaudeSessionRecord(pid: 2, sessionId: "s1", cwd: "/w/a", status: "busy", statusUpdatedAt: now.addingTimeInterval(1))
        s.apply(T3WorkspaceInputs(records: [older, newer], facts: [1: facts(), 2: facts()], progress: [:], startedAt: [:], projects: []), now: now)
        XCTAssertEqual(s.threads.map(\.id), ["s1"])
        XCTAssertEqual(s.pid(of: "s1"), 2)
    }

    // E4: the snoozed section wakes soonest-first, not updatedAt-desc — the
    // later-updated thread here wakes later, so it must sort second.
    func testSnoozedSectionOrdersBySoonestWake() {
        var s = T3WorkspaceState()
        let soonerWake = ClaudeSessionRecord(pid: 1, sessionId: "sooner-wake", cwd: "/w/a", status: "idle", statusUpdatedAt: now)
        let laterWake = ClaudeSessionRecord(pid: 2, sessionId: "later-wake", cwd: "/w/a", status: "idle",
                                            statusUpdatedAt: now.addingTimeInterval(1))
        s.apply(T3WorkspaceInputs(records: [soonerWake, laterWake],
                                  facts: [1: facts(snoozedUntil: now.addingTimeInterval(60)),
                                          2: facts(snoozedUntil: now.addingTimeInterval(3600))],
                                  progress: [:], startedAt: [:], projects: []), now: now)
        let snoozed = s.sidebarSections(now: now).first { $0.kind == .snoozed }
        XCTAssertEqual(snoozed?.threads.map(\.id), ["sooner-wake", "later-wake"])
    }

    func testSelectIgnoresAnIdNotInThreads() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())]), now: now)
        s.select("nope", now: now)
        XCTAssertNil(s.selectedThreadId)
        XCTAssertNil(s.lastVisitedAt["nope"])
    }

    // T3SidebarList.swift:131 — no selection walks .previous to the last id.
    func testAdjacentPreviousWithNoSelectionIsLast() {
        var s = T3WorkspaceState()
        s.apply(inputs([
            (record(pid: 1, id: "pinned"), facts(pinnedAt: now)),
            (record(pid: 2, id: "active"), facts()),
        ]), now: now)
        XCTAssertEqual(s.adjacentThreadId(.previous, now: now), "active")
    }

    func testSearchWithNoMatchesReturnsNothing() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1", cwd: "/w/a"), facts())]), now: now)
        s.search = "zzz-does-not-match-anything"
        XCTAssertEqual(s.visibleThreads(now: now), [])
        XCTAssertEqual(s.sidebarSections(now: now), [])
    }
    // MARK: - Drafts (Task 15)

    func testDraftSurvivesApplyAndKeepsItsSelection() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())]), now: now)
        let draft = s.addDraft(projectId: ProjectSummary.projectId(cwd: "/w/a"), now: now)
        XCTAssertTrue(T3WorkspaceState.isDraft(draft))
        s.select(draft, now: now)
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())]), now: now)
        XCTAssertEqual(s.drafts.map(\.id), [draft])
        XCTAssertTrue(s.threads.contains { $0.id == draft })
        XCTAssertEqual(s.selectedThreadId, draft)
        XCTAssertNil(s.pid(of: draft))
    }

    func testDraftsSortAboveActiveThreads() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "active"), facts())]), now: now)
        let draft = s.addDraft(projectId: ProjectSummary.projectId(cwd: "/w/a"), now: now)
        let active = s.sidebarSections(now: now).first { $0.kind == .active }
        XCTAssertEqual(active?.threads.map(\.id), [draft, "active"])
    }

    func testStartedDraftIsReplacedByItsSessionAndSelectionMoves() {
        var s = T3WorkspaceState()
        let draft = s.addDraft(projectId: ProjectSummary.projectId(cwd: "/w/a"), now: now)
        s.select(draft, now: now)
        s.markDraftStarted(draft, pid: 7, now: now)
        s.apply(inputs([(record(pid: 7, id: "s7"), facts())]), now: now)
        XCTAssertTrue(s.drafts.isEmpty)
        XCTAssertEqual(s.threads.map(\.id), ["s7"])
        XCTAssertEqual(s.selectedThreadId, "s7")
    }

    // A record can land a tick before its facts do (`apply` skips a pid with
    // no facts): replacing on record-sight alone would move the selection to
    // an id that is not in `threads` yet.
    func testStartedDraftWaitsForTheRecordsFacts() {
        var s = T3WorkspaceState()
        let draft = s.addDraft(projectId: ProjectSummary.projectId(cwd: "/w/a"), now: now)
        s.select(draft, now: now)
        s.markDraftStarted(draft, pid: 7, now: now)
        s.apply(T3WorkspaceInputs(records: [record(pid: 7, id: "s7")], facts: [:], progress: [:],
                                  startedAt: [:], projects: []), now: now)
        XCTAssertEqual(s.drafts.map(\.id), [draft])
        XCTAssertEqual(s.selectedThreadId, draft)
    }

    /// The relaunch path (B-5 review): a persisted draft's row comes back
    /// under the id its text is stored under, and asking twice cannot stack a
    /// second row for it.
    func testRestoredDraftKeepsItsIdAndIsNotDuplicated() {
        var s = T3WorkspaceState()
        let id = T3WorkspaceState.draftIdPrefix + "9E0B"
        XCTAssertEqual(s.addDraft(id: id, projectId: "project-1", now: now), id)
        s.addDraft(id: id, projectId: "project-1", now: now)
        XCTAssertEqual(s.drafts.map(\.id), [id])
        XCTAssertEqual(s.threads.map(\.id), [id])
        XCTAssertEqual(s.drafts.first?.projectId, "project-1")
    }

    func testRemoveDraftDropsItAndItsSelection() {
        var s = T3WorkspaceState()
        let draft = s.addDraft(projectId: "project-1", now: now)
        s.select(draft, now: now)
        s.removeDraft(draft, now: now)
        XCTAssertTrue(s.drafts.isEmpty)
        XCTAssertNil(s.selectedThreadId)
    }

    // Fix 1: a discarded draft hands its selection to the neighbour, so the
    // window is never left with nothing selected while threads exist.
    func testRemoveDraftFallsBackToTheAdjacentThread() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())]), now: now)
        let draft = s.addDraft(projectId: ProjectSummary.projectId(cwd: "/w/a"), now: now)
        s.select(draft, now: now)
        s.removeDraft(draft, now: now)
        XCTAssertEqual(s.selectedThreadId, "s1")
    }

    // Fix 1 (important #1): a start whose session never appears must not leave
    // the draft "starting" forever — the pending pid expires past the deadline,
    // the draft stays, and the id is reported so the model can say so.
    func testAStartedDraftWhoseSessionNeverAppearsTimesOut() {
        var s = T3WorkspaceState()
        let draft = s.addDraft(projectId: ProjectSummary.projectId(cwd: "/w/a"), now: now)
        s.select(draft, now: now)
        s.markDraftStarted(draft, pid: 7, now: now)
        // Just short of the deadline: still waiting.
        s.apply(inputs([]), now: now, wallClock: now.addingTimeInterval(T3WorkspaceState.startDeadline - 1))
        XCTAssertTrue(s.isDraftStarting(draft))
        XCTAssertTrue(s.draftStartTimeouts.isEmpty)
        // Past it: released, reported, and the draft is still there to edit.
        s.apply(inputs([]), now: now, wallClock: now.addingTimeInterval(T3WorkspaceState.startDeadline + 1))
        XCTAssertFalse(s.isDraftStarting(draft))
        XCTAssertEqual(s.draftStartTimeouts, [draft])
        XCTAssertEqual(s.drafts.map(\.id), [draft])
        XCTAssertEqual(s.selectedThreadId, draft)
        s.clearDraftStartTimeout(draft)
        XCTAssertTrue(s.draftStartTimeouts.isEmpty)
    }

    // …and once expired, a pid REUSE by an unrelated session cannot be taken
    // for this draft's own start.
    func testAnExpiredStartIsNotHijackedByAPidReuse() {
        var s = T3WorkspaceState()
        let draft = s.addDraft(projectId: ProjectSummary.projectId(cwd: "/w/a"), now: now)
        s.select(draft, now: now)
        s.markDraftStarted(draft, pid: 7, now: now)
        s.apply(inputs([]), now: now, wallClock: now.addingTimeInterval(T3WorkspaceState.startDeadline + 1))
        s.apply(inputs([(record(pid: 7, id: "someone-else"), facts())]), now: now)
        XCTAssertEqual(s.drafts.map(\.id), [draft])
        XCTAssertEqual(s.selectedThreadId, draft)
    }

    func testReusableDraftFindsAnUntouchedDraftInTheSameProject() {
        var s = T3WorkspaceState()
        let a = s.addDraft(projectId: "p1", now: now)
        let b = s.addDraft(projectId: "p2", now: now)
        XCTAssertEqual(s.reusableDraftId(projectId: "p1", isUntouched: { _ in true }), a)
        XCTAssertEqual(s.reusableDraftId(projectId: "p2", isUntouched: { _ in true }), b)
        XCTAssertNil(s.reusableDraftId(projectId: "p1", isUntouched: { _ in false }))
        XCTAssertNil(s.reusableDraftId(projectId: "p3", isUntouched: { _ in true }))
        // A draft whose session is already starting is not free to reuse.
        s.markDraftStarted(a, pid: 5, now: now)
        XCTAssertNil(s.reusableDraftId(projectId: "p1", isUntouched: { _ in true }))
    }
}
