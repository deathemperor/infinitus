import Foundation

/// Port of T3 Code's `threadSettled.ts`: the settle/snooze rules the client
/// derives locally (attention "is not a server concept" in T3). `now` is
/// always a parameter, never read inside these functions.
public enum T3ThreadSettled {
    public static let queuedTurnStartGrace: TimeInterval = 120

    /// A user message no turn has adopted yet, within the grace window on
    /// both sides (message clocks come from whichever device sent them).
    public static func hasQueuedTurnStart(_ t: T3Thread, now: Date) -> Bool {
        guard let messageAt = t.latestUserMessageAt else { return false }
        if t.session?.status == .error { return false }
        if abs(now.timeIntervalSince(messageAt)) > queuedTurnStartGrace { return false }
        guard let turn = t.latestTurn else { return true }
        return [turn.requestedAt, turn.startedAt, turn.completedAt].allSatisfy { $0 == nil || $0! < messageAt }
    }

    /// A snoozed thread "raises its hand" when something outranks the
    /// user's snooze: blocked on the user, a fresh failure, or a run that
    /// completed after the snooze was set.
    public static func raisedHandWhileSnoozed(_ t: T3Thread) -> Bool {
        if t.hasPendingApprovals || t.hasPendingUserInput { return true }
        if let s = t.session, s.status == .error, t.snoozedAt.map({ s.updatedAt > $0 }) ?? true { return true }
        if let snoozedAt = t.snoozedAt, let turn = t.latestTurn, turn.state == .completed,
           let completedAt = turn.completedAt, completedAt > snoozedAt { return true }
        return false
    }

    /// A running session IS snoozable — snooze only affects visibility.
    public static func canSnooze(_ t: T3Thread, now: Date) -> Bool {
        if t.hasPendingApprovals || t.hasPendingUserInput { return false }
        return !hasQueuedTurnStart(t, now: now)
    }

    /// Hidden while the wake time is ahead and the thread has not raised its hand.
    public static func effectiveSnoozed(_ t: T3Thread, now: Date) -> Bool {
        guard let wakeAt = t.snoozedUntil, wakeAt > now else { return false }
        return !raisedHandWhileSnoozed(t)
    }

    /// When a previously-snoozed thread woke, or nil if it never snoozed /
    /// is still snoozed. Timer wakes report the wake time itself;
    /// raised-hand wakes report the triggering timestamp.
    public static func wokeAt(_ t: T3Thread, now: Date) -> Date? {
        guard let wakeAt = t.snoozedUntil else { return nil }
        if raisedHandWhileSnoozed(t) {
            if let snoozedAt = t.snoozedAt, let turn = t.latestTurn, turn.state == .completed,
               let completedAt = turn.completedAt, completedAt > snoozedAt { return completedAt }
            return t.session?.updatedAt ?? t.snoozedAt
        }
        return wakeAt <= now ? wakeAt : nil
    }

    /// Compact "wakes in" label: minutes round up so a hidden row never reads "0m".
    public static func snoozeWakeLabel(until: Date, now: Date) -> String {
        let remaining = until.timeIntervalSince(now)
        if remaining <= 0 { return "now" }
        if remaining < 3600 { return "\(max(1, Int((remaining / 60).rounded(.up))))m" }
        if remaining < 86400 { return "\(Int((remaining / 3600).rounded(.up)))h" }
        return "\(Int((remaining / 86400).rounded(.up)))d"
    }

    public enum PresetId: String, Sendable, CaseIterable { case hour, threeHours = "three-hours", evening, tomorrow, nextWeek = "next-week" }
    public struct Preset: Sendable, Equatable {
        public let id: PresetId
        public let label: String
        public let snoozedUntil: Date
    }

    /// "This evening" only while it is more than an hour away; calendar
    /// presets landing on the same instant collapse (Sunday: no "Next week").
    public static func snoozePresets(now: Date, calendar: Calendar = .current) -> [Preset] {
        /// Local-calendar hour on `base`'s day (upstream `setHours(hour, 0, 0, 0)`), never rolling to the next day.
        func at(_ base: Date, hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: calendar.startOfDay(for: base))! }
        func addDays(_ base: Date, _ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: base)! }
        var out = [Preset(id: .hour, label: "In 1 hour", snoozedUntil: now.addingTimeInterval(3600)),
                   Preset(id: .threeHours, label: "In 3 hours", snoozedUntil: now.addingTimeInterval(3 * 3600))]
        let evening = at(now, hour: 18)
        if evening.timeIntervalSince(now) > 3600 { out.append(Preset(id: .evening, label: "This evening", snoozedUntil: evening)) }
        let tomorrow = at(addDays(now, 1), hour: 9)
        out.append(Preset(id: .tomorrow, label: "Tomorrow", snoozedUntil: tomorrow))
        let weekday = calendar.component(.weekday, from: now)          // 1 = Sunday … 7 = Saturday
        let daysUntilMonday = (2 - weekday + 7) % 7 == 0 ? 7 : (2 - weekday + 7) % 7
        let nextWeek = at(addDays(now, daysUntilMonday), hour: 9)
        if nextWeek != tomorrow { out.append(Preset(id: .nextWeek, label: "Next week", snoozedUntil: nextWeek)) }
        return out
    }

    /// When a queued-turn snooze guard expires on its own; nil for user-blocked threads.
    public static func snoozeGateExpiry(_ t: T3Thread, now: Date) -> Date? {
        if t.hasPendingApprovals || t.hasPendingUserInput { return nil }
        guard hasQueuedTurnStart(t, now: now), let messageAt = t.latestUserMessageAt else { return nil }
        return messageAt.addingTimeInterval(queuedTurnStartGrace)
    }
}
