import Foundation

/// The phone's own alarms (#86), planned from state it already holds in
/// the snapshot: an exhausted account's limit lifting in ten minutes, and
/// the account the fleet just swapped to. Pure planning — accounts in,
/// alarms out — so the rules run under `swift test`; the phone schedules
/// each as a local `UNNotificationRequest`, re-planned on every snapshot.
/// No push service, no polling, nothing hosted.
public enum FleetAlarms {
    /// How far ahead of the reset the banner lands by default; the Mac's
    /// revive lead (Settings › Notifications) overrides it per snapshot.
    public static let lead: TimeInterval = 10 * 60

    public struct Alarm: Equatable, Sendable {
        public let id: String
        /// nil = now (the swap banner); else a scheduled instant.
        public let fireAt: Date?
        public let title: String
        public let body: String
    }

    public static func name(_ account: Account) -> String {
        account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
    }

    /// One alarm per exhausted account (disabled ones excluded), `lead`
    /// before the reset that governs its return — the same reset the
    /// popup counts down. Resets already inside the lead window get no
    /// alarm: the countdown is on screen, and a past trigger never fires.
    /// A credit cap with no reset blocks indefinitely: nothing to plan.
    public static func resets(accounts: [Account], now: Date,
                              lead: TimeInterval = lead) -> [Alarm] {
        accounts.compactMap { account in
            guard !(account.disabled ?? false),
                  let cause = AccountVitals.cause(account.usage),
                  let reset = WeeklyRoll.parse(cause.resetsAt) else { return nil }
            let fireAt = reset.addingTimeInterval(-lead)
            guard fireAt > now else { return nil }
            let window: String
            switch cause.kind {
            case .session: window = "session"
            case .weekly: window = "weekly"
            case .scoped: window = cause.name ?? "model"
            case .credit: return nil
            }
            return Alarm(id: "reset-\(account.number)", fireAt: fireAt,
                         title: "\(name(account)) resets in \(Int(lead / 60)) min",
                         body: "the \(window) limit lifts at \(clock.string(from: reset))")
        }
    }

    /// The swap banner: only a change between two looks — the first look
    /// seeds, and an unknown account (a fleet without it) says nothing.
    public static func swap(from previous: Int?, to current: Int?,
                            accounts: [Account]) -> Alarm? {
        guard let previous, let current, current != previous,
              let account = accounts.first(where: { $0.number == current }) else { return nil }
        return Alarm(id: "swap", fireAt: nil,
                     title: "swapped to \(name(account))",
                     body: "account \(current) is live — sessions ride it now")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
