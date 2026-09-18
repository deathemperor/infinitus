import Foundation

/// Weekly usage pace for engines that do not report it themselves.
///
/// swapd computes pace in the engine and ships it on every window
/// (`SwapdPace`); 9Router and CLIProxyAPI send a bare percentage, so their
/// rows drew no pace stripe, no burn and no chill and their tooltip said
/// neither "in reserve" nor "in deficit". This mirrors swapd's weekly
/// pace calculation, including its one-minute guard after reset.
///
/// Weekly windows only — a 5h window resets too fast for pace to mean
/// anything, and reads "far ahead" almost by definition early in the
/// window.
public enum Pace {
    /// Weekly windows reset on a fixed 7-day cadence.
    public static let weeklyPeriod: TimeInterval = 7 * 24 * 3600

    /// Shortest elapsed span pace is read over. The rate below is `actual /
    /// elapsed` and a fetch can land on the reset second itself, so there has
    /// to be a span to measure. This suppressed a whole day once, on the
    /// grounds that expected is near zero right after a reset and any usage
    /// reads as "far ahead" — but `aheadThresholdPct` is already that damper,
    /// and scales with what was spent rather than with the clock, so the day
    /// only cost every window its stripe.
    public static let minElapsed: TimeInterval = 60

    /// Minimum (actual − expected) gap in points before the window counts
    /// as ahead of pace. Below it, the difference is normal variance and
    /// the marker would just add noise.
    public static let aheadThresholdPct: Double = 15

    public struct Result: Equatable, Sendable {
        /// Where "on schedule" usage would be by now.
        public let expectedPct: Double
        public let actualPct: Double
        /// Time since this window's current cycle started.
        public let elapsed: TimeInterval
        /// The window's full cycle length.
        public let period: TimeInterval
        /// Ahead by at least `aheadThresholdPct`.
        public let ahead: Bool
    }

    /// Pace for one weekly window, or nil when it is not computable or not
    /// yet meaningful. `resetsAt` is the NEXT reset — the only instant the
    /// usage APIs give — so the current window's start is derived by
    /// folding it back by whole periods, which is right however many
    /// cycles stale the value is.
    public static func compute(pct: Double, resetsAt: String?, fetchedAt: Date,
                               period: TimeInterval = weeklyPeriod) -> Result? {
        guard let reset = WeeklyRoll.parse(resetsAt) else { return nil }
        // Floored modulo: Swift's `%` keeps the dividend's sign, Python's
        // does not, and a reset already in the past must still fold to the
        // time remaining in the current cycle.
        let raw = reset.timeIntervalSince(fetchedAt).truncatingRemainder(dividingBy: period)
        let remaining = raw < 0 ? raw + period : raw
        let elapsed = remaining == 0 ? 0 : period - remaining
        guard elapsed >= minElapsed else { return nil }

        let expected = min(100, elapsed / period * 100)
        return Result(expectedPct: expected, actualPct: pct, elapsed: elapsed,
                      period: period, ahead: pct - expected >= aheadThresholdPct)
    }

    /// Linear-projection instant usage would hit 100%, or nil when there is
    /// no measurable rate. Wide error bars against bursty usage — JSON and
    /// tooltips only, never a headline number.
    public static func exhaustsAt(_ pace: Result, fetchedAt: Date) -> Date? {
        guard pace.elapsed > 0, pace.actualPct > 0 else { return nil }
        let ratePerSecond = pace.actualPct / pace.elapsed
        guard ratePerSecond > 0 else { return nil }
        let remainingPct = 100 - pace.actualPct
        guard remainingPct > 0 else { return fetchedAt }
        return fetchedAt.addingTimeInterval(remainingPct / ratePerSecond)
    }

    /// Whether usage stays under 100% through the reset at the current
    /// rate. At a constant rate this flips exactly when actual passes
    /// expected — the marker's signal with no threshold, so a window can
    /// report false while showing no marker.
    public static func lastsToReset(_ pace: Result) -> Bool? {
        guard pace.actualPct > 0 else { return true }  // nothing to run out of
        guard pace.elapsed > 0 else { return nil }
        let ratePerSecond = pace.actualPct / pace.elapsed
        guard ratePerSecond > 0 else { return nil }
        return pace.actualPct + ratePerSecond * (pace.period - pace.elapsed) <= 100
    }

    /// `window` with its pace fields filled in, or unchanged when pace is
    /// not computable. The one call an engine mapping needs.
    public static func applied(to window: UsageWindow, fetchedAt: Date,
                               period: TimeInterval = weeklyPeriod) -> UsageWindow {
        guard let pace = compute(pct: window.pct, resetsAt: window.resetsAt,
                                 fetchedAt: fetchedAt, period: period) else { return window }
        return UsageWindow(
            pct: window.pct, resetsAt: window.resetsAt, countdown: window.countdown,
            clock: window.clock, name: window.name,
            expectedPct: pace.expectedPct, aheadOfPace: pace.ahead,
            projectedExhaustionAt: exhaustsAt(pace, fetchedAt: fetchedAt)
                .map(ProxyMapping.isoString),
            willLastToReset: lastsToReset(pace))
    }
}
