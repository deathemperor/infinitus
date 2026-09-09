import Foundation

/// `SessionTimeline` (+ owned pending) → the rows reducer's `Input` (Task 9):
/// the same fields the phone's mirror route (`AppModel.mirrorServer.timeline`)
/// derives per pid, trimmed to what `T3TimelineRows.derive` reads.
public enum T3TimelineInput {
    /// `ended`: the session this timeline belongs to is gone (#400) — the
    /// thread stays open, but its facts froze at their last value, so a
    /// `running` status there is stale and must not keep a Working row (and
    /// its elapsed counter) alive. The phone gates its Working pill the same
    /// way (`T3ThreadScreen.working`). The rows themselves are untouched.
    public static func make(timeline: SessionTimeline, pending: [PendingRequest], facts: SessionFacts?,
                            expandedTurnIds: Set<String>, expandedWorkGroupIds: Set<String>,
                            ended: Bool = false) -> T3TimelineRows.Input {
        let latest = timeline.latestTurn
        let latestTurnRunning = latest?.state == .running
        let latestTurn = latest.map {
            T3TimelineRows.LatestTurn(turnId: $0.id, state: $0.state, startedAt: $0.startedAt, completedAt: $0.completedAt)
        }
        return T3TimelineRows.Input(
            entries: T3TimelineEntry.entries(from: timeline, pending: pending),
            latestTurn: latestTurn,
            runningTurnId: latestTurnRunning ? latest?.id : nil,
            expandedTurnIds: expandedTurnIds,
            expandedWorkGroupIds: expandedWorkGroupIds,
            isWorking: !ended && (facts?.status == .running || latestTurnRunning),
            activeTurnStartedAt: !ended && latestTurnRunning ? (latest?.startedAt ?? latest?.requestedAt) : nil,
            turnDiffSummaries: [],
            supportsConversationRollback: false)
    }
}
