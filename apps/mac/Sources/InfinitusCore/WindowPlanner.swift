import Foundation

// MARK: - Reset battle plans (#7 layer 2, compute-only)
//
// docs/research/smart-engine.md. The physics: a 5h window starts on the
// FIRST request after the previous one expired, so an idle account's clock
// can be started on purpose (an "igniter": one tiny request via `cswap run`)
// without switching the fleet. The planner turns that into a battle plan —
// ordered (instant, action, why) steps — that a card can show and the user
// can cancel. It only ever proposes: ignite, switch, hold (ride a short
// stall out), and the expected reset that follows. Nothing here executes;
// executing a step is a later layer behind a confirm.
//
// `replay` is the verification path: run the same bookkeeping over a
// recorded stretch of usage history and report what the fleet actually did
// — switches, how many landed on a cold clock (a plan could have pre-ignited
// them), and how long the active account sat bound at 100%.
public enum WindowPlanner {
    public struct Config: Sendable, Equatable {
        /// A bind further out than this is not planned for yet.
        public var horizon: Double = 2 * 3600
        /// Open question 1: how long a stall between the active window
        /// binding and its own reset the user accepts before rotation is
        /// preferred. Within it the plan says "hold" instead of "switch".
        public var stallTolerance: Double = 15 * 60
        /// Never ignite an account whose weekly reserve is this spent —
        /// the fleet's last headroom is not for warming up.
        public var reserveFloorPct: Double = 95
        /// A window must have at least this much left when the switch
        /// lands, or it isn't worth landing on: an ignited window that
        /// has aged past this by the bind (the bind came later than
        /// projected) would give minutes and then a stall — worse than a
        /// cold clock. Applies to warm candidates and to the ignition
        /// itself.
        public var minRemainingAtSwitch: Double = 90 * 60
        /// Length of a 5h window.
        public static let windowLength: Double = 18_000
        public init() {}
    }

    /// One account as the planner sees it. Built from the live snapshot or,
    /// for the pane's dry run, from each account's latest usage sample.
    public struct AccountState: Sendable, Equatable {
        public let number: Int
        public let email: String
        public let active: Bool
        public let disabled: Bool
        public let fiveHourPct: Double?
        public let fiveHourResetsAt: Double?
        /// Worst of 7d / per-model — the weekly reserve.
        public let weeklyPct: Double

        public init(number: Int, email: String, active: Bool, disabled: Bool = false,
                    fiveHourPct: Double?, fiveHourResetsAt: Double?, weeklyPct: Double) {
            self.number = number
            self.email = email
            self.active = active
            self.disabled = disabled
            self.fiveHourPct = fiveHourPct
            self.fiveHourResetsAt = fiveHourResetsAt
            self.weeklyPct = weeklyPct
        }

        /// No window ticking: the next request starts a fresh one.
        public func coldClock(now: Double) -> Bool {
            guard let reset = fiveHourResetsAt, reset > now else { return true }
            return false
        }

        var shortName: String { email.split(separator: "@").first.map(String.init) ?? email }
    }

    public enum Action: Codable, Sendable, Equatable {
        /// Start the account's 5h clock without switching (`cswap run`).
        case ignite(Int)
        case switchTo(Int)
        /// Stay put through a short stall — the reset is close.
        case hold(Int)
        /// Expectation marker, not an action: the account's window resets.
        case reset(Int)

        public var number: Int {
            switch self {
            case .ignite(let n), .switchTo(let n), .hold(let n), .reset(let n): return n
            }
        }

        /// Wire name (`infinitusctl plan`, the phone mirror).
        public var name: String {
            switch self {
            case .ignite: return "ignite"
            case .switchTo: return "switch"
            case .hold: return "hold"
            case .reset: return "reset"
            }
        }
    }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public let at: Double
        public let action: Action
        public let why: String
        public var id: String { "\(at)|\(action)" }
        public init(at: Double, action: Action, why: String) {
            self.at = at
            self.action = action
            self.why = why
        }
    }

    public struct Plan: Codable, Sendable, Equatable {
        /// When the active account's 5h window is projected to bind.
        public let bindAt: Double
        public let steps: [Step]
        public init(bindAt: Double, steps: [Step]) {
            self.bindAt = bindAt
            self.steps = steps
        }
        public var ignites: Bool { steps.contains { if case .ignite = $0.action { return true }; return false } }
        /// The account an ignite step names, if the plan has one.
        public var igniteNumber: Int? {
            steps.lazy.compactMap { if case .ignite(let n) = $0.action { return n }; return nil }.first
        }
    }

    /// Flat wire shape of a plan (Action is an enum with payload, so the
    /// Codable form is spelled out): `infinitusctl plan`, the phone.
    public struct Payload: Codable, Sendable, Equatable {
        public struct Step: Codable, Sendable, Equatable {
            public let at: Double
            public let action: String
            public let number: Int
            public let why: String
        }
        public let bindAt: Double
        public let steps: [Step]
        public init(_ plan: Plan) {
            bindAt = plan.bindAt
            steps = plan.steps.map { .init(at: $0.at, action: $0.action.name,
                                           number: $0.action.number, why: $0.why) }
        }
    }

    /// The cswap igniter: one ~1K-token request as account `number`
    /// through `cswap run`, which execs claude under that account's own
    /// CLAUDE_CONFIG_DIR — the default login and the fleet stay untouched
    /// (docs/research/smart-engine.md, "The primitive we already have").
    /// Engines expose it as `AccountEngine.ignite` (capability `.ignite`).
    public static func igniterArguments(number: Int) -> [String] {
        ["run", "\(number)", "--", "-p", ".", "--max-turns", "1"]
    }

    /// The core decision, evaluated each poll. Nil means "nothing to plan":
    /// no sprint running, no ticking window on the active account, no
    /// measurable burn, the window resets before it binds, or the bind is
    /// beyond the horizon. `burnPctPerHour` is the active account's 5h
    /// burn (WindowTelemetry.burnRate).
    /// `measuredAt`: when the active account's pct was read — the bind
    /// extrapolates from there, not from `now` (UsageForecast.build).
    public static func plan(accounts: [AccountState], burnPctPerHour: Double?,
                            busySessions: Int, now: Double, measuredAt: Double? = nil,
                            config: Config = Config()) -> Plan? {
        guard busySessions > 0,
              let active = accounts.first(where: { $0.active }),
              let pct = active.fiveHourPct,
              let reset = active.fiveHourResetsAt, reset > now else { return nil }

        let bindAt: Double
        if pct >= 100 {
            bindAt = now
        } else {
            guard let rate = burnPctPerHour, rate > 0 else { return nil }
            bindAt = max(now, min(measuredAt ?? now, now) + (100 - pct) / rate * 3600)
        }
        guard bindAt < reset, bindAt - now <= config.horizon else { return nil }

        let minutes = { (s: Double) in Int((s / 60).rounded()) }
        if reset - bindAt <= config.stallTolerance {
            return Plan(bindAt: bindAt, steps: [
                Step(at: bindAt, action: .hold(active.number),
                     why: "\(active.shortName) binds \(minutes(reset - bindAt)) min before its own reset — ride it out"),
                Step(at: reset, action: .reset(active.number),
                     why: "\(active.shortName)'s window resets — same account, back to back"),
            ])
        }

        // Most weekly headroom first; must be usable at the switch: a cold
        // clock (fresh window on the first request — or on ignition, if
        // the ignited window still has enough left at the bind), a window
        // that resets before the bind lands (fresh again), or a ticking
        // window with enough left after the bind to be worth landing on.
        let ignitedResetAt = now + Config.windowLength
        let candidates = accounts.filter { a in
            guard !a.active, !a.disabled, a.weeklyPct < config.reserveFloorPct else { return false }
            if a.coldClock(now: now) {
                return ignitedResetAt - bindAt >= config.minRemainingAtSwitch
            }
            let reset = a.fiveHourResetsAt ?? .infinity
            if reset <= bindAt { return true }
            return (a.fiveHourPct ?? 0) < 100 && reset - bindAt >= config.minRemainingAtSwitch
        }
        guard let cand = candidates.min(by: { $0.weeklyPct < $1.weeklyPct }) else { return nil }

        if cand.coldClock(now: now) {
            let resetAt = ignitedResetAt
            return Plan(bindAt: bindAt, steps: [
                Step(at: now, action: .ignite(cand.number),
                     why: "\(cand.shortName)'s 5h clock is cold — start it now so its window is "
                        + "\(minutes(bindAt - now)) min old at the switch"),
                Step(at: bindAt, action: .switchTo(cand.number),
                     why: "\(active.shortName) binds; \(cand.shortName) has the most weekly headroom "
                        + "(\(Int(cand.weeklyPct.rounded()))%)"),
                Step(at: resetAt, action: .reset(cand.number),
                     why: "\(cand.shortName)'s ignited window resets mid-sprint — second session on the same account"),
            ])
        }
        // A window that resets before the bind is fresh again by the time
        // we land on it — nothing left to schedule after the switch.
        let headroom = "\(cand.shortName) has the most weekly headroom (\(Int(cand.weeklyPct.rounded()))%)"
        guard let candReset = cand.fiveHourResetsAt, candReset > bindAt else {
            return Plan(bindAt: bindAt, steps: [
                Step(at: bindAt, action: .switchTo(cand.number),
                     why: "\(active.shortName) binds; \(headroom) and a fresh 5h window by then"),
            ])
        }
        return Plan(bindAt: bindAt, steps: [
            Step(at: bindAt, action: .switchTo(cand.number),
                 why: "\(active.shortName) binds; \(headroom) and a window already ticking"),
            Step(at: candReset, action: .reset(cand.number),
                 why: "\(cand.shortName)'s window resets \(minutes(candReset - bindAt)) min into the switch"),
        ])
    }

    // MARK: replay

    public struct ReplayReport: Sendable, Equatable {
        public let from: Double
        public let to: Double
        /// Active account changed between consecutive polls.
        public let switches: Int
        /// Switches whose target had no window ticking — a plan could have
        /// ignited it ahead of time.
        public let coldSwitches: Int
        /// Seconds the active account spent at 100% on its 5h window.
        public let stalledSeconds: Double
        /// Whether any sample in range carried the `active` flag; without
        /// it switches can't be seen (lines written before the flag).
        public let sawActiveFlag: Bool
        public init(from: Double, to: Double, switches: Int, coldSwitches: Int,
                    stalledSeconds: Double, sawActiveFlag: Bool) {
            self.from = from
            self.to = to
            self.switches = switches
            self.coldSwitches = coldSwitches
            self.stalledSeconds = stalledSeconds
            self.sawActiveFlag = sawActiveFlag
        }
    }

    /// What the fleet actually did over [from, to]. Reads switches off the
    /// `active` flag of consecutive samples; samples before `from` still
    /// feed the per-account "last seen" state so a cold check at the range
    /// edge has something to look at.
    public static func replay(_ samples: [UsageSample], from: Double, to: Double) -> ReplayReport {
        var latest: [String: UsageSample] = [:]
        var activeEmail: String?
        var switches = 0, cold = 0
        var stalledSince: Double?
        var stalled: Double = 0
        var sawFlag = false

        func endStall(at t: Double) {
            if let since = stalledSince { stalled += max(0, min(t, to) - max(since, from)) }
            stalledSince = nil
        }

        for s in samples.sorted(by: { $0.t < $1.t }) where s.t <= to {
            defer { latest[s.email] = s }
            guard s.active == true else { continue }
            if s.t >= from { sawFlag = true }
            if let cur = activeEmail, cur != s.email {
                endStall(at: s.t)
                if s.t >= from {
                    switches += 1
                    let prev = latest[s.email]
                    let ticking = prev?.fiveHour?.resetsAt.map { $0 > s.t } ?? false
                    if prev != nil && !ticking { cold += 1 }
                }
            }
            activeEmail = s.email
            let bound = (s.fiveHour?.pct ?? 0) >= 100
            if bound {
                if stalledSince == nil { stalledSince = s.t }
            } else {
                endStall(at: s.t)
            }
        }
        endStall(at: to)
        return ReplayReport(from: from, to: to, switches: switches, coldSwitches: cold,
                            stalledSeconds: stalled, sawActiveFlag: sawFlag)
    }
}

extension WindowTelemetry {
    /// The account's 5h burn in pct/hour over the last `lookback` seconds,
    /// measured inside its current window (a reset in between would make
    /// the delta meaningless). Nil below ten minutes of observation or
    /// when the pct went down.
    public static func burnRate(_ samples: [UsageSample], email: String, now: Double,
                                lookback: Double = 3600,
                                resetSlack: Double = resetSlack) -> Double? {
        burnRate(samples, email: email, now: now, lookback: lookback,
                 resetSlack: resetSlack, window: { $0.fiveHour })
    }
}
