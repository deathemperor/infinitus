import Foundation

/// Infinitus facts → T3's thread shell (spec §2.2 / §4.3): the one place a
/// live session becomes the `T3Thread` that `T3SidebarList`, `T3ThreadSort`,
/// `T3ThreadSettled` and `T3ThreadStatus` reason over. The phone has the
/// same mapping at its seam; the Mac window uses this one.
extension T3Thread {
    /// The Mac's own sessions; remote environments arrive with the team
    /// mirror (F), never here.
    public static let localEnvironmentId = "local"

    public init(record: ClaudeSessionRecord, facts: SessionFacts,
                progress: SessionProgress?, startedAt: Date?, now: Date) {
        let turn = facts.latestTurn.map {
            Turn(state: Turn.State($0.state),
                 requestedAt: $0.requestedAt, startedAt: $0.startedAt, completedAt: $0.completedAt)
        }
        let createdAt = startedAt ?? facts.latestTurn?.requestedAt ?? record.statusUpdatedAt ?? now
        let turnAt = facts.latestTurn.map { $0.completedAt ?? $0.startedAt ?? $0.requestedAt }
        let updatedAt = [progress?.lastActivityAt, record.statusUpdatedAt, turnAt, createdAt]
            .compactMap { $0 }.max() ?? now
        self.init(id: record.sessionId,
                  environmentId: Self.localEnvironmentId,
                  projectId: ProjectSummary.projectId(cwd: record.cwd),
                  title: SessionNaming.displayName(name: record.name, autoName: progress?.autoName, cwd: record.cwd),
                  createdAt: createdAt, updatedAt: updatedAt,
                  pinnedAt: facts.pinnedAt,
                  settledOverride: SessionListPresentation.isSettled(facts) ? .settled : .active,
                  settledAt: facts.settledAt, unsettledAt: facts.unsettledAt,
                  snoozedUntil: facts.snoozedUntil, snoozedAt: facts.snoozedAt,
                  hasPendingApprovals: facts.hasPendingApprovals, hasPendingUserInput: facts.hasPendingUserInput,
                  hasActionableProposedPlan: false,
                  latestUserMessageAt: facts.latestUserMessageAt, latestTurn: turn,
                  session: Session(status: SessionStatus(facts.status),
                                   updatedAt: record.statusUpdatedAt ?? updatedAt))
    }

    /// The phone's row shape (team mirror, #337): `SessionDetail` + optional facts.
    /// `SessionFacts` carries no session id, so the id is always the pid form here
    /// (the record init above keeps `record.sessionId`).
    /// Facts nil → status from the engine word, approvals from "waiting".
    public init(session: SessionDetail, facts: SessionFacts?, progress: SessionProgress?,
                environmentId: String, now: Date) {
        let createdAt = Date(timeIntervalSince1970: session.startedAt / 1000)
        let turn = facts?.latestTurn.map {
            Turn(state: Turn.State($0.state),
                 requestedAt: $0.requestedAt, startedAt: $0.startedAt, completedAt: $0.completedAt)
        }
        let turnAt = facts?.latestTurn.map { $0.completedAt ?? $0.startedAt ?? $0.requestedAt }
        let updatedAt = [progress?.lastActivityAt, turnAt, createdAt].compactMap { $0 }.max() ?? now
        let status: SessionStatus = facts.map { SessionStatus($0.status) }
            ?? (session.status == "busy" ? .running : .idle)
        self.init(id: "pid:\(session.pid)",
                  environmentId: environmentId,
                  projectId: ProjectSummary.projectId(cwd: session.cwd),
                  title: SessionNaming.displayName(name: progress?.name, autoName: progress?.autoName, cwd: session.cwd),
                  createdAt: createdAt, updatedAt: updatedAt,
                  pinnedAt: facts?.pinnedAt,
                  settledOverride: facts.map { SessionListPresentation.isSettled($0) ? .settled : .active },
                  settledAt: facts?.settledAt, unsettledAt: facts?.unsettledAt,
                  snoozedUntil: facts?.snoozedUntil, snoozedAt: facts?.snoozedAt,
                  hasPendingApprovals: facts?.hasPendingApprovals ?? (session.status == "waiting"),
                  hasPendingUserInput: facts?.hasPendingUserInput ?? false,
                  hasActionableProposedPlan: false,
                  latestUserMessageAt: facts?.latestUserMessageAt, latestTurn: turn,
                  session: Session(status: status, updatedAt: updatedAt))
    }
}

extension T3ProjectGrouping.Project {
    /// `ProjectSummary` (the mirror's `projects`) → T3's project row; the
    /// same rule on both clients so grouping keys agree.
    public init(summary: ProjectSummary, environmentId: String = T3Thread.localEnvironmentId) {
        self.init(id: summary.id, environmentId: environmentId, name: summary.name, cwd: summary.cwd)
    }
}
