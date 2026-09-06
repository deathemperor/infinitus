import Foundation

/// Client-side mirror of the engine's `_next_recovery` advisory
/// (claude_swap/switcher.py), minus its active-account exclusion.
///
/// The engine skips the active account when ranking who recovers soonest
/// — reasonable for "should the auto-switcher wait on someone else", but
/// wrong for "who does the popup tell the user to wait for": if the
/// active account is itself dead and its last maxed window resets before
/// anyone else's, the engine still names a LATER account (user report
/// 2026-09-02: "loc recovers in 01:07:23" while the active account,
/// deathemperor2nd, actually revived in 27m). We recompute the same
/// ranking over every non-disabled account, active included, and prefer
/// it — it only ever finds a candidate at least as soon as the engine's.
public enum RecoveryMath {
    /// Nothing legitimate resets later than a weekly window; a reset
    /// further out than this is a bad string, not a reviver (#226).
    public static let plausibleHorizon: TimeInterval = 8 * 24 * 3600

    /// When the account is back for good: its LAST maxed window's reset
    /// (5h, 7d and scoped alike), as a parsed date and the ISO string it
    /// came from. nil when nothing is maxed, when a maxed window carries
    /// no parseable reset (unrankable, never "resets now"), or when the
    /// reset is implausibly far out.
    public static func revival(of account: Account, now: Date) -> (at: Date, iso: String)? {
        guard let usage = account.usage else { return nil }
        var windows: [UsageWindow] = []
        if let w = usage.fiveHour { windows.append(w) }
        if let w = usage.sevenDay { windows.append(w) }
        windows += usage.scoped ?? []
        let maxed = windows.filter { $0.pct >= 100 }
        if maxed.isEmpty { return nil }
        var last: (at: Date, iso: String)?
        for window in maxed {
            guard let iso = window.resetsAt, let at = WeeklyRoll.parse(iso) else { return nil }
            if last == nil || at > last!.at { last = (at, iso) }
        }
        guard let last, last.at <= now.addingTimeInterval(plausibleHorizon) else { return nil }
        return last
    }

    /// Mirrors `_next_recovery`, without the `row.number == active` skip
    /// and ranking by parsed date rather than by string (#226: a raw
    /// `resetsAt` compared lexicographically).
    public static func nextRecovery(accounts: [Account], now: Date = Date()) -> NextRecovery? {
        var best: (at: Date, iso: String, number: Int)?
        for account in accounts {
            if account.disabled == true { continue }
            guard let revival = revival(of: account, now: now) else { continue }
            if best == nil || revival.at < best!.at {
                best = (revival.at, revival.iso, account.number)
            }
        }
        guard let best else { return nil }
        return NextRecovery(number: best.number, at: best.iso)
    }

    /// The value to actually show: the client's superset ranking when it
    /// can rank someone (never later than the engine's, since it considers
    /// strictly more candidates), else the engine's own value. `nil` when
    /// the engine reports `nil` — the "everyone limited" premise comes
    /// from the engine, and this never invents it.
    ///
    /// The engine emits `nextRecovery` whenever it has no OTHER account
    /// to switch to — it never looks at the active one. With the active
    /// account healthy and every spare limited, that read "All accounts
    /// down" over a working fleet (user 2026-09-04). So: no active
    /// account, or an active account that is itself at a limit, else
    /// there is nothing to wait for.
    public static func corrected(engine: NextRecovery?, accounts: [Account],
                                 activeNumber: Int?, now: Date = Date()) -> NextRecovery? {
        guard engine != nil else { return nil }
        if let active = accounts.first(where: { $0.number == activeNumber }),
           !AccountVitals.isDead(active.usage) { return nil }
        return nextRecovery(accounts: accounts, now: now) ?? engine
    }

    /// The account to spotlight while every account is limited (#227): the
    /// corrected pick, only when the engine names no candidate and the
    /// reset is a real future instant inside the plausible horizon. nil
    /// the moment a candidate exists — the highlight never fights the
    /// next-up marker.
    public static func reviver(nextCandidate: Int?, nextRecovery: NextRecovery?,
                               now: Date = Date()) -> (number: Int, at: Date)? {
        guard nextCandidate == nil, let rec = nextRecovery,
              let at = WeeklyRoll.parse(rec.at), at > now,
              at <= now.addingTimeInterval(plausibleHorizon) else { return nil }
        return (rec.number, at)
    }
}
