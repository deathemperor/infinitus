import Foundation

/// One fleet's verdict on whether background sessions may spend (#616,
/// ruling A: native decides, the fork obeys). Published on `fleets` /
/// `refresh` while `priority_mode` is on; absent when the mode is off or
/// the active account has never carried usage. The active account's
/// fullest window binds, `low` at or above `priority_low_pct`, `abundant`
/// again at or below `priority_abundant_pct`, inside the band the previous
/// verdict holds, and independently a window the forecast projects to
/// fill before its own reset holds too, even below the line (#616
/// remainder 1). The interrupt mode (#743) says `critical` wherever the
/// hold mode says `low` — same line, same hysteresis — so the mode
/// travels inside the verdict: the fork holds starts on `low`, holds
/// starts and interrupts running background turns on `critical`, and
/// never reads the pref.
public struct Headroom: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case abundant, low, critical }
    /// The active account's earliest window projected to fill before its
    /// reset, as `UsageForecast.AccountLine` names it. Never reaches the
    /// wire — a caller-computed input to `verdict`, not part of the
    /// published verdict.
    public struct Fill: Sendable, Equatable {
        public let window: String
        public let at: Double
        public init(window: String, at: Double) { self.window = window; self.at = at }
    }
    public let state: State
    /// The binding window as the engine names it: "5h", "7d", or a
    /// scoped window's display name.
    public let window: String
    public let pct: Double
    public let reason: String
    /// When this verdict's state was first reached (epoch seconds); an
    /// additive wire key (#616 remainder 2) — carried unchanged while the
    /// state holds, reset to `now` on every state change, so the ledger
    /// entry a relaunch seeds from reads as of the state's own start.
    public let since: Double?

    public init(state: State, window: String, pct: Double, reason: String, since: Double? = nil) {
        self.state = state; self.window = window; self.pct = pct; self.reason = reason; self.since = since
    }

    /// `previous` is the verdict for the SAME active account; pass nil
    /// after a swap so the hysteresis starts over on the new account.
    /// A refresh that carries no usage (#159: one in three can) says
    /// nothing, so the previous verdict stands rather than the key
    /// vanishing and releasing every held session for one poll.
    /// `interrupt` picks the holding state: `.critical` in the interrupt
    /// mode, `.low` otherwise; a previous verdict held under the other
    /// mode re-reads as this mode's holding state inside the band.
    /// `fill`, when given, is the active account's earliest window on
    /// pace to hit its limit before it resets — checked right after the
    /// pct threshold, so a fleet already at/above `lowPct` keeps that
    /// reason, and a fleet whose pace drops back (`fill` goes nil) while
    /// the pct still sits in the band keeps the held verdict via the
    /// ordinary hysteresis.
    public static func verdict(previous: Headroom?, usage: Usage?,
                               lowPct: Double, abundantPct: Double,
                               interrupt: Bool = false, fill: Fill? = nil,
                               now: Double = Date().timeIntervalSince1970) -> Headroom? {
        guard let usage else { return previous }
        let holding: State = interrupt ? .critical : .low
        var windows: [(String, Double)] = []
        if let w = usage.fiveHour { windows.append(("5h", w.pct)) }
        if let w = usage.sevenDay { windows.append(("7d", w.pct)) }
        for w in usage.scoped ?? [] { windows.append((w.name ?? "?", w.pct)) }
        guard let (window, pct) = windows.max(by: { $0.1 < $1.1 }) else { return previous }
        // `since`: carried from `previous` while the state holds, reset to
        // `now` on any state change (or when there was no previous verdict).
        func make(_ state: State, window: String, pct: Double, reason: String) -> Headroom {
            let since = (previous == nil || previous?.state != state) ? now : (previous?.since ?? now)
            return Headroom(state: state, window: window, pct: pct, reason: reason, since: since)
        }
        let shown = "\(window) at \(Int(pct.rounded()))%"
        if pct >= lowPct {
            return make(holding, window: window, pct: pct,
                        reason: "\(shown), \(interrupt ? "interrupting" : "holding") from \(Int(lowPct))%")
        }
        if let fill {
            let fillPct = windows.first { $0.0 == fill.window }?.1 ?? pct
            let minutes = Int(max(0, (fill.at - now) / 60).rounded())
            let verb = interrupt ? "interrupting" : "holding"
            return make(holding, window: fill.window, pct: fillPct,
                        reason: "\(fill.window) at \(Int(fillPct.rounded()))%, fills in \(minutes) min before its reset — \(verb)")
        }
        if pct <= abundantPct || previous == nil {
            return make(.abundant, window: window, pct: pct,
                        reason: "\(shown), releasing at \(Int(abundantPct))%")
        }
        let held: State = previous?.state == .abundant ? .abundant : holding
        return make(held, window: window, pct: pct,
                    reason: "\(shown), between \(Int(abundantPct))% and \(Int(lowPct))%: still \(held.rawValue)")
    }
}
