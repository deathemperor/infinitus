import Foundation

/// The headroom ranking behind the proxy fleet's advisory next candidate
/// (ProxyMapping) and the popup's display sort (DisplayOrder). Nothing
/// writes it to an engine any more: pick-first is each engine's own knob
/// (cswap `autoswitch.preferred`, the proxy's priority tier) — the app
/// runs no second account policy (user 2026-09-03).
///
/// Most headroom first — the same ranking the engine's advisory next
/// candidate uses: an account's binding window is its highest pct across
/// 5h / 7d / per-model; spend is NOT a window (an estimate, never billing
/// truth — a rested account once went advisory-dead on it). Then accounts
/// with no usage yet (unknown is not dead), then dead ones by who recovers
/// first, then disabled ones.
///
/// Anchored to the incumbent order: an account only moves ahead of the one
/// directly in front of it when it beats it by a real margin (`margin`
/// points of headroom), so two accounts burning side by side never
/// flip-flop every refresh.
public enum AutoOrder {
    public static let margin: Double = 5

    public struct Row: Equatable, Sendable {
        public enum Rank: Int, Comparable, Sendable {
            case alive, unknown, dead, disabled
            public static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
        }
        public let number: Int
        public let rank: Rank
        /// Highest window pct (alive rows only).
        public let bindingPct: Double
        /// When the last exhausted window rolls (dead rows only).
        public let recovery: Date?

        public init(number: Int, rank: Rank, bindingPct: Double = 0, recovery: Date? = nil) {
            self.number = number
            self.rank = rank
            self.bindingPct = bindingPct
            self.recovery = recovery
        }
    }

    public static func row(_ account: Account) -> Row {
        if account.disabled == true {
            return Row(number: account.number, rank: .disabled)
        }
        guard let usage = account.usage else {
            return Row(number: account.number, rank: .unknown)
        }
        var windows: [UsageWindow] = []
        if let w = usage.fiveHour { windows.append(w) }
        if let w = usage.sevenDay { windows.append(w) }
        windows += usage.scoped ?? []
        guard let binding = windows.map(\.pct).max() else {
            return Row(number: account.number, rank: .unknown)
        }
        if binding >= 100 {
            let recovery = windows.filter { $0.pct >= 100 }
                .compactMap { WeeklyRoll.parse($0.resetsAt) }.max()
            return Row(number: account.number, rank: .dead, recovery: recovery)
        }
        return Row(number: account.number, rank: .alive, bindingPct: binding)
    }

    /// Does `b` deserve to sit ahead of `a`?
    static func beats(_ b: Row, _ a: Row) -> Bool {
        if b.rank != a.rank { return b.rank < a.rank }
        switch b.rank {
        case .alive: return b.bindingPct + margin <= a.bindingPct
        case .dead:
            guard let rb = b.recovery else { return false }
            guard let ra = a.recovery else { return true }
            return rb < ra
        case .unknown, .disabled: return false
        }
    }

    /// The order to ask for, given the current top-to-bottom rows. Equal to
    /// the input's numbers when nothing earns a move — callers skip the
    /// engine call on equality.
    public static func order(_ rows: [Row]) -> [Int] {
        var rows = rows
        var swapped = true
        while swapped {
            swapped = false
            for i in rows.indices.dropFirst() where beats(rows[i], rows[i - 1]) {
                rows.swapAt(i, i - 1)
                swapped = true
            }
        }
        return rows.map(\.number)
    }

    public static func order(_ accounts: [Account]) -> [Int] {
        order(accounts.map(row))
    }
}

/// Display-only ordering (todo 2026-09-01: "sorted by headroom but put
/// active and first candidate on top"): the active account leads, the
/// next candidate follows, then AutoOrder's ranking — most headroom
/// first, unknown, dead by soonest recovery, disabled last. No margin:
/// a display sort writes nothing, so flip-flop costs nothing. Engine
/// slot numbers never move.
public enum DisplayOrder {
    /// `reviver` takes the next-candidate slot while all accounts are
    /// limited (#227) — the row to watch floats up the way the next-up
    /// row does when the fleet is alive.
    public static func sort(_ accounts: [Account],
                            active: Int?, next: Int?, reviver: Int? = nil) -> [Account] {
        func pin(_ a: Account) -> Int {
            if a.number == active { return 0 }
            if a.number == next || a.number == reviver { return 1 }
            return 2
        }
        return accounts.sorted { l, r in
            let pl = pin(l), pr = pin(r)
            if pl != pr { return pl < pr }
            let rl = AutoOrder.row(l), rr = AutoOrder.row(r)
            if rl.rank != rr.rank { return rl.rank < rr.rank }
            switch rl.rank {
            case .alive where rl.bindingPct != rr.bindingPct:
                return rl.bindingPct < rr.bindingPct
            case .dead where rl.recovery != rr.recovery:
                return (rl.recovery ?? .distantFuture)
                     < (rr.recovery ?? .distantFuture)
            default:
                return l.number < r.number
            }
        }
    }
}
