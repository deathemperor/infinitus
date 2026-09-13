import Foundation

/// Away-push triggers beyond account switches (user requests 2026-08-30):
/// all accounts exhausted, and a warning when the last alive account is
/// close to dying. Pure state machine — snapshot ticks in, message strings
/// out — so the episode/dedup rules run under `swift test`; the app posts
/// each message to Notification Center and through `cswap notify push`.
///
/// Episode rules:
///  - the all-dead latch seeds silently on the first look instead, which
///    covers a relaunch without state.
///  - what would repeat after a relaunch is kept in `Memory` — the app
///    persists it after each tick and hands it back through
///    `init(memory:)`.
///  - each condition fires once and re-arms only after it clears (the
///    last-alive warning re-arms below `rearmBelowPct`, hysteresis).
///  - flags are applied at emit time, but state advances regardless — so
///    toggling a trigger on later never fires a stale episode.
public struct PushTriggers: Sendable {
    public struct Account: Sendable {
        public let number: Int
        public let name: String
        public let dead: Bool
        /// Worst plan-window pct (5h/7d/scoped; spend excluded — a spent
        /// credit cap is a footnote, not a death; see AccountVitals).
        public let worstPct: Double?
        public init(number: Int, name: String, dead: Bool, worstPct: Double?) {
            self.number = number
            self.name = name
            self.dead = dead
            self.worstPct = worstPct
        }
    }

    public struct Flags: Sendable {
        public var allDead: Bool
        public var lastAlive: Bool
        public init(allDead: Bool = true, lastAlive: Bool = true) {
            self.allDead = allDead
            self.lastAlive = lastAlive
        }
    }

    public static let warnPct = 90.0
    public static let rearmBelowPct = 85.0

    /// The latch that would repeat after a relaunch unless remembered.
    /// Only this one: all-dead seeds silently instead.
    public struct Memory: Codable, Equatable, Sendable {
        /// The account the last-alive warning went out for.
        public var warnedLastAlive: Int?
        public init(warnedLastAlive: Int? = nil) {
            self.warnedLastAlive = warnedLastAlive
        }
    }
    public private(set) var memory: Memory

    private var allDeadAnnounced = false
    /// The first look with accounts seeds silently: a fleet already dead
    /// at launch is on screen (and the phone's countdown activity), and
    /// the app relaunches often enough that announcing it again is noise.
    private var seededAllDead = false

    public init(memory: Memory = Memory()) {
        self.memory = memory
    }

    static let allDeadTail = "nothing left to switch to"
    /// The all-dead message, for callers that route it differently.
    public static func isAllDeadMessage(_ message: String) -> Bool {
        message.hasSuffix(allDeadTail)
    }

    public static func worstPlanPct(_ usage: Usage?) -> Double? {
        guard let usage else { return nil }
        var pcts: [Double] = []
        if let p = usage.fiveHour?.pct { pcts.append(p) }
        if let p = usage.sevenDay?.pct { pcts.append(p) }
        for w in usage.scoped ?? [] { pcts.append(w.pct) }
        return pcts.max()
    }

    public mutating func tick(accounts: [Account], flags: Flags,
                              now: Date = Date()) -> [String] {
        var out: [String] = []

        if !accounts.isEmpty, accounts.allSatisfy(\.dead) {
            if !allDeadAnnounced {
                allDeadAnnounced = true
                if flags.allDead, seededAllDead {
                    out.append("all \(accounts.count) accounts exhausted — \(Self.allDeadTail)")
                }
            }
        } else if accounts.contains(where: { !$0.dead }) {
            // Only an account seen alive re-arms: an empty or partial
            // roster (usage blanked by an engine re-probe) must not turn
            // the next dead look into a repeat.
            allDeadAnnounced = false
        }
        if !accounts.isEmpty { seededAllDead = true }

        let alive = accounts.filter { !$0.dead }
        if alive.count == 1, let last = alive.first,
           let pct = last.worstPct, pct >= Self.warnPct {
            if memory.warnedLastAlive != last.number {
                memory.warnedLastAlive = last.number
                if flags.lastAlive {
                    out.append("last account standing — \(last.name) at \(Int(pct.rounded()))%")
                }
            }
        } else if alive.count != 1
            || (alive.first?.worstPct ?? 0) < Self.rearmBelowPct {
            memory.warnedLastAlive = nil
        }

        return out
    }
}
