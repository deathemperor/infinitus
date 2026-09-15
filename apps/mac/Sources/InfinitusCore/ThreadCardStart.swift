import Foundation

/// The thread card's start hold (#1277). A push-to-start makes iOS start a
/// NEW activity every time, and the card's own update token reaches the
/// Mac only once the phone has run and registered it; with every state
/// change going push-to-start meanwhile, a slow phone stacked five cards.
/// So after a start goes out the device is "started, unreported": later
/// states are held — the latest wins, nothing queued deeper — until the
/// phone's `agent-activity` token registers and the held state goes out
/// at once as an update; an end while unreported is held the same way. The
/// hold lapses with the started card's stale window, after which a fresh
/// push-to-start is allowed. A registration clears the hold whatever its
/// timing.
public enum ThreadCardStart {
    public struct Hold: Equatable, Sendable {
        public enum Pending: Equatable, Sendable {
            case none
            case update(AgentActivityState)
            case end
        }

        public let startedAt: Date
        public internal(set) var pending: Pending = .none

        public init(startedAt: Date) { self.startedAt = startedAt }

        public func lapsed(now: Date) -> Bool {
            now.timeIntervalSince(startedAt) > LiveActivityPush.staleAfter
        }
    }

    /// What `pushAgentActivity` does for one device.
    public enum Action: Equatable, Sendable {
        /// Send the state to the live token as an update (or the end).
        case update, end
        /// Send the state to the push-to-start token; a hold begins.
        case start
        /// Kept for the token's arrival, nothing sent.
        case held
        case none
    }

    /// The plan for a state (`nil` ends the card) given what the device
    /// holds. A hold still in force takes the state and sends nothing; a
    /// lapsed one is dropped and the device is planned afresh.
    public static func plan(state: AgentActivityState?, live: Bool, start: Bool, hold: Hold?,
                            now: Date) -> (action: Action, hold: Hold?) {
        if var hold, !hold.lapsed(now: now) {
            hold.pending = state.map { .update($0) } ?? .end
            return (.held, hold)
        }
        if live { return (state == nil ? .end : .update, nil) }
        guard start, state != nil else { return (.none, nil) }
        return (.start, Hold(startedAt: now))
    }

    /// What goes out when the phone registers the started card's token:
    /// the held state as an update, the held end, or nothing.
    public static func release(_ hold: Hold) -> Action {
        switch hold.pending {
        case .none: return .none
        case .update: return .update
        case .end: return .end
        }
    }
}
