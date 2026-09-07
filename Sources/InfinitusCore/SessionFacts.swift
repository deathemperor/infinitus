import Foundation

/// T3's shell row for one session (#223 phase 3): what the list needs
/// without the timeline body (contracts `orchestration.ts` ThreadShell).
/// Attention is "not a server concept" in T3 — the client derives
/// `approval > input > working > failed > ready` (`threadListV2.ts:30`)
/// and settled/snoozed (`threadSettled.ts`) from these inputs.
public struct SessionFacts: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case idle, starting, running, ready, interrupted, stopped, error }

    public struct PlanProgress: Codable, Sendable, Equatable {
        public let step: String?
        public let completed: Int
        public let total: Int
        public init(step: String?, completed: Int, total: Int) {
            self.step = step; self.completed = completed; self.total = total
        }
    }

    public let status: Status
    public let hasPendingApprovals: Bool
    public let hasPendingUserInput: Bool
    /// The boolean only, never the plan body (upstream eb8ed803).
    public let hasPlan: Bool
    public let latestTurn: SessionTimeline.Turn?
    public let planProgress: PlanProgress?
    public let latestUserMessageAt: Date?
    public let settledOverride: AttentionStore.SettledOverride?
    public let settledAt: Date?
    public let unsettledAt: Date?
    public let snoozedUntil: Date?
    public let snoozedAt: Date?
    public let pinnedAt: Date?

    /// `status` is the session record's ("busy", "waiting", "idle",
    /// "shell", nil). Busy and waiting are running turns; everything
    /// else is read off the latest turn (spec §2, T3 `projector.ts:78-93`).
    /// `.starting` and `.stopped` are reserved for owned sessions before
    /// their first turn and past sessions (#164).
    public static func derive(timeline: SessionTimeline, status: String?, attention: AttentionStore.Entry) -> SessionFacts {
        let latest = timeline.latestTurn
        let state: Status
        if status == "busy" || status == "waiting" {
            state = .running
        } else {
            switch latest?.state {
            case nil: state = .idle
            case .completed: state = .ready
            case .interrupted: state = .interrupted
            case .error: state = .error
            case .running: state = .running
            }
        }
        let pending = PendingRequests.derive(timeline.activities)
        let plan = timeline.activities.last { $0.kind == "turn.plan.updated" }
        let progress = plan.map { p -> PlanProgress in
            let steps = p.payload["steps"]?.arrayValue ?? []
            let current = steps.first { $0.objectValue?["status"]?.stringValue == "in_progress" }
            return PlanProgress(step: current?.objectValue?["text"]?.stringValue,
                                completed: Int(p.payload["completed"]?.numberValue ?? 0),
                                total: Int(p.payload["total"]?.numberValue ?? 0))
        }
        return SessionFacts(status: state,
                            hasPendingApprovals: !pending.approvals.isEmpty,
                            hasPendingUserInput: !pending.userInputs.isEmpty,
                            hasPlan: plan != nil,
                            latestTurn: latest,
                            planProgress: progress,
                            latestUserMessageAt: timeline.messages.last { $0.role == .user }?.createdAt,
                            settledOverride: attention.settledOverride,
                            settledAt: attention.settledAt,
                            unsettledAt: attention.unsettledAt,
                            snoozedUntil: attention.snoozedUntil,
                            snoozedAt: attention.snoozedAt,
                            pinnedAt: attention.pinnedAt)
    }

    public init(status: Status, hasPendingApprovals: Bool, hasPendingUserInput: Bool, hasPlan: Bool,
                latestTurn: SessionTimeline.Turn?, planProgress: PlanProgress?, latestUserMessageAt: Date?,
                settledOverride: AttentionStore.SettledOverride?, settledAt: Date?, unsettledAt: Date?,
                snoozedUntil: Date?, snoozedAt: Date?, pinnedAt: Date?) {
        self.status = status; self.hasPendingApprovals = hasPendingApprovals
        self.hasPendingUserInput = hasPendingUserInput; self.hasPlan = hasPlan
        self.latestTurn = latestTurn; self.planProgress = planProgress
        self.latestUserMessageAt = latestUserMessageAt; self.settledOverride = settledOverride
        self.settledAt = settledAt; self.unsettledAt = unsettledAt
        self.snoozedUntil = snoozedUntil; self.snoozedAt = snoozedAt; self.pinnedAt = pinnedAt
    }
}
