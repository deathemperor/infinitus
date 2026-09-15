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

    /// One of `now.json`'s `live` rows: a thread whose session is
    /// starting or running on Infinitus desktop.
    public struct LiveThread: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// Project directory basename, never the path.
        public var project: String
        public var startedAt: Int?
        /// The turn's current line ("Waiting for approval", a tool name).
        public var activityLine: String?
        public init(id: String, title: String, project: String, startedAt: Int? = nil, activityLine: String? = nil) {
            self.id = id; self.title = title; self.project = project; self.startedAt = startedAt; self.activityLine = activityLine
        }
    }

    /// `now.json` — live state; deleted on quit.
    public struct Now: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        /// The Mac's name, as the roster shows it.
        public var machine: String
        public var live: [LiveThread]
        public var fleets: [Fleet]
        public var blockers: [String]
        public var crashesToday: Int
        /// The audience hint a leader copies into the roster (§5).
        public var sharesTo: [String: TeamRoster.ShareTarget]
        /// Whether Infinitus desktop answered when this was written: false
        /// means `live` and the threads index say nothing about the Mac.
        public var desktop: Bool
        public init(at: Int, machine: String, live: [LiveThread], fleets: [Fleet], blockers: [String], crashesToday: Int,
                    sharesTo: [String: TeamRoster.ShareTarget], desktop: Bool) {
            self.at = at; self.machine = machine; self.live = live; self.fleets = fleets; self.blockers = blockers
            self.crashesToday = crashesToday; self.sharesTo = sharesTo; self.desktop = desktop
        }
    }

    /// One thread in `threads/index.json` (spec §4): what Infinitus
    /// desktop's shell says about it, never the transcript.
    public struct ThreadRow: Codable, Equatable, Sendable {
        public struct Usage: Codable, Equatable, Sendable {
            public var inputTokens: Int
            public var outputTokens: Int
            public var costUsd: Double?
            public var models: [String]
            public init(inputTokens: Int, outputTokens: Int, costUsd: Double?, models: [String]) {
                self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costUsd = costUsd; self.models = models
            }
        }
        public var id: String
        public var title: String
        /// Project directory basename, never the path.
        public var project: String
        /// idle | starting | running | failed | archived
        public var status: String
        public var createdAt: Int
        public var updatedAt: Int
        public var turns: Int
        public var usage: Usage?
        public init(id: String, title: String, project: String, status: String, createdAt: Int, updatedAt: Int, turns: Int, usage: Usage? = nil) {
            self.id = id; self.title = title; self.project = project; self.status = status
            self.createdAt = createdAt; self.updatedAt = updatedAt; self.turns = turns; self.usage = usage
        }
    }

    public struct ThreadsIndex: Codable, Equatable, Sendable {
        public var schema = 1
        public var at: Int
        public var threads: [ThreadRow]
        public var fleets: [Fleet]
        public init(at: Int, threads: [ThreadRow], fleets: [Fleet]) { self.at = at; self.threads = threads; self.fleets = fleets }
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
            public var turns: Int
            public var members: Int
            public init(project: String, usd: Double, turns: Int, members: Int) {
                self.project = project; self.usd = usd; self.turns = turns; self.members = members
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
