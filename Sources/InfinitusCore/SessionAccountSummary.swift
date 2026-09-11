import Foundation

// MARK: - Session → account attribution (phone header + detail screen)
//
// "Which account is active or using the session" (user 2026-09-03): a
// credential-swap (swapd) session always rides the fleet's one active
// credential; a CLIProxyAPI session routes per request across every
// account in that fleet, so there is no single "the" account. Pure data
// decision, gated on the owning fleet's identity — never on `Provider`
// alone, since a CLIProxyAPI Claude fleet must not read as a swapd one.

/// Which fleet a live session's requests actually go through, and what
/// to say about its account(s).
public struct SessionAccountSummary: Sendable {
    public enum Kind: Sendable, Equatable { case swap, proxy, unknownFleet }

    public let kind: Kind
    public let engineID: String
    /// swap / unknownFleet: the fleet's one active account (nil if the
    /// fleet reports no active number, or it doesn't match any account).
    public let account: Account?
    /// proxy only: every account on that fleet, for the detail list.
    public let proxyAccounts: [Account]
    public let proxyAliveCount: Int
    public let proxyLowestHeadroom: Account?
}

public enum SessionAccountLookup {
    /// `SwapdEngine.engineID` itself is `#if !os(iOS)` (it spawns a
    /// subprocess) — hardcoded here so this file compiles on the phone too.
    public static let swapEngineID = "swapd"

    /// - Parameters:
    ///   - pid: the session's pid (`SessionDetail.pid`).
    ///   - fleets: every mirrored `EngineFleet`, in popup order.
    /// - Returns: nil only when there are no fleets at all to attribute to.
    public static func summarize(pid: Int, fleets: [EngineFleet]) -> SessionAccountSummary? {
        // The fleet whose OWN liveSessions carries this pid — today only
        // ever swapd's, per `SessionsScreen.fleetsWithSessions`, but the
        // lookup stays generic for whichever engine reports sessions next.
        let owner = fleets.first { fleet in
            fleet.liveSessions?.sessions?.contains { $0.pid == pid } ?? false
        }
        let primary = fleets.first { $0.provider == .claude } ?? fleets.first
        guard let fleet = owner ?? primary else { return nil }

        func activeAccount(_ fleet: EngineFleet) -> Account? {
            fleet.accounts.first { $0.number == fleet.activeNumber }
        }

        if fleet.engineID == swapEngineID, fleet.provider == .claude {
            return SessionAccountSummary(kind: .swap, engineID: fleet.engineID,
                                          account: activeAccount(fleet), proxyAccounts: [],
                                          proxyAliveCount: 0, proxyLowestHeadroom: nil)
        }
        if fleet.engineID == CLIProxyEngine.engineID {
            let alive = fleet.accounts.filter { $0.disabled != true && !AccountVitals.isDead($0.usage) }
            let lowest = alive.max { AccountHeadroom.worstPct($0) < AccountHeadroom.worstPct($1) }
            return SessionAccountSummary(kind: .proxy, engineID: fleet.engineID, account: nil,
                                          proxyAccounts: fleet.accounts, proxyAliveCount: alive.count,
                                          proxyLowestHeadroom: lowest)
        }
        return SessionAccountSummary(kind: .unknownFleet, engineID: fleet.engineID,
                                      account: activeAccount(fleet), proxyAccounts: [],
                                      proxyAliveCount: 0, proxyLowestHeadroom: nil)
    }
}

/// Shared pct→severity mapping, pure so the header line and the detail
/// screen agree with each other without both re-deriving it.
public enum AccountHeadroom {
    /// The worst (highest-used) window on the account — 5h, 7d, or any
    /// per-model scoped window; 0 for an account with no usage yet.
    public static func worstPct(_ account: Account) -> Double {
        guard let usage = account.usage else { return 0 }
        var pcts: [Double] = []
        if let p = usage.fiveHour?.pct { pcts.append(p) }
        if let p = usage.sevenDay?.pct { pcts.append(p) }
        for w in usage.scoped ?? [] { pcts.append(w.pct) }
        return pcts.max() ?? 0
    }

    /// A `ThemeColor.resolve`-compatible name — green/orange/red, the
    /// same bands the Mac's account cells read off `AccountVitals`.
    public static func colorName(forPct pct: Double) -> String {
        if pct >= 100 { return "red" }
        if pct >= 80 { return "orange" }
        return "green"
    }
}
