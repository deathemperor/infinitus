import Foundation

/// One fleet's verdict on whether background sessions may spend (#616,
/// ruling A: native decides, the fork obeys). Published on `fleets` /
/// `refresh` while `priority_mode` is on; absent when the mode is off or
/// the active account has never carried usage. Pct-only in v1: the
/// active account's fullest window binds, `low` at or above
/// `priority_low_pct`, `abundant` again at or below
/// `priority_abundant_pct`, and inside the band the previous verdict
/// holds. The interrupt mode (#743) says `critical` wherever the hold
/// mode says `low` — same line, same hysteresis — so the mode travels
/// inside the verdict: the fork holds starts on `low`, holds starts and
/// interrupts running background turns on `critical`, and never reads
/// the pref.
public struct Headroom: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case abundant, low, critical }
    public let state: State
    /// The binding window as the engine names it: "5h", "7d", or a
    /// scoped window's display name.
    public let window: String
    public let pct: Double
    public let reason: String

    public init(state: State, window: String, pct: Double, reason: String) {
        self.state = state; self.window = window; self.pct = pct; self.reason = reason
    }

    /// `previous` is the verdict for the SAME active account; pass nil
    /// after a swap so the hysteresis starts over on the new account.
    /// A refresh that carries no usage (#159: one in three can) says
    /// nothing, so the previous verdict stands rather than the key
    /// vanishing and releasing every held session for one poll.
    /// `interrupt` picks the holding state: `.critical` in the interrupt
    /// mode, `.low` otherwise; a previous verdict held under the other
    /// mode re-reads as this mode's holding state inside the band.
    public static func verdict(previous: Headroom?, usage: Usage?,
                               lowPct: Double, abundantPct: Double,
                               interrupt: Bool = false) -> Headroom? {
        guard let usage else { return previous }
        let holding: State = interrupt ? .critical : .low
        var windows: [(String, Double)] = []
        if let w = usage.fiveHour { windows.append(("5h", w.pct)) }
        if let w = usage.sevenDay { windows.append(("7d", w.pct)) }
        for w in usage.scoped ?? [] { windows.append((w.name ?? "?", w.pct)) }
        guard let (window, pct) = windows.max(by: { $0.1 < $1.1 }) else { return previous }
        let shown = "\(window) at \(Int(pct.rounded()))%"
        if pct >= lowPct {
            return Headroom(state: holding, window: window, pct: pct,
                            reason: "\(shown), \(interrupt ? "interrupting" : "holding") from \(Int(lowPct))%")
        }
        if pct <= abundantPct || previous == nil {
            return Headroom(state: .abundant, window: window, pct: pct,
                            reason: "\(shown), releasing at \(Int(abundantPct))%")
        }
        let held: State = previous?.state == .abundant ? .abundant : holding
        return Headroom(state: held, window: window, pct: pct,
                        reason: "\(shown), between \(Int(abundantPct))% and \(Int(lowPct))%: still \(held.rawValue)")
    }
}
