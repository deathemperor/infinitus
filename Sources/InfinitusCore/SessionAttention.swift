import Foundation

/// `POST /sessions/<pid>/attention` (#223 phase 3): T3's
/// `thread.settle|unsettle|snooze|unsnooze|pin|unpin` for one session.
/// The reply is the session's fresh `SessionFacts`, so the phone's row
/// updates without waiting for the next snapshot. Guards are the T3
/// decider's (`decider.ts` @ t3code acc0a219e).
public enum SessionAttention {
    public struct Request: Codable, Sendable, Equatable {
        public let action: AttentionStore.Action
        /// The wake time; snooze only (T3 `snoozedUntil`).
        public let until: Date?
        public init(action: AttentionStore.Action, until: Date?) { self.action = action; self.until = until }
    }

    public enum Outcome: Sendable, Equatable {
        case applied(SessionFacts)
        /// 409: "snooze refuses while waiting on you" (decider.ts 626-640).
        case refused(String)
        /// 400: snooze without a future `until` (decider.ts 618-624).
        case badRequest
    }

    public static func apply(_ request: Request, sessionId: String, timeline: SessionTimeline, status: String?,
                             store: AttentionStore, now: Date = Date()) -> Outcome {
        if request.action == .snooze {
            guard let until = request.until, until > now else { return .badRequest }
            let before = SessionFacts.derive(timeline: timeline, status: status, attention: store.entry(sessionId: sessionId))
            if before.hasPendingApprovals || before.hasPendingUserInput { return .refused("waiting") }
        }
        let entry = store.apply(request.action, sessionId: sessionId, until: request.until, now: now)
        return .applied(SessionFacts.derive(timeline: timeline, status: status, attention: entry))
    }
}
