import Foundation

/// When a dead account's countdown ends, ask the engine again instead of
/// waiting for the next minute poll (user 2026-09-05: "countdowns end
/// but it seems to take a long time to revive").
///
/// cswap re-probes an exhausted account at `min(now + 10 min, resetsAt +
/// 60 s)` and `list --json` refreshes a slot that is both due and stale
/// (>180 s), so a snapshot taken shortly after `resetsAt + 60 s` makes
/// the engine fetch that account right then. One slot per call, so a
/// fleet resetting together needs a probe per account — hence the
/// retries, a minute apart, until nothing is dead any more.
public enum RevivalProbe {
    /// The engine's own slack after the advertised reset.
    public static let engineSlack: TimeInterval = 60
    /// A few seconds past the engine's slack so its plan is due.
    public static let margin: TimeInterval = 5
    public static let retries = 3
    public static let retrySpacing: TimeInterval = 65

    /// The soonest reset among the dead, non-disabled accounts — the
    /// instant whose passing is worth a probe. nil when nothing is dead
    /// or no maxed window carries a reset time.
    public static func nextReset(accounts: [Account], now: Date = Date()) -> Date? {
        var soonest: Date?
        for account in accounts where account.disabled != true && AccountVitals.isDead(account.usage) {
            guard let reset = revivesAt(account) else { continue }
            if soonest == nil || reset < soonest! { soonest = reset }
        }
        return soonest
    }

    /// The account's last maxed window's reset — when it is back for good.
    public static func revivesAt(_ account: Account) -> Date? {
        guard let usage = account.usage else { return nil }
        var windows: [UsageWindow] = []
        if let w = usage.fiveHour { windows.append(w) }
        if let w = usage.sevenDay { windows.append(w) }
        windows += usage.scoped ?? []
        let resets = windows.filter { $0.pct >= 100 }.compactMap { $0.resetsAt }.compactMap(parse)
        return resets.max()
    }

    /// The probe instants for a reset: `reset + engineSlack + margin`,
    /// then `retries - 1` more a `retrySpacing` apart. A reset already
    /// past probes from `now`.
    public static func schedule(reset: Date, now: Date = Date()) -> [Date] {
        let first = max(reset.addingTimeInterval(engineSlack + margin), now.addingTimeInterval(margin))
        return (0..<retries).map { first.addingTimeInterval(Double($0) * retrySpacing) }
    }

    /// Whether a revival came before the engine expected it: the account
    /// was due to revive more than `earlyBy` later.
    public static let earlyBy: TimeInterval = 2 * 60
    public static func wasEarly(previous: Account?, now: Date = Date()) -> Bool {
        guard let previous, let due = revivesAt(previous) else { return false }
        return due.timeIntervalSince(now) > earlyBy
    }

    static func parse(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }
}
