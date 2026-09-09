import Foundation
import InfinitusCore

/// The Limits tab's arithmetic (T3 `packages/shared/src/usageLimits.ts` at
/// upstream 6c583620f: `collectLimitPools`, `remainingPercent`,
/// `elapsedShare`, `paceOf`, `formatDuration`, `formatResetsIn`), over the
/// engines' `Account.usage` instead of T3's `ServerProviderUsageWindow`.
/// Every figure anchors to a `now` the screen passes in: nothing here ticks.
enum T3UsageLimits {
    static let sessionSeconds: TimeInterval = 5 * 3600
    static let weekSeconds: TimeInterval = 7 * 24 * 3600

    /// One reported window, normalised: `usedPct` and `resetsAt` already
    /// rolled for a weekly window whose stored reset has passed
    /// (`WeeklyRoll`), the length T3 reads from `windowDurationMins`.
    struct Window: Equatable {
        enum Kind: Int, Comparable {
            case session, weekly, scoped
            static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        }
        let kind: Kind
        /// Pool key across accounts: the kind, plus the model name for a scoped window.
        let id: String
        let label: String
        let usedPct: Double
        let resetsAt: Date?
        let length: TimeInterval
        /// The engine's own even-spend expectation, when it reports one.
        let expectedPct: Double?

        /// Quota left, 0…100 — bars and labels show what remains.
        var remainingPct: Int { Int((100 - max(0, min(100, usedPct))).rounded()) }

        /// Elapsed share of the window, 0…1; the engine's expectation wins
        /// over the clock when present, nil without a reset.
        func elapsedShare(now: Date) -> Double? {
            if let expectedPct { return max(0, min(1, expectedPct / 100)) }
            guard let resetsAt, length > 0 else { return nil }
            return max(0, min(1, (length - resetsAt.timeIntervalSince(now)) / length))
        }
    }

    enum Pace: Equatable { case ahead, on, under }

    /// Spending evenly leaves as much quota as time; within five points is on pace.
    static func pace(usedPct: Double, elapsed: Double) -> Pace {
        let gap = usedPct - elapsed * 100
        if gap > 5 { return .ahead }
        if gap < -5 { return .under }
        return .on
    }

    static func pace(_ window: Window, now: Date) -> Pace? {
        window.elapsedShare(now: now).map { pace(usedPct: window.usedPct, elapsed: $0) }
    }

    /// `2h 13m`, `3d 4h`, `12m`.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let remaining = Int(max(0, seconds))
        let days = remaining / 86400
        let hours = remaining % 86400 / 3600
        let minutes = remaining % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// `resets in 2h 13m`, `resets now`, or nil without a reset.
    static func resetsIn(_ window: Window, now: Date) -> String? {
        guard let at = window.resetsAt else { return nil }
        return at <= now ? "resets now" : "resets in \(formatDuration(at.timeIntervalSince(now)))"
    }

    /// The engine's windows for one account, in T3's kind order. Weekly and
    /// per-model windows roll through `WeeklyRoll` so a stale measurement
    /// reads 0 % with the next boundary, not "resets now" for a week.
    static func windows(_ usage: Usage?, now: Date) -> [Window] {
        guard let usage else { return [] }
        var out: [Window] = []
        if let w = usage.fiveHour {
            out.append(Window(kind: .session, id: "session", label: "Session", usedPct: w.pct,
                              resetsAt: WeeklyRoll.parse(w.resetsAt), length: sessionSeconds,
                              expectedPct: w.expectedPct))
        }
        if let w = usage.sevenDay {
            out.append(Window(kind: .weekly, id: "weekly", label: "Weekly",
                              usedPct: WeeklyRoll.displayPct(w, now: now) ?? w.pct,
                              resetsAt: WeeklyRoll.displayReset(w, now: now), length: weekSeconds,
                              expectedPct: w.expectedPct))
        }
        for w in usage.scoped ?? [] {
            let name = w.name ?? "Model"
            out.append(Window(kind: .scoped, id: "scoped:\(name)", label: "Weekly · \(name)",
                              usedPct: WeeklyRoll.displayPct(w, now: now) ?? w.pct,
                              resetsAt: WeeklyRoll.displayReset(w, now: now), length: weekSeconds,
                              expectedPct: w.expectedPct))
        }
        return out
    }

    /// One account as the pools see it: what to call it, and its windows.
    struct Member: Equatable {
        let number: Int
        let name: String
        let email: String
        let plan: String?
        let disabled: Bool
        let windows: [Window]
    }

    /// T3's `accountName`: the display name, else the initials of the email.
    static func name(alias: String?, email: String) -> String {
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty { return alias }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        let initials = String((parts.first?.first.map(String.init) ?? "") + (parts.dropFirst().first?.first.map(String.init) ?? ""))
        return initials.isEmpty ? "Account" : initials.uppercased()
    }

    static func member(_ account: Account, now: Date) -> Member {
        Member(number: account.number, name: name(alias: account.alias, email: account.email),
               email: account.email, plan: account.plan, disabled: account.disabled ?? false,
               windows: windows(account.usage ?? account.lastGoodUsage, now: now))
    }

    /// One window id across every account that reports it.
    struct Pool: Equatable {
        struct Column: Equatable {
            let member: Member
            let window: Window?
        }
        struct Reset: Equatable {
            let member: Member
            let at: Date
            /// Points of the pool the reset hands back: the member's used share over the member count.
            let restoresPct: Int
        }
        let id: String
        let kind: Window.Kind
        let label: String
        /// Fixed account positions across the pools of one group; a nil window leaves a gap.
        let columns: [Column]
        let remainingPct: Int
        let pace: Pace?
        let resets: [Reset]

        var members: [Column] { columns.filter { $0.window != nil } }
        var nextRefill: Reset? { resets.first { $0.restoresPct > 0 } }
    }

    /// `collectLimitPools` for one group of accounts: members order by the
    /// first window kind's reset, soonest first (missing resets last, names
    /// then numbers breaking ties), and every pool keeps that order as its
    /// columns so a segment stays the same account row to row.
    static func pools(_ members: [Member], now: Date) -> [Pool] {
        let orderKind = members.flatMap(\.windows).map(\.kind).min()
        func orderReset(_ m: Member) -> TimeInterval {
            m.windows.first { $0.kind == orderKind }?.resetsAt?.timeIntervalSinceReferenceDate ?? .infinity
        }
        let sorted = members.sorted {
            let (a, b) = (orderReset($0), orderReset($1))
            if a != b { return a < b }
            let names = $0.name.lowercased().compare($1.name.lowercased())
            if names != .orderedSame { return names == .orderedAscending }
            return $0.number < $1.number
        }
        var order: [String] = []
        var byKey: [String: [(Member, Window)]] = [:]
        for m in sorted {
            for w in m.windows {
                if byKey[w.id] == nil { order.append(w.id) }
                byKey[w.id, default: []].append((m, w))
            }
        }
        let pools = order.map { key -> Pool in
            let hits = byKey[key]!
            let first = hits[0].1
            let used = hits.map(\.1.usedPct).reduce(0, +) / Double(hits.count)
            // Pace is judged only over members with a clock; one without
            // would count as spend with no time elapsed.
            let timed = hits.compactMap { m, w in w.elapsedShare(now: now).map { (w.usedPct, $0) } }
            let pace: Pace? = timed.isEmpty ? nil : Self.pace(
                usedPct: timed.map(\.0).reduce(0, +) / Double(timed.count),
                elapsed: timed.map(\.1).reduce(0, +) / Double(timed.count))
            let resets = hits.compactMap { m, w in
                w.resetsAt.map { Pool.Reset(member: m, at: $0, restoresPct: Int((w.usedPct / Double(hits.count)).rounded())) }
            }.sorted { $0.at < $1.at }
            return Pool(id: key, kind: first.kind, label: first.label,
                        columns: sorted.map { m in Pool.Column(member: m, window: hits.first { $0.0.number == m.number }?.1) },
                        remainingPct: Int((100 - used).rounded()), pace: pace, resets: resets)
        }
        return pools.sorted { $0.kind < $1.kind }
    }

    /// Accounts whose status has something to say beside the bars.
    static func notices(_ accounts: [Account]) -> [String] {
        accounts.compactMap { a in
            SentinelNotes.note(for: a.usageStatus).map { "\(name(alias: a.alias, email: a.email)): \($0)" }
        }
    }
}
