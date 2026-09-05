import Foundation

/// Engineering metrics (user 2026-09-04: PRs, commits, lines, human vs
/// relayed messages, sessions — per day/week/month/year). One `Day` per
/// local calendar day; days add, so any period is a sum. Pure — the
/// scanners in StatsScanner / RepoStats / StatsEvents produce days, the
/// app merges and folds them.
public enum Stats {
    /// Where a stretch's effort went (issue #24). Raw values are the
    /// `Day.activities` keys — they travel in the cache and the bundle,
    /// so never rename one. The rule that picks a case lives in
    /// `StatsScanner.Stretch.activity`.
    public enum Activity: String, CaseIterable, Codable, Sendable {
        case review, tests, plan, debug, browser, simulator, explanation, code, other

        public var title: String {
            switch self {
            case .review: return "Code & PR review"
            case .tests: return "Writing tests"
            case .plan: return "Plan & design"
            case .debug: return "Debugging"
            case .browser: return "Browser & computer use"
            case .simulator: return "Simulator & device"
            case .explanation: return "Explanations"
            case .code: return "Coding"
            case .other: return "Other"
            }
        }
    }

    /// Which tool wrote a transcript. Raw values are the `Day.byEngine`
    /// keys — cached and mirrored, so never rename one.
    public enum Engine: String, CaseIterable, Codable, Sendable {
        case claude, codex

        public var title: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex CLI"
            }
        }
    }

    /// One bucket of effort — per activity, or per model. Short coding
    /// keys: eight Days × (9 activities + 6 models) of these ride in
    /// every mirrored bundle.
    public struct ActivityTally: Codable, Equatable, Sendable {
        public var stretches = 0
        public var seconds = 0.0
        public var inputTokens = 0
        public var outputTokens = 0
        public var usd = 0.0
        public init() {}

        enum CodingKeys: String, CodingKey {
            case stretches = "n", seconds = "s", inputTokens = "in", outputTokens = "out", usd
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stretches = try c.decodeIfPresent(Int.self, forKey: .stretches) ?? 0
            seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
            inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
            outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? 0
        }

        public static func + (a: ActivityTally, b: ActivityTally) -> ActivityTally {
            var c = a
            c.stretches += b.stretches
            c.seconds += b.seconds
            c.inputTokens += b.inputTokens
            c.outputTokens += b.outputTokens
            c.usd += b.usd
            return c
        }
    }

    public struct Day: Codable, Equatable, Sendable {
        // Messages
        public var humanMessages = 0      // typed at the keyboard
        public var phoneMessages = 0      // typed on the phone (human too)
        public var agentMessages = 0      // other Claude sessions
        public var nudges = 0             // the app's own "[Infinitus] …"
        // Work
        public var turns = 0
        public var toolCalls: [String: Int] = [:]
        public var toolErrors = 0
        public var questions = 0          // AskUserQuestion
        public var denials = 0            // tool calls the user denied
        public var waitingSeconds = 0.0   // turn end → next human/phone message, ≤ 8 h each
        public var subagents = 0
        public var compactions = 0
        public var retries = 0
        public var longestUnattended = 0  // most tool calls between two human messages
        // Tokens
        public var inputTokens = 0
        public var outputTokens = 0
        public var usd = 0.0
        /// Output tokens per minute of the day (minute index → tokens),
        /// summed across every session — the scan's working set for the
        /// peak below; emptied by `compacted()` and meaningless once days
        /// are folded together (the peak is what survives a fold).
        public var minuteTokens: [Int: Int] = [:]
        /// The busiest minute's output tokens (tokens/min records, #89);
        /// across days, the highest single day's.
        public var peakTokensPerMinute = 0
        public var peakMinute: Int?
        /// Effort per `Activity.rawValue` (main transcripts only) and per
        /// model id (sub-agent transcripts included). Additive like
        /// everything else here, so folding needs nothing new.
        public var activities: [String: ActivityTally] = [:]
        public var byModel: [String: ActivityTally] = [:]
        /// Per engine (`Engine.rawValue`: the tool that wrote the
        /// transcript) and per effort setting (`low`…`max`, `unset`
        /// when the entry carries none), the same way.
        public var byEngine: [String: ActivityTally] = [:]
        public var byEffort: [String: ActivityTally] = [:]
        // Sessions
        public var sessions: Set<String> = []
        public var sessionTally = 0       // compact form for the phone: set emptied, count kept
        public var sessionSeconds = 0.0
        public var sessionBuckets = [0, 0, 0, 0]   // <15m, 15-60m, 1-4h, >4h; one session per file-day
        public var hours: [Int] = Array(repeating: 0, count: 168)   // weekday(Mon=0)*24 + hour
        // Git
        public var commits = 0
        public var linesAdded = 0
        public var linesRemoved = 0
        public var filesTouched = 0
        public var coAuthoredByClaude = 0
        public var reverts = 0
        public var repos: Set<String> = []
        public var repoTally = 0          // compact form for the phone: set emptied, count kept
        // GitHub
        public var prsOpened = 0
        public var prsMerged = 0
        public var mergeHoursTotal = 0.0
        public var mergeCount = 0
        // App events
        public var switches = 0
        public var limitStops = 0
        public var revivals = 0
        public var ignites = 0
        public var resumes = 0
        public var minutesLostToLimits = 0.0

        public init() {}

        public static func + (a: Day, b: Day) -> Day {
            var c = a
            c.humanMessages += b.humanMessages
            c.phoneMessages += b.phoneMessages
            c.agentMessages += b.agentMessages
            c.nudges += b.nudges
            c.turns += b.turns
            c.toolCalls.merge(b.toolCalls, uniquingKeysWith: +)
            c.toolErrors += b.toolErrors
            c.questions += b.questions
            c.denials += b.denials
            c.waitingSeconds += b.waitingSeconds
            c.subagents += b.subagents
            c.compactions += b.compactions
            c.retries += b.retries
            c.longestUnattended = max(a.longestUnattended, b.longestUnattended)
            c.inputTokens += b.inputTokens
            c.outputTokens += b.outputTokens
            c.usd += b.usd
            c.minuteTokens.merge(b.minuteTokens, uniquingKeysWith: +)
            if b.peakTokensPerMinute > a.peakTokensPerMinute {
                c.peakTokensPerMinute = b.peakTokensPerMinute
                c.peakMinute = b.peakMinute
            }
            c.activities.merge(b.activities, uniquingKeysWith: +)
            c.byModel.merge(b.byModel, uniquingKeysWith: +)
            c.byEngine.merge(b.byEngine, uniquingKeysWith: +)
            c.byEffort.merge(b.byEffort, uniquingKeysWith: +)
            c.sessions.formUnion(b.sessions)
            c.sessionTally += b.sessionTally
            c.sessionSeconds += b.sessionSeconds
            c.sessionBuckets = summed(a.sessionBuckets, b.sessionBuckets)
            c.hours = summed(a.hours, b.hours)
            c.commits += b.commits
            c.linesAdded += b.linesAdded
            c.linesRemoved += b.linesRemoved
            c.filesTouched += b.filesTouched
            c.coAuthoredByClaude += b.coAuthoredByClaude
            c.reverts += b.reverts
            c.repos.formUnion(b.repos)
            c.repoTally += b.repoTally
            c.prsOpened += b.prsOpened
            c.prsMerged += b.prsMerged
            c.mergeHoursTotal += b.mergeHoursTotal
            c.mergeCount += b.mergeCount
            c.switches += b.switches
            c.limitStops += b.limitStops
            c.revivals += b.revivals
            c.ignites += b.ignites
            c.resumes += b.resumes
            c.minutesLostToLimits += b.minutesLostToLimits
            return c
        }

        /// Element-wise sum that survives a `compacted()` operand: the
        /// two histograms are only the same length while both days are
        /// full-fat, so iterate the shorter and keep the longer's tail
        /// rather than trapping on an index.
        private static func summed(_ a: [Int], _ b: [Int]) -> [Int] {
            var out = a.count >= b.count ? a : b
            for i in 0..<min(a.count, b.count) { out[i] = a[i] + b[i] }
            return out
        }

        /// The travelling form: identity sets folded into their tallies
        /// and the per-hour histogram dropped. `hours[168]` riding on
        /// eight Days is what made the mirrored bundle 14.8 KB (spec:
        /// ≤ 4 KB) and `infinitusctl stats --period year` ~0.5 MB.
        /// Idempotent — `sessionCount`/`repoCount` already read the
        /// tally once the set is empty.
        /// The day's peak from its minute buckets — after every file's
        /// share of the day has been merged in (a merge of two files'
        /// same minute adds up to more than either's peak).
        public mutating func finalizePeak() {
            guard let top = minuteTokens.max(by: { $0.value < $1.value }) else { return }
            peakTokensPerMinute = top.value
            peakMinute = top.key
        }

        public func compacted() -> Day {
            var d = self
            d.minuteTokens = [:]
            d.sessionTally = sessionCount
            d.sessions = []
            d.repoTally = repoCount
            d.repos = []
            d.hours = []
            d.byModel = Self.topModels(byModel, keep: 6)
            return d
        }

        /// The `keep` costliest models by $ stay; everything else sums
        /// under "other" (which itself counts as one of the kept keys
        /// when present, so a compacted Day compacts to itself).
        public static func topModels(_ models: [String: ActivityTally], keep: Int) -> [String: ActivityTally] {
            var named = models
            var other = named.removeValue(forKey: "other") ?? ActivityTally()
            guard named.count > keep else { return models }
            let sorted = named.sorted { $0.value.usd == $1.value.usd ? $0.key < $1.key : $0.value.usd > $1.value.usd }
            var out: [String: ActivityTally] = [:]
            for (i, (key, tally)) in sorted.enumerated() {
                if i < keep { out[key] = tally } else { other = other + tally }
            }
            out["other"] = other
            return out
        }

        /// Hand-written so a Day written by a NEWER build still decodes:
        /// every field falls back to its memberwise default. The
        /// synthesized initializer throws on the first missing key,
        /// which would drop both stats caches on the ground every time
        /// a field is added AND make an older phone fail to decode the
        /// whole `MirrorSnapshot`, not just its stats. Encoding stays
        /// synthesized.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Day()
            humanMessages = try c.decodeIfPresent(Int.self, forKey: .humanMessages) ?? d.humanMessages
            phoneMessages = try c.decodeIfPresent(Int.self, forKey: .phoneMessages) ?? d.phoneMessages
            agentMessages = try c.decodeIfPresent(Int.self, forKey: .agentMessages) ?? d.agentMessages
            nudges = try c.decodeIfPresent(Int.self, forKey: .nudges) ?? d.nudges
            turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? d.turns
            toolCalls = try c.decodeIfPresent([String: Int].self, forKey: .toolCalls) ?? d.toolCalls
            toolErrors = try c.decodeIfPresent(Int.self, forKey: .toolErrors) ?? d.toolErrors
            questions = try c.decodeIfPresent(Int.self, forKey: .questions) ?? d.questions
            denials = try c.decodeIfPresent(Int.self, forKey: .denials) ?? d.denials
            waitingSeconds = try c.decodeIfPresent(Double.self, forKey: .waitingSeconds) ?? d.waitingSeconds
            subagents = try c.decodeIfPresent(Int.self, forKey: .subagents) ?? d.subagents
            compactions = try c.decodeIfPresent(Int.self, forKey: .compactions) ?? d.compactions
            retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? d.retries
            longestUnattended = try c.decodeIfPresent(Int.self, forKey: .longestUnattended) ?? d.longestUnattended
            inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? d.inputTokens
            outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? d.outputTokens
            usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? d.usd
            activities = try c.decodeIfPresent([String: ActivityTally].self, forKey: .activities) ?? d.activities
            byModel = try c.decodeIfPresent([String: ActivityTally].self, forKey: .byModel) ?? d.byModel
            byEngine = try c.decodeIfPresent([String: ActivityTally].self, forKey: .byEngine) ?? d.byEngine
            byEffort = try c.decodeIfPresent([String: ActivityTally].self, forKey: .byEffort) ?? d.byEffort
            sessions = try c.decodeIfPresent(Set<String>.self, forKey: .sessions) ?? d.sessions
            sessionTally = try c.decodeIfPresent(Int.self, forKey: .sessionTally) ?? d.sessionTally
            sessionSeconds = try c.decodeIfPresent(Double.self, forKey: .sessionSeconds) ?? d.sessionSeconds
            sessionBuckets = try c.decodeIfPresent([Int].self, forKey: .sessionBuckets) ?? d.sessionBuckets
            hours = try c.decodeIfPresent([Int].self, forKey: .hours) ?? d.hours
            commits = try c.decodeIfPresent(Int.self, forKey: .commits) ?? d.commits
            linesAdded = try c.decodeIfPresent(Int.self, forKey: .linesAdded) ?? d.linesAdded
            linesRemoved = try c.decodeIfPresent(Int.self, forKey: .linesRemoved) ?? d.linesRemoved
            filesTouched = try c.decodeIfPresent(Int.self, forKey: .filesTouched) ?? d.filesTouched
            coAuthoredByClaude = try c.decodeIfPresent(Int.self, forKey: .coAuthoredByClaude) ?? d.coAuthoredByClaude
            reverts = try c.decodeIfPresent(Int.self, forKey: .reverts) ?? d.reverts
            repos = try c.decodeIfPresent(Set<String>.self, forKey: .repos) ?? d.repos
            repoTally = try c.decodeIfPresent(Int.self, forKey: .repoTally) ?? d.repoTally
            prsOpened = try c.decodeIfPresent(Int.self, forKey: .prsOpened) ?? d.prsOpened
            prsMerged = try c.decodeIfPresent(Int.self, forKey: .prsMerged) ?? d.prsMerged
            mergeHoursTotal = try c.decodeIfPresent(Double.self, forKey: .mergeHoursTotal) ?? d.mergeHoursTotal
            mergeCount = try c.decodeIfPresent(Int.self, forKey: .mergeCount) ?? d.mergeCount
            switches = try c.decodeIfPresent(Int.self, forKey: .switches) ?? d.switches
            limitStops = try c.decodeIfPresent(Int.self, forKey: .limitStops) ?? d.limitStops
            revivals = try c.decodeIfPresent(Int.self, forKey: .revivals) ?? d.revivals
            ignites = try c.decodeIfPresent(Int.self, forKey: .ignites) ?? d.ignites
            resumes = try c.decodeIfPresent(Int.self, forKey: .resumes) ?? d.resumes
            minutesLostToLimits = try c.decodeIfPresent(Double.self, forKey: .minutesLostToLimits) ?? d.minutesLostToLimits
            // Added with the tokens/min records (#89) and missed here at
            // first: every cache load then dropped the minute buckets, so
            // the "peak" was only the last pass's fresh bytes (2026-09-05).
            minuteTokens = try c.decodeIfPresent([Int: Int].self, forKey: .minuteTokens) ?? d.minuteTokens
            peakTokensPerMinute = try c.decodeIfPresent(Int.self, forKey: .peakTokensPerMinute) ?? d.peakTokensPerMinute
            peakMinute = try c.decodeIfPresent(Int.self, forKey: .peakMinute) ?? d.peakMinute
        }

        // Derived — nil when the denominator is zero (tiles show "—").
        public var messages: Int { humanMessages + phoneMessages }
        public var totalToolCalls: Int { toolCalls.values.reduce(0, +) }
        public var sessionCount: Int { sessions.isEmpty ? sessionTally : sessions.count }
        public var repoCount: Int { repos.isEmpty ? repoTally : repos.count }
        public var messagesPerCommit: Double? { ratio(Double(messages), Double(commits)) }
        public var toolCallsPerHumanMessage: Double? { ratio(Double(totalToolCalls), Double(messages)) }
        public var usdPerCommit: Double? { ratio(usd, Double(commits)) }
        public var usdPerPR: Double? { ratio(usd, Double(prsMerged)) }
        public var tokensPerLine: Double? { ratio(Double(outputTokens), Double(linesAdded + linesRemoved)) }
        public var humanShare: Double? { ratio(Double(messages), Double(messages + agentMessages + nudges)) }
        public var meanMergeHours: Double? { ratio(mergeHoursTotal, Double(mergeCount)) }
        private func ratio(_ n: Double, _ d: Double) -> Double? { d > 0 ? n / d : nil }

        /// 0..3 by <15m, <1h, <4h, else >4h.
        public static func sessionBucket(seconds: Double) -> Int {
            if seconds < 900 { return 0 }
            if seconds < 3600 { return 1 }
            if seconds < 14400 { return 2 }
            return 3
        }
    }

    public enum Period: String, Codable, CaseIterable, Sendable {
        case day, week, month, year
        public var title: String {
            switch self {
            case .day: "Today"
            case .week: "This week"
            case .month: "This month"
            case .year: "This year"
            }
        }
    }

    /// One day in a period's series — a key and its facts.
    public struct DayPoint: Codable, Equatable, Sendable {
        public let key: String
        public let day: Day
        public init(key: String, day: Day) { self.key = key; self.day = day }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public let period: Period
        public let from: String          // first day key, inclusive
        public let to: String            // last day key, inclusive
        public var total: Day
        public var previous: Day         // the calendar period before `from`
        public var daily: [DayPoint]     // every day from `from` to `to`, empty days included
        public var streak: Int           // consecutive days ending today with a commit or a human message

        /// Every Day in the summary in its travelling form — see
        /// `Day.compacted()`. `daily` matters here too: a year's
        /// series carried the 168-slot histogram and the session set
        /// 365 times over (`infinitusctl stats --period year` was
        /// ~0.5 MB).
        public func compacted() -> Summary {
            var s = self
            s.total = s.total.compacted()
            s.previous = s.previous.compacted()
            s.previous.activities = [:]
            s.previous.byModel = [:]
            s.previous.byEngine = [:]
            s.previous.byEffort = [:]
            s.daily = s.daily.map {
                var day = $0.day.compacted()
                day.activities = [:]
                day.byModel = [:]
                day.byEngine = [:]
                day.byEffort = [:]
                return DayPoint(key: $0.key, day: day)
            }
            return s
        }
    }

    /// What travels to the phone / the wall: the four periods without
    /// their day series.
    public struct Bundle: Codable, Equatable, Sendable {
        public let computedAt: Date
        public let periods: [Summary]
        /// Absent in bundles from a Mac older than #89.
        public var tokenRecords: TokenRecords?
        public init(days: [String: Day], now: Date = Date(), calendar: Calendar = .current) {
            computedAt = now
            periods = Period.allCases.map { p in
                var s = fold(days: days, period: p, now: now, calendar: calendar)
                s.daily = []
                return s.compacted()
            }
            tokenRecords = TokenRecords(days: days, now: now, calendar: calendar)
        }
        public func summary(_ p: Period) -> Summary? { periods.first { $0.period == p } }
    }

    /// The tokens/min record book (#89, user 2026-09-05: "is the trend
    /// upward or downward and how often I break new records"): every
    /// day's peak minute against the best before it.
    public struct TokenRecords: Codable, Equatable, Sendable {
        public struct Mark: Codable, Equatable, Sendable {
            public let day: String
            public let tokensPerMinute: Int
            public init(day: String, tokensPerMinute: Int) { self.day = day; self.tokensPerMinute = tokensPerMinute }
        }
        /// The all-time best.
        public var best: Mark?
        /// Today's busiest minute so far.
        public var today = 0
        /// Days a new all-time record was set, newest first, at most `keep`.
        public var records: [Mark] = []
        /// How many of those fell in the current calendar month.
        public var recordsThisMonth = 0
        /// The last 30 days' peaks, oldest first (a sparkline).
        public var dailyPeaks: [Int] = []
        /// Median of the last 7 days' peaks over the 7 before — > 1 is
        /// up; nil until both weeks have a busy day.
        public var trend: Double?
        public static let keep = 24

        public init() {}

        public init(days: [String: Day], now: Date, calendar: Calendar = .current) {
            var best = 0
            var marks: [Mark] = []
            for key in days.keys.sorted() {
                let peak = days[key]?.peakTokensPerMinute ?? 0
                guard peak > best else { continue }
                best = peak
                marks.append(Mark(day: key, tokensPerMinute: peak))
            }
            self.best = marks.last
            records = Array(marks.reversed().prefix(Self.keep))
            let monthKey = String(dayKey(now, calendar: calendar).prefix(7))
            recordsThisMonth = marks.filter { $0.day.hasPrefix(monthKey) }.count
            let todayKey = dayKey(now, calendar: calendar)
            today = days[todayKey]?.peakTokensPerMinute ?? 0
            var peaks: [Int] = []
            var cursor = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
            for _ in 0..<30 {
                peaks.append(days[dayKey(cursor, calendar: calendar)]?.peakTokensPerMinute ?? 0)
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
            dailyPeaks = peaks
            let last = Self.median(peaks.suffix(7).filter { $0 > 0 })
            let before = Self.median(peaks.dropLast(7).suffix(7).filter { $0 > 0 })
            if let last, let before, before > 0 { trend = Double(last) / Double(before) }
        }

        static func median(_ values: [Int]) -> Int? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
    }

    // MARK: keys

    /// "yyyy-MM-dd" in the calendar's own zone, via `Calendar` rather
    /// than a `DateFormatter`.
    ///
    /// Why not a formatter: setting `DateFormatter.timeZone` to a named
    /// IANA zone TRAPS on Windows (swift-corelibs-foundation, Swift
    /// 6.3.3 — verified 2026-09-05: the setter succeeds and the next
    /// `string(from:)` kills the process, which took the whole `swift
    /// test` run down at `StatsTests`). `Calendar.dateComponents` on the
    /// same zone works, and the key is a fixed-width ASCII date with no
    /// locale in it, so nothing is lost by formatting it by hand.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// Midnight of a `dayKey`'s day in the calendar's zone — the inverse
    /// of `dayKey`, same reason it avoids a formatter.
    public static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    /// Minute of the local day, 0…1439, for an epoch-seconds stamp.
    public static func minuteOfDay(_ t: Double, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Monday = 0 … Sunday = 6, times 24, plus the hour.
    public static func hourSlot(_ date: Date, calendar: Calendar = .current) -> Int {
        let weekday = (calendar.component(.weekday, from: date) + 5) % 7
        return weekday * 24 + calendar.component(.hour, from: date)
    }

    // MARK: folding

    public static func fold(days: [String: Day], period: Period, now: Date = Date(),
                            calendar: Calendar = .current) -> Summary {
        let (start, end) = range(period, now: now, calendar: calendar)
        let previousStart: Date
        switch period {
        case .day:
            previousStart = calendar.date(byAdding: .day, value: -1, to: start)!
        case .week:
            previousStart = calendar.date(byAdding: .day, value: -7, to: start)!
        case .month:
            previousStart = calendar.date(byAdding: .month, value: -1, to: start)!
        case .year:
            previousStart = calendar.date(byAdding: .year, value: -1, to: start)!
        }
        let previousEnd = start
        var total = Day(), previous = Day(), daily: [DayPoint] = []
        var cursor = start
        while cursor < end {
            let key = dayKey(cursor, calendar: calendar)
            let day = days[key] ?? Day()
            total = total + day
            daily.append(DayPoint(key: key, day: day))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        cursor = previousStart
        while cursor < previousEnd {
            previous = previous + (days[dayKey(cursor, calendar: calendar)] ?? Day())
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        var streak = 0
        var back = calendar.startOfDay(for: now)
        // Today hasn't necessarily started yet: at 09:00 with no commit
        // and no message so far, counting from today would read a
        // 40-day streak as 0. Nothing today → count from yesterday.
        func active(_ d: Date) -> Bool {
            guard let day = days[dayKey(d, calendar: calendar)] else { return false }
            return day.commits > 0 || day.messages > 0
        }
        if !active(back) { back = calendar.date(byAdding: .day, value: -1, to: back)! }
        while let d = days[dayKey(back, calendar: calendar)], d.commits > 0 || d.messages > 0 {
            streak += 1
            back = calendar.date(byAdding: .day, value: -1, to: back)!
        }
        let last = calendar.date(byAdding: .day, value: -1, to: end)!
        return Summary(period: period, from: dayKey(start, calendar: calendar),
                       to: dayKey(last, calendar: calendar), total: total, previous: previous,
                       daily: daily, streak: streak)
    }

    /// [start, end) of the period containing `now`; weeks are Monday to
    /// Sunday whatever the locale's own first weekday is (spec) — the
    /// same Mon=0 convention `hourSlot` already hardcodes, so a US
    /// calendar's Sunday start can't shift the week bucket off the
    /// heatmap by a day.
    static func range(_ period: Period, now: Date, calendar: Calendar) -> (Date, Date) {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .day:
            return (today, calendar.date(byAdding: .day, value: 1, to: today)!)
        case .week:
            var mondays = calendar
            mondays.firstWeekday = 2
            let comps = mondays.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
            let start = mondays.date(from: comps)!
            return (start, mondays.date(byAdding: .day, value: 7, to: start)!)
        case .month:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
            return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
        case .year:
            let start = calendar.date(from: calendar.dateComponents([.year], from: today))!
            return (start, calendar.date(byAdding: .year, value: 1, to: start)!)
        }
    }
}
