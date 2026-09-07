import Foundation

/// What a session row says about attention (#223 phase 3, T3
/// `threadListV2.ts:30`): derived on the client from the host's facts,
/// never a server state. Rank order is fixed — a pending approval beats
/// a pending question beats work in flight beats a failure beats ready.
public enum SessionListPresentation {
    public enum Attention: String, Codable, Sendable, CaseIterable {
        case approval, input, working, failed, ready
    }

    /// The row's attention from its facts; without facts (no lease yet,
    /// an older Mac) the engine's status word decides: busy is working,
    /// waiting is an approval, anything else is ready.
    public static func attention(_ facts: SessionFacts?, fallbackStatus: String?) -> Attention {
        guard let facts else {
            switch fallbackStatus {
            case "busy": return .working
            case "waiting": return .approval
            default: return .ready
            }
        }
        if facts.hasPendingApprovals { return .approval }
        if facts.hasPendingUserInput { return .input }
        switch facts.status {
        case .running, .starting: return .working
        case .error, .interrupted: return .failed
        case .idle, .ready, .stopped: return .ready
        }
    }

    /// "2 of 5 · Wire the phone" — the plan line under a row, nil without a plan.
    public static func planLine(_ facts: SessionFacts?) -> String? {
        guard let p = facts?.planProgress, p.total > 0 else { return nil }
        let count = "\(p.completed) of \(p.total)"
        return p.step.map { "\(count) · \($0)" } ?? count
    }

    /// Snoozed until a time still ahead — unless the session raised its
    /// hand since (T3 `threadRaisedHandWhileSnoozed`): an approval, a
    /// question, a failure or a finished turn after the snooze wakes it.
    public static func isSnoozed(_ facts: SessionFacts, now: Date = Date()) -> Bool {
        guard let until = facts.snoozedUntil, until > now else { return false }
        let since = facts.snoozedAt ?? .distantPast
        if facts.hasPendingApprovals || facts.hasPendingUserInput { return false }
        if let turn = facts.latestTurn, let ended = turn.completedAt, ended > since { return false }
        return true
    }

    /// Settled: shelved by hand, or automatically by the host, unless
    /// the user un-settled it since.
    public static func isSettled(_ facts: SessionFacts) -> Bool {
        switch facts.settledOverride {
        case .settled?: return true
        case .active?: return false
        case nil: return facts.settledAt != nil && (facts.unsettledAt.map { $0 < facts.settledAt! } ?? true)
        }
    }
}
