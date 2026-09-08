import XCTest
@testable import InfinitusCore

final class T3ThreadBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func record(_ status: String? = "idle", name: String? = nil, statusAt: Date? = nil) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: 42, sessionId: "sess-1", cwd: "/Users/me/death/limitless", status: status,
                            name: name, statusUpdatedAt: statusAt)
    }
    private func facts(status: SessionFacts.Status = .ready, approvals: Bool = false, input: Bool = false,
                       turn: SessionTimeline.Turn? = nil, pinnedAt: Date? = nil,
                       settled: AttentionStore.SettledOverride? = nil, snoozedUntil: Date? = nil) -> SessionFacts {
        SessionFacts(status: status, hasPendingApprovals: approvals, hasPendingUserInput: input, hasPlan: false,
                     latestTurn: turn, planProgress: nil, latestUserMessageAt: turn?.requestedAt,
                     settledOverride: settled, settledAt: settled == .settled ? now : nil, unsettledAt: nil,
                     snoozedUntil: snoozedUntil, snoozedAt: snoozedUntil == nil ? nil : now, pinnedAt: pinnedAt)
    }

    func testIdentityAndProject() {
        let t = T3Thread(record: record(), facts: facts(), progress: nil, startedAt: nil, now: now)
        XCTAssertEqual(t.id, "sess-1")
        XCTAssertEqual(t.environmentId, T3Thread.localEnvironmentId)
        XCTAssertEqual(t.projectId, ProjectSummary.projectId(cwd: "/Users/me/death/limitless"))
        XCTAssertEqual(t.title, SessionNaming.displayName(name: nil, autoName: nil, cwd: "/Users/me/death/limitless"))
    }

    private func progress(autoName: String? = nil, lastActivityAt: Date? = nil) -> SessionProgress {
        var p = SessionProgress(lastActivityAt: lastActivityAt, nowDoing: nil, todos: nil, title: nil, goal: nil)
        p.autoName = autoName
        return p
    }

    func testTitlePrefersRecordNameThenAutoName() {
        XCTAssertEqual(T3Thread(record: record(name: "Fix login"), facts: facts(), progress: progress(autoName: "auto"), startedAt: nil, now: now).title, "Fix login")
        XCTAssertEqual(T3Thread(record: record(), facts: facts(), progress: progress(autoName: "Auto name"), startedAt: nil, now: now).title, "Auto name")
    }

    func testProjectFromSummary() {
        let s = ProjectSummary(id: "abc", name: "limitless", cwd: "/Users/me/death/limitless", branch: "main", liveCount: 1, lastActivityAt: nil)
        let p = T3ProjectGrouping.Project(summary: s)
        XCTAssertEqual(p.id, "abc"); XCTAssertEqual(p.name, "limitless"); XCTAssertEqual(p.cwd, s.cwd)
        XCTAssertEqual(p.environmentId, T3Thread.localEnvironmentId)
        XCTAssertEqual(T3ProjectGrouping.physicalKey(p), "local:abc")
    }

    func testStatusMapsOneToOne() {
        for s in SessionFacts.Status.allCases {
            let t = T3Thread(record: record(), facts: facts(status: s), progress: nil, startedAt: nil, now: now)
            XCTAssertEqual(t.session?.status.rawValue, s.rawValue)
        }
    }

    func testTurnStateMapsOneToOne() {
        for s in SessionTimeline.Turn.State.allCases {
            let turn = SessionTimeline.Turn(id: "t", state: s, requestedAt: now, startedAt: now, completedAt: nil,
                                            userMessageId: "u", assistantMessageId: nil)
            let t = T3Thread(record: record(), facts: facts(turn: turn), progress: nil, startedAt: nil, now: now)
            XCTAssertEqual(t.latestTurn?.state.rawValue, s.rawValue)
            XCTAssertEqual(t.latestTurn?.requestedAt, now)
        }
    }

    func testTimestampsFallBackInOrder() {
        let started = now.addingTimeInterval(-600), statusAt = now.addingTimeInterval(-60)
        let t = T3Thread(record: record(statusAt: statusAt), facts: facts(), progress: nil, startedAt: started, now: now)
        XCTAssertEqual(t.createdAt, started)
        XCTAssertEqual(t.updatedAt, statusAt)
        XCTAssertEqual(t.session?.updatedAt, statusAt)
        let bare = T3Thread(record: record(), facts: facts(), progress: nil, startedAt: nil, now: now)
        XCTAssertEqual(bare.createdAt, now)
        XCTAssertEqual(bare.updatedAt, now)
    }

    func testUpdatedAtIsTheLatestSignal() {
        let statusAt = now.addingTimeInterval(-300), activity = now.addingTimeInterval(-30)
        let t = T3Thread(record: record(statusAt: statusAt), facts: facts(), progress: progress(lastActivityAt: activity), startedAt: nil, now: now)
        XCTAssertEqual(t.updatedAt, activity)
    }

    func testAttentionFieldsCopyThrough() {
        let until = now.addingTimeInterval(3600)
        let t = T3Thread(record: record(), facts: facts(approvals: true, pinnedAt: now, settled: .settled, snoozedUntil: until),
                         progress: nil, startedAt: nil, now: now)
        XCTAssertTrue(t.hasPendingApprovals)
        XCTAssertEqual(t.pinnedAt, now)
        XCTAssertEqual(t.settledOverride, .settled)
        XCTAssertEqual(t.settledAt, now)
        XCTAssertEqual(t.snoozedUntil, until)
        XCTAssertEqual(t.snoozedAt, now)
        XCTAssertFalse(t.hasActionableProposedPlan)
        XCTAssertNil(t.archivedAt)
    }

    // MARK: - Mirror overload (lifted from ios/InfinitusMobileTests/T3HomeTests.swift,
    // adapted to T3Thread(session:facts:progress:environmentId:now:))

    private func mirrorSession(_ status: String) -> SessionDetail {
        SessionDetail(pid: 7, cwd: "/r/limitless", status: status, kind: "claude", startedAt: 900_000_000)
    }

    func testMirrorFactsNilUsesEngineWord() {
        func t(_ status: String) -> T3Thread {
            T3Thread(session: mirrorSession(status), facts: nil, progress: nil, environmentId: "mac-2", now: now)
        }
        XCTAssertEqual(t("busy").session?.status, .running)
        XCTAssertTrue(t("waiting").hasPendingApprovals)
        XCTAssertFalse(t("busy").hasPendingApprovals)
        XCTAssertFalse(t("idle").hasPendingApprovals)
        XCTAssertEqual(t("idle").session?.status, .idle)
        XCTAssertNil(t("idle").settledOverride)
        XCTAssertEqual(t("idle").id, "pid:7")
    }

    func testMirrorFactsPresentUsesIsSettled() {
        let settledFacts = SessionFacts(status: .ready, hasPendingApprovals: false, hasPendingUserInput: false,
                                        hasPlan: false, latestTurn: nil, planProgress: nil, latestUserMessageAt: nil,
                                        settledOverride: nil, settledAt: now, unsettledAt: nil,
                                        snoozedUntil: nil, snoozedAt: nil, pinnedAt: nil)
        let t = T3Thread(session: mirrorSession("idle"), facts: settledFacts, progress: nil, environmentId: "mac-2", now: now)
        XCTAssertEqual(t.settledOverride, .settled)
    }

    func testMirrorFactsPresentUnsettledIsActive() {
        let unsettledFacts = SessionFacts(status: .ready, hasPendingApprovals: false, hasPendingUserInput: false,
                                          hasPlan: false, latestTurn: nil, planProgress: nil, latestUserMessageAt: nil,
                                          settledOverride: nil, settledAt: nil, unsettledAt: nil,
                                          snoozedUntil: nil, snoozedAt: nil, pinnedAt: nil)
        let t = T3Thread(session: mirrorSession("idle"), facts: unsettledFacts, progress: nil, environmentId: "mac-2", now: now)
        XCTAssertEqual(t.settledOverride, .active)
    }
}
