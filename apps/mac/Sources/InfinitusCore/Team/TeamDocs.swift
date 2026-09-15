import Foundation

/// The plaintext documents a member publishes (spec §7, §4.3). Each
/// carries `schema` so a reader can skip a version it does not know;
/// the envelope's `kind` names which of these is inside. Engine ids and
/// account names are opaque strings (no engine leaks its shape here).
public enum TeamDocs {
    /// `days/<yyyy-mm-dd>.json` — one day's `Stats.Day` (Stats v2 shape).
    public struct DayDoc: Codable, Equatable, Sendable {
        public var schema = 1
        public var day: String
        public var stats: Stats.Day
        public init(day: String, stats: Stats.Day) { self.day = day; self.stats = stats }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var label: String
        public var pct: Int
        public var resetsAt: Int?
        public init(label: String, pct: Int, resetsAt: Int? = nil) { self.label = label; self.pct = pct; self.resetsAt = resetsAt }
    }

    /// One fleet's health as the app sees it: the active account and
    /// its usage windows. The CLI, which has no fleet view, sends none.
    public struct Fleet: Codable, Equatable, Sendable {
        public var engine: String
        public var account: String?
        public var windows: [Window]
        public init(engine: String, account: String?, windows: [Window] = []) {
            self.engine = engine; self.account = account; self.windows = windows
        }
    }

    public struct LiveSession: Codable, Equatable, Sendable {
        public var id: String
        /// Project directory basename, never the path.
        public var project: String
        public var status: String
        public var name: String?
        public init(id: String, project: String, status: String, name: String? = nil) {
            self.id = id; self.project = project; self.status = status; self.name = name
        }
    }

    /// `now.json` — live state; deleted on quit.
    public struct Now: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var sessions: [LiveSession]
        public var fleets: [Fleet]
        public var blockers: [String]
        public var crashesToday: Int
        /// The audience hint a leader copies into the roster (§5).
        public var sharesTo: [String: TeamRoster.ShareTarget]
        public init(at: Int, sessions: [LiveSession], fleets: [Fleet], blockers: [String], crashesToday: Int,
                    sharesTo: [String: TeamRoster.ShareTarget]) {
            self.at = at; self.sessions = sessions; self.fleets = fleets; self.blockers = blockers
            self.crashesToday = crashesToday; self.sharesTo = sharesTo
        }
    }

    /// One session in `sessions/index.json`, summed over its transcript
    /// and its sub-agents' transcripts.
    public struct SessionRow: Codable, Equatable, Sendable {
        public var id: String
        public var project: String
        public var name: String?
        public var engine: String
        public var startedAt = 0
        public var endedAt = 0
        /// Minutes the assistant was working (stretch seconds).
        public var busyMinutes = 0
        /// Minutes a finished turn waited for the person.
        public var waitingMinutes = 0
        /// Minutes per `Stats.Activity` raw value.
        public var activities: [String: Int] = [:]
        public var usd = 0.0
        public var subagents = 0
        public init(id: String, project: String, engine: String) { self.id = id; self.project = project; self.engine = engine }
    }

    public struct SessionsIndex: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var sessions: [SessionRow]
        public var fleets: [Fleet]
        public init(at: Int, sessions: [SessionRow], fleets: [Fleet]) { self.at = at; self.sessions = sessions; self.fleets = fleets }
    }

    /// `crashes.json` — `CrashReport.summary` lines, never the raw report.
    public struct Crashes: Codable, Equatable, Sendable {
        public var schema = 1
        public var crashes: [String]
        public init(crashes: [String]) { self.crashes = crashes }
    }

    /// `roster/aggregates/<period>.json` (spec §8.3): the team picture a
    /// leader publishes to the whole team. Per-member rows only under
    /// `policy.membersSeeEachOther` (§8.4). Days are compacted.
    public struct Aggregates: Codable, Equatable, Sendable {
        public struct Repo: Codable, Equatable, Sendable {
            public var project: String
            public var usd: Double
            public var minutes: Int
            public var members: Int
            public init(project: String, usd: Double, minutes: Int, members: Int) {
                self.project = project; self.usd = usd; self.minutes = minutes; self.members = members
            }
        }
        public struct MemberTotal: Codable, Equatable, Sendable {
            public var kid: String
            public var name: String
            public var role: String
            public var usd: Double
            public var commits: Int
            public var messages: Int
            public var outputTokens: Int
            public var sessions: Int
            public var online: Bool
            public init(kid: String, name: String, role: String, usd: Double, commits: Int, messages: Int, outputTokens: Int, sessions: Int, online: Bool) {
                self.kid = kid; self.name = name; self.role = role; self.usd = usd; self.commits = commits
                self.messages = messages; self.outputTokens = outputTokens; self.sessions = sessions; self.online = online
            }
        }
        public var schema = 1
        public var period: String
        public var from: String
        public var to: String
        public var at: Int
        public var members: Int
        public var total: Stats.Day
        public var previous: Stats.Day
        public var hours: [Int]
        public var repos: [Repo]
        public var byModel: [String: Double]
        public var onNow: [String]
        public var perMember: [MemberTotal]?
        public init(period: String, from: String, to: String, at: Int, members: Int, total: Stats.Day, previous: Stats.Day,
                    hours: [Int], repos: [Repo], byModel: [String: Double], onNow: [String], perMember: [MemberTotal]?) {
            self.period = period; self.from = from; self.to = to; self.at = at; self.members = members; self.total = total
            self.previous = previous; self.hours = hours; self.repos = repos; self.byModel = byModel; self.onNow = onNow; self.perMember = perMember
        }
    }
}
