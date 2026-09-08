import Foundation

/// T3 Code's thread shell as the settle/snooze rules see it
/// (`OrchestrationThreadShell` upstream) — the session/turn/snooze fields
/// `T3ThreadStatus` and `T3ThreadSettled` derive over, nothing more.
public struct T3Thread: Sendable, Equatable {
    public enum SessionStatus: String, Sendable, CaseIterable { case idle, starting, running, ready, interrupted, stopped, error }

    public struct Session: Sendable, Equatable {
        public var status: SessionStatus
        public var updatedAt: Date
        public init(status: SessionStatus, updatedAt: Date) {
            self.status = status
            self.updatedAt = updatedAt
        }
    }

    public struct Turn: Sendable, Equatable {
        public enum State: String, Sendable, CaseIterable { case running, interrupted, completed, error }
        public var state: State
        public var requestedAt: Date
        public var startedAt: Date?
        public var completedAt: Date?
        public init(state: State, requestedAt: Date, startedAt: Date?, completedAt: Date?) {
            self.state = state
            self.requestedAt = requestedAt
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }

    public var id: String
    public var environmentId: String
    public var projectId: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var pinnedAt: Date?
    public var pinOrderKey: String?
    public var activeOrderKey: String?
    public var settledOverride: AttentionStore.SettledOverride?
    public var settledAt: Date?
    public var unsettledAt: Date?
    public var snoozedUntil: Date?
    public var snoozedAt: Date?
    public var hasPendingApprovals: Bool
    public var hasPendingUserInput: Bool
    public var hasActionableProposedPlan: Bool
    public var latestUserMessageAt: Date?
    public var latestTurn: Turn?
    public var session: Session?
    public var lastVisitedAt: Date?

    public init(id: String, environmentId: String = "environment-1", projectId: String = "project-1", title: String,
                createdAt: Date, updatedAt: Date, archivedAt: Date? = nil, pinnedAt: Date? = nil,
                pinOrderKey: String? = nil, activeOrderKey: String? = nil,
                settledOverride: AttentionStore.SettledOverride? = nil, settledAt: Date? = nil, unsettledAt: Date? = nil,
                snoozedUntil: Date? = nil, snoozedAt: Date? = nil,
                hasPendingApprovals: Bool = false, hasPendingUserInput: Bool = false, hasActionableProposedPlan: Bool = false,
                latestUserMessageAt: Date? = nil, latestTurn: Turn? = nil, session: Session? = nil, lastVisitedAt: Date? = nil) {
        self.id = id
        self.environmentId = environmentId
        self.projectId = projectId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.pinnedAt = pinnedAt
        self.pinOrderKey = pinOrderKey
        self.activeOrderKey = activeOrderKey
        self.settledOverride = settledOverride
        self.settledAt = settledAt
        self.unsettledAt = unsettledAt
        self.snoozedUntil = snoozedUntil
        self.snoozedAt = snoozedAt
        self.hasPendingApprovals = hasPendingApprovals
        self.hasPendingUserInput = hasPendingUserInput
        self.hasActionableProposedPlan = hasActionableProposedPlan
        self.latestUserMessageAt = latestUserMessageAt
        self.latestTurn = latestTurn
        self.session = session
        self.lastVisitedAt = lastVisitedAt
    }
}
