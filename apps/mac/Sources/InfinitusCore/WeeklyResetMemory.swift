import Foundation

/// Cross-poll memory of each account's 7-day reset slot (issue #16).
/// Anthropic's weekly window resets at a FIXED time each week, assigned
/// per account (support.claude.com "How do usage and length limits
/// work"), but the usage endpoint reports no `resets_at` while the
/// window's usage is 0 — so the engine shows an untouched account as
/// bare `"sevenDay": {"pct": 0}`. Any resetsAt this app ever saw for the
/// account pins its slot: the next reset is that instant stepped
/// forward by whole weeks (user 2026-09-03: a fresh account's first
/// message showed "Resets Fri 8:00 AM" — the very slot remembered).
///
/// Fed by `UsageHistoryRecorder` (an actor) and read by MainActor
/// SwiftUI views, so this is a lock, not actor isolation — reads from
/// the UI stay synchronous.
public final class WeeklyResetMemory: @unchecked Sendable {
    public static let shared = WeeklyResetMemory()

    private let lock = NSLock()
    private var byEmail: [String: Date] = [:]

    /// Public so tests can exercise an isolated instance instead of the
    /// process-wide singleton.
    public init() {}

    /// Records a resetsAt seen for `email`'s 7-day window. Keeps the
    /// latest — a stale poll racing a fresher one must never regress it.
    public func note(email: String, resetsAt: Date) {
        lock.lock(); defer { lock.unlock() }
        if let existing = byEmail[email], existing >= resetsAt { return }
        byEmail[email] = resetsAt
    }

    /// The next reset in `email`'s weekly slot: the remembered instant,
    /// stepped forward by whole weeks until it's ahead of `now`.
    public func futureReset(email: String, now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let d = byEmail[email] else { return nil }
        return Self.nextInSlot(d, after: now)
    }

    static func nextInSlot(_ seen: Date, after now: Date) -> Date {
        let week: TimeInterval = 7 * 24 * 3600
        guard seen <= now else { return seen }
        let weeks = ((now.timeIntervalSince(seen)) / week).rounded(.down) + 1
        return seen.addingTimeInterval(weeks * week)
    }

    /// Seeds from history samples (the existing usage-history JSONL) so
    /// a fresh launch doesn't forget what a prior session already saw.
    public func seed(from samples: [UsageSample]) {
        for s in samples {
            guard let ts = s.sevenDay?.resetsAt else { continue }
            note(email: s.email, resetsAt: Date(timeIntervalSince1970: ts))
        }
    }
}

/// The Ready cell's weekly-reset caption, decided as pure data so it's
/// testable without the singleton above. `remembered` is passed in
/// rather than read here.
public enum ReadyWeeklyCaption {
    /// - Parameters:
    ///   - pct/resetsAt/countdown/clock: the account's live sevenDay window.
    ///   - remembered: the last resetsAt this app has observed for the
    ///     account (`WeeklyResetMemory.futureReset`), or nil.
    ///   - compact: the popup's short vocabulary.
    /// - Returns: nil only when there's truly nothing to say (a positive
    ///   pct with no reset info at all — the pre-existing behavior).
    public static func text(pct: Double, resetsAt: String?, countdown: String?,
                            clock: String?, remembered: Date?,
                            now: Date = Date(), compact: Bool = false) -> String? {
        if let when = compact
            ? ResetLabel.compact(resetsAt: resetsAt, countdown: countdown, now: now)
            : ResetLabel.label(resetsAt: resetsAt, countdown: countdown,
                              clock: clock, now: now) {
            return when
        }
        guard pct <= 0 else { return nil }
        if let remembered, remembered > now {
            // The account's fixed weekly slot, from memory — as good as
            // the engine's own figure, so it wears the same label.
            let iso = ISO8601DateFormatter().string(from: remembered)
            return compact
                ? ResetLabel.compact(resetsAt: iso, countdown: nil, now: now)
                : ResetLabel.label(resetsAt: iso, countdown: nil, clock: nil, now: now)
        }
        // Never seen this account's slot: the first message reveals it.
        return compact ? "7d: slot unknown" : "7d reset unknown until first use"
    }
}
