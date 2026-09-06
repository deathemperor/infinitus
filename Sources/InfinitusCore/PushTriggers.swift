import Foundation

/// Away-push triggers beyond account switches (user requests 2026-08-30):
/// all sessions finished, all accounts exhausted, and a warning when the
/// last alive account is close to dying. Pure state machine — snapshot
/// ticks in, message strings out — so the episode/dedup rules run under
/// `swift test`; the app posts each message to Notification Center and
/// through `cswap notify push`.
///
/// Episode rules:
///  - "sessions finished" needs TWO consecutive quiet ticks: busy drops to
///    0 between every turn, and a single-tick trigger would ping the phone
///    on each turn gap. It also needs `sessionsDoneMinBusy` of work first
///    (#231): a one-command burst ending is not news either.
///  - what would repeat after a relaunch is kept in `Memory` — the app
///    persists it after each tick and hands it back through
///    `init(memory:)`. The all-dead and waiting latches seed silently on
///    the first look instead, which covers a relaunch without state.
///  - each condition fires once and re-arms only after it clears (the
///    last-alive warning re-arms below `rearmBelowPct`, hysteresis).
///  - flags are applied at emit time, but state advances regardless — so
///    toggling a trigger on later never fires a stale episode.
///  - "waiting on you" (#17) fires once per session when its status flips
///    to `waiting` (a permission prompt or a question) and re-arms when it
///    leaves that state.
///  - "needs AWS login" fires once per session+profile when the need
///    appears (2026-09-04: the user found it minutes late, by opening the
///    app) and re-arms when it clears. Same launch seeding as waiting —
///    except that its announced keys survive a relaunch (#98: three
///    relaunches in a day re-pushed every fresh need three times): the
///    app hands them back in `Memory` and persists it after each tick.
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
        public var sessionsDone: Bool
        public var allDead: Bool
        public var lastAlive: Bool
        public var waiting: Bool
        public var awsLogin: Bool
        public init(sessionsDone: Bool = true, allDead: Bool = true,
                    lastAlive: Bool = true, waiting: Bool = true, awsLogin: Bool = true) {
            self.sessionsDone = sessionsDone
            self.allDead = allDead
            self.lastAlive = lastAlive
            self.waiting = waiting
            self.awsLogin = awsLogin
        }
    }

    public static let warnPct = 90.0
    public static let rearmBelowPct = 85.0
    /// Work shorter than this ending is not "all sessions finished".
    public static let sessionsDoneMinBusy: TimeInterval = 10 * 60

    /// The latches that would repeat after a relaunch unless remembered.
    /// Only these three: all-dead and waiting seed silently instead.
    public struct Memory: Codable, Equatable, Sendable {
        /// AWS-login needs already pushed (session|profile|failedAt) (#98).
        public var announcedAwsLogins: Set<String>
        /// The account the last-alive warning went out for.
        public var warnedLastAlive: Int?
        /// When the current busy episode began: a relaunch mid-work keeps
        /// the stretch, one right after the work finished still pushes.
        public var busySince: Date?
        public init(announcedAwsLogins: Set<String> = [], warnedLastAlive: Int? = nil, busySince: Date? = nil) {
            self.announcedAwsLogins = announcedAwsLogins
            self.warnedLastAlive = warnedLastAlive
            self.busySince = busySince
        }
    }
    public private(set) var memory: Memory

    private var quietTicks = 0
    private var allDeadAnnounced = false
    /// The first look with accounts seeds silently: a fleet already dead
    /// at launch is on screen (and the phone's countdown activity), and
    /// the app relaunches often enough that announcing it again is noise.
    private var seededAllDead = false
    private var announcedWaiting: Set<Int> = []
    private var seededWaiting = false
    /// Sessions the plugin's hook already announced (#79): the hook pushes
    /// a prompt the moment it appears, and the next poll must not push it
    /// again. Timed — a prompt answered before the record flips to
    /// `waiting` must not pin its pid forever.
    private var hookAnnounced: [Int: Date] = [:]
    public static let hookGrace: TimeInterval = 5 * 60
    private var seededAwsLogins = false
    /// A need that failed this recently is pushed even on the seeding
    /// look: the relaunch (or the first scan) swallowed it, and the user
    /// has likely not seen it (#29). Older ones seed silently as before.
    public static let awsLoginFreshWindow: TimeInterval = 10 * 60

    public init(memory: Memory = Memory()) {
        self.memory = memory
    }

    /// The needs already pushed (session|profile|failedAt), pruned to the
    /// current roster on every scanned tick.
    public var announcedAwsLoginKeys: Set<String> { memory.announcedAwsLogins }

    public mutating func announceWaiting(pid: Int, now: Date = Date()) {
        hookAnnounced[pid] = now
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

    public mutating func tick(busy: Int?, total: Int?,
                              accounts: [Account], flags: Flags,
                              sessions: [SessionDetail]? = nil,
                              awsLogins: [AwsLogin.Item]? = nil,
                              now: Date = Date()) -> [String] {
        var out: [String] = []

        // nil until the transcripts have been scanned once: seeding on
        // an empty first look would push every need already on screen.
        if let awsLogins {
            let needs = awsLogins.filter { $0.pid != nil }
            let seeded = seededAwsLogins
            seededAwsLogins = true
            // Keyed on the failure time too: the same session on the same
            // profile failing again later is news again.
            func key(_ item: AwsLogin.Item) -> String {
                "\(item.id)|\(Int(item.failedAt?.timeIntervalSince1970 ?? 0))"
            }
            for item in needs where !memory.announcedAwsLogins.contains(key(item)) {
                memory.announcedAwsLogins.insert(key(item))
                let fresh = item.failedAt.map { now.timeIntervalSince($0) < Self.awsLoginFreshWindow } ?? false
                if flags.awsLogin, seeded || fresh {
                    let who = item.sessionLabel ?? "session \(item.pid ?? 0)"
                    out.append("needs AWS login — \(who) (\(item.profile))")
                }
            }
            memory.announcedAwsLogins = memory.announcedAwsLogins.intersection(needs.map(key))
        }

        if let sessions {
            let waiting = sessions.filter { $0.status == "waiting" }
            // The first look seeds silently: a session that was already
            // waiting when the app launched is not news, and a relaunch
            // must not re-push every stale prompt.
            let seeded = seededWaiting
            seededWaiting = true
            hookAnnounced = hookAnnounced.filter { now.timeIntervalSince($0.value) < Self.hookGrace }
            for session in waiting where !announcedWaiting.contains(session.pid) {
                announcedWaiting.insert(session.pid)
                if flags.waiting, seeded, hookAnnounced[session.pid] == nil {
                    let repo = URL(fileURLWithPath: session.cwd).lastPathComponent
                    out.append("waiting on you — \(repo) needs an answer")
                }
            }
            announcedWaiting = announcedWaiting.intersection(waiting.map(\.pid))
        }

        if let busy {
            if busy > 0 {
                if memory.busySince == nil { memory.busySince = now }
                quietTicks = 0
            } else if let since = memory.busySince {
                quietTicks += 1
                if quietTicks >= 2 {
                    memory.busySince = nil
                    quietTicks = 0
                    // A stretch persisted across a long gap (quit mid-work, sessions
                    // closed meanwhile) must not announce "0 of 0 working".
                    if flags.sessionsDone, (total ?? 0) > 0, now.timeIntervalSince(since) >= Self.sessionsDoneMinBusy {
                        out.append("all sessions finished — 0 of \(total ?? 0) working")
                    }
                }
            }
        }

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
