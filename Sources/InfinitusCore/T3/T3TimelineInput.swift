import Foundation

/// `SessionTimeline` (+ owned pending) → the rows reducer's `Input` (Task 9):
/// the same fields the phone's mirror route (`AppModel.mirrorServer.timeline`)
/// derives per pid, trimmed to what `T3TimelineRows.derive` reads.
public enum T3TimelineInput {
    public static func make(timeline: SessionTimeline, pending: [PendingRequest], facts: SessionFacts?,
                            expandedTurnIds: Set<String>, expandedWorkGroupIds: Set<String>) -> T3TimelineRows.Input {
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
            isWorking: facts?.status == .running || latestTurnRunning,
            activeTurnStartedAt: latestTurnRunning ? (latest?.startedAt ?? latest?.requestedAt) : nil,
            turnDiffSummaries: [],
            supportsConversationRollback: false)
    }
}
