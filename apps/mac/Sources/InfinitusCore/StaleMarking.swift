import Foundation

/// Ageing the rows an engine could not refresh (#965's `stale`, widened
/// past swapd).
///
/// When an engine's `snapshot()` throws, the app keeps that engine's
/// last good rows rather than blanking the fleet. That is the right
/// call — those numbers are still the best the app has — but until now
/// the retained rows said nothing about their age, and every countdown
/// on them is recomputed live from stored reset times, so an hour-old
/// reading rendered exactly like one fetched this minute. Marking them
/// gives every surface the `stale` flag and the age it already knows
/// how to draw.
public enum StaleMarking {
    /// The last good fleet, with each account that carries a reading
    /// flagged stale, the failure's message as the reason, and an age.
    ///
    /// Age, truest source first: the engine's own `usageFetchedAt` for
    /// that row (it says when THOSE numbers were fetched and survives a
    /// relaunch off the disk cache), else when this engine last answered
    /// at all. Never the age the row already carried — that one was
    /// measured when the reading was taken and does not move, so serving
    /// it now would draw "2 min ago" on numbers hours old, which is the
    /// very lie this is here to stop. With neither source the row still
    /// says it is stale, and simply reports no age.
    ///
    /// A row with no reading at all has no age to report and is left
    /// untouched.
    public static func marked(_ fleet: EngineFleet, reason: String,
                              lastGood: Date?, now: Date) -> EngineFleet {
        let accounts = fleet.accounts.map { account -> Account in
            guard account.usage != nil || account.lastGoodUsage != nil else { return account }
            let stamped = UsageHistory.parseISO(account.usageFetchedAt ?? "")
                .map { now.timeIntervalSince($0) }
            let sinceGood = lastGood.map { now.timeIntervalSince($0) }
            let age = stamped ?? sinceGood
            return account.markingStale(reason: reason, ageSeconds: age.map { max(0, $0) })
        }
        return fleet.with(accounts: accounts)
    }
}

public extension Account {
    /// The same account wearing the stale flag, its reason and its age —
    /// the failed-refresh counterpart of `preferring(_:)`.
    func markingStale(reason: String, ageSeconds: Double?) -> Account {
        Account(number: number, email: email, organizationName: organizationName,
                organizationUuid: organizationUuid, isOrganization: isOrganization,
                active: active, usageStatus: usageStatus, usage: usage, windows: windows,
                alias: alias, icon: icon, plan: plan, disabled: disabled, preferred: preferred,
                usageFetchedAt: usageFetchedAt, usageAgeSeconds: ageSeconds,
                lastGoodUsage: lastGoodUsage, lastGoodFetchedAt: lastGoodFetchedAt,
                lastGoodAgeSeconds: lastGoodAgeSeconds, stale: true, staleReason: reason)
    }
}
