import Foundation

// MARK: - 5h window reconstruction (#7 layer 1)
//
// Physics (docs/research/smart-engine.md, "The physics"): a 5h window
// starts on the FIRST request after the previous one expired, so its
// start isn't in the samples directly — only `resetsAt` is. Start is
// derived: resetsAt - 18000s. Peak (not final) pct is the useful stat,
// since a window's headroom idles rather than leaking mid-window —
// "used" means the highest pct anyone observed inside it.
//
// Reuses WasteMath's generation-closing idioms (resetSlack jitter
// tolerance, vanish-closes, past-now-closes) but — unlike weekly
// waste, which only reports CLOSED generations — the still-ticking
// window is also emitted, marked `closed: false`, since the planner
// (layer 2) needs to know about the account's current window too.

public struct FiveHourWindow: Sendable, Equatable, Identifiable {
    public let email: String
    public let number: Int?
    public let start: Double
    public let resetsAt: Double
    public let peakPct: Double
    public let samples: Int
    public let closed: Bool

    /// Stable identity for lists: two accounts can share a `resetsAt`.
    public var id: String { "\(email)|\(resetsAt)" }

    public init(email: String, number: Int?, start: Double, resetsAt: Double,
                peakPct: Double, samples: Int, closed: Bool) {
        self.email = email
        self.number = number
        self.start = start
        self.resetsAt = resetsAt
        self.peakPct = peakPct
        self.samples = samples
        self.closed = closed
    }
}

public enum WindowTelemetry {
    /// 5h windows carry no reset jitter tolerance of their own — reuse
    /// WasteMath's, since both come from the same engine countdown math.
    public static let resetSlack: Double = WasteMath.resetSlack

    /// Reconstructed windows across the history, oldest first. A window
    /// closes when its account's fiveHour.resetsAt jumps LATER by more
    /// than `resetSlack`, the fiveHour field vanishes, or (at the end of
    /// history) the resetsAt already lies in the past of `now`; anything
    /// still ticking is returned too, with `closed == false`.
    public static func fiveHourWindows(_ samples: [UsageSample], now: Double,
                                        resetSlack: Double = resetSlack) -> [FiveHourWindow] {
        struct Open { var number: Int?; var resetAt: Double; var peak: Double; var n: Int }
        var open: [String: Open] = [:]      // email -> state
        var closed: [FiveHourWindow] = []

        func window(email: String, _ o: Open, closed isClosed: Bool) -> FiveHourWindow {
            FiveHourWindow(email: email, number: o.number,
                           start: o.resetAt - 18_000, resetsAt: o.resetAt,
                           peakPct: o.peak, samples: o.n, closed: isClosed)
        }

        for s in samples.sorted(by: { $0.t < $1.t }) {
            let email = s.email
            guard let w = s.fiveHour, let reset = w.resetsAt else {
                // Window vanished: the reset elapsed between samples.
                if let cur = open[email] {
                    closed.append(window(email: email, cur, closed: true))
                    open[email] = nil
                }
                continue
            }
            if let cur = open[email], abs(reset - cur.resetAt) <= resetSlack {
                open[email] = Open(number: s.number, resetAt: cur.resetAt,
                                   peak: max(cur.peak, w.pct), n: cur.n + 1)
            } else {
                if let cur = open[email] {
                    closed.append(window(email: email, cur, closed: true))
                }
                open[email] = Open(number: s.number, resetAt: reset, peak: w.pct, n: 1)
            }
        }
        var result = closed
        for (email, o) in open {
            result.append(window(email: email, o, closed: o.resetAt < now))
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Histogram of window START hour-of-day → count — the user's sprint
    /// rhythm, and the planner's (layer 2) input for "when do windows
    /// usually begin".
    public static func dailyRhythm(_ windows: [FiveHourWindow],
                                   calendar: Calendar = .current) -> [Int: Int] {
        var hist: [Int: Int] = [:]
        for w in windows {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: w.start))
            hist[hour, default: 0] += 1
        }
        return hist
    }

    /// unused = closed windows whose peak never rose above 5% — ignited
    /// or opened but never really worked in before the reset.
    public static func summary(_ windows: [FiveHourWindow]) -> (count: Int, meanPeak: Double, unusedWindows: Int) {
        guard !windows.isEmpty else { return (0, 0, 0) }
        let meanPeak = windows.map(\.peakPct).reduce(0, +) / Double(windows.count)
        let unused = windows.filter { $0.closed && $0.peakPct < 5 }.count
        return (windows.count, meanPeak, unused)
    }
}
