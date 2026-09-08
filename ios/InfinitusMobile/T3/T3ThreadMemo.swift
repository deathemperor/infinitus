import Foundation
import InfinitusCore

/// The thread screen's rows and pending cards, derived once per
/// (timeline, facts, expansion) and handed back until one changes — the
/// same shape as Core's `ThreadRowsMemo` (#380): a computed `rows` ran
/// `T3TimelineRows.derive` (and `T3Pending.derive` inside it) on every
/// body pass and once more for `rows.last`. Compare-by-value on the
/// timeline is a fraction of a derivation; the follower's sequence and
/// synchronized flag are left out of the key because they don't feed it.
@MainActor final class T3ThreadMemo {
    private var timeline: SessionTimeline?
    private var facts: SessionFacts?
    private var turns: Set<String> = []
    private var groups: Set<String> = []
    private(set) var pending = T3Pending.Live()
    private(set) var rows: [T3TimelineRows.Row] = []
    /// Perf probe: derivations so far.
    private(set) var derivations = 0

    @discardableResult
    func update(state: TimelineFollower.State, expandedTurnIds: Set<String>,
                expandedWorkGroupIds: Set<String>) -> T3ThreadMemo {
        if let cached = timeline, cached == state.timeline, facts == state.facts,
           turns == expandedTurnIds, groups == expandedWorkGroupIds { return self }
        pending = T3Pending.derive(state.timeline)
        rows = T3TimelineRows.derive(T3ThreadScreen.timelineInput(
            state: state, hiddenActivityIds: pending.activityIds,
            expandedTurnIds: expandedTurnIds, expandedWorkGroupIds: expandedWorkGroupIds))
        timeline = state.timeline
        facts = state.facts
        turns = expandedTurnIds
        groups = expandedWorkGroupIds
        derivations += 1
        return self
    }
}
