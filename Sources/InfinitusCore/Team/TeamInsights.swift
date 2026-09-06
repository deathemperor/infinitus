import Foundation

/// Spec §8.2–8.4, computed from a `TeamReader` — pure, so the pane, the
/// phone (via aggregates) and the CLI agree. Money is the app's own
/// estimate (usage-cost caveat), never billing truth.
public enum TeamInsights {
    // MARK: comparison

    public struct MemberRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        public var role: String
        public var summary: Stats.Summary
        public var online: Bool
        public var sessionsNow: Int
        public var blockers: [String]
        public var crashes: Int
        public var lastPublished: Int?
        public var since: Int?
        public var removedAt: Int?
    }

    /// One row per roster member (and per removed sender still readable),
    /// leaders first, then by name.
    public static func comparison(_ reader: TeamReader, period: Stats.Period, now: Date = Date(),
                                  calendar: Calendar = .current) -> [MemberRow] {
        reader.members.values.map { m in
            MemberRow(kid: m.kid, name: m.name, role: m.role,
                      summary: Stats.fold(days: m.days, period: period, now: now, calendar: calendar),
                      online: isOn(m, now: now), sessionsNow: m.now?.sessions.count ?? 0,
                      blockers: m.now?.blockers ?? [], crashes: m.crashes.count, lastPublished: m.lastPublished,
                      since: m.since, removedAt: m.removedAt)
        }
        .sorted { x, y in
            (x.role == "leader" ? 0 : 1, x.name, x.kid) < (y.role == "leader" ? 0 : 1, y.name, y.kid)
        }
    }

    // MARK: who is on

    /// A `now.json` older than this is stale: the member is off.
    public static let onlineWindow = 15 * 60

    public static func isOn(_ m: TeamReader.Member, now: Date) -> Bool {
        guard let n = m.now else { return false }
        return Int(now.timeIntervalSince1970) - n.at <= onlineWindow && !n.sessions.isEmpty
    }

    public static func whoIsOn(_ reader: TeamReader, now: Date = Date()) -> [TeamReader.Member] {
        reader.members.values.filter { isOn($0, now: now) }.sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }
    }

    // MARK: leaderboards

    public enum Metric: String, CaseIterable, Codable, Sendable {
        case usd, outputTokens, commits, prsMerged, linesAdded, messages, toolCalls, waitingMinutes, sessions

        public var title: String {
            switch self {
            case .usd: "Spend (est.)"
            case .outputTokens: "Output tokens"
            case .commits: "Commits"
            case .prsMerged: "PRs merged"
            case .linesAdded: "Lines added"
            case .messages: "Messages"
            case .toolCalls: "Tool calls"
            case .waitingMinutes: "Minutes waiting"
            case .sessions: "Sessions"
            }
        }

        public func value(_ d: Stats.Day) -> Double {
            switch self {
            case .usd: d.usd
            case .outputTokens: Double(d.outputTokens)
            case .commits: Double(d.commits)
            case .prsMerged: Double(d.prsMerged)
            case .linesAdded: Double(d.linesAdded)
            case .messages: Double(d.messages)
            case .toolCalls: Double(d.totalToolCalls)
            case .waitingMinutes: d.waitingSeconds / 60
            case .sessions: Double(d.sessionCount)
            }
        }
    }

    public struct LeaderboardRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        public var value: Double
    }

    public static func leaderboard(_ rows: [MemberRow], metric: Metric) -> [LeaderboardRow] {
        rows.map { LeaderboardRow(kid: $0.kid, name: $0.name, value: metric.value($0.summary.total)) }
            .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
    }

    // MARK: repos

    public struct RepoRow: Equatable, Sendable {
        public struct Share: Equatable, Sendable {
            public var kid: String
            public var name: String
            public var usd: Double
            public var minutes: Int
        }
        public var project: String
        public var usd: Double
        public var minutes: Int
        /// By effort, descending.
        public var members: [Share]
    }

    /// Who works where, from every member's session index: sessions that
    /// started inside the period, grouped by project, by effort.
    public static func repos(_ reader: TeamReader, period: Stats.Period, now: Date = Date(),
                             calendar: Calendar = .current) -> [RepoRow] {
        let start = Int(Stats.range(period, now: now, calendar: calendar).0.timeIntervalSince1970)
        var byProject: [String: [String: RepoRow.Share]] = [:]
        for m in reader.members.values {
            for s in m.sessions where s.startedAt >= start {
                var share = byProject[s.project, default: [:]][m.kid] ?? RepoRow.Share(kid: m.kid, name: m.name, usd: 0, minutes: 0)
                share.usd += s.usd
                share.minutes += s.busyMinutes
                byProject[s.project, default: [:]][m.kid] = share
            }
        }
        return byProject.map { project, shares in
            let members = shares.values.sorted { $0.usd == $1.usd ? $0.name < $1.name : $0.usd > $1.usd }
            return RepoRow(project: project, usd: members.reduce(0) { $0 + $1.usd }, minutes: members.reduce(0) { $0 + $1.minutes }, members: members)
        }
        .sorted { $0.usd == $1.usd ? $0.project < $1.project : $0.usd > $1.usd }
    }

    // MARK: blockers

    public struct Blocker: Equatable, Sendable {
        public var kid: String
        public var name: String
        /// "aws" | "limit" | "waiting" | "crash" | "other"
        public var kind: String
        public var text: String
    }

    /// Every fresh member's blockers (spec §8.3): what its pop-out shows,
    /// sessions waiting on a prompt, crashes today. Stale members are
    /// skipped so an old `now.json` cannot keep a blocker alive.
    public static func blockers(_ reader: TeamReader, now: Date = Date()) -> [Blocker] {
        var out: [Blocker] = []
        for m in reader.members.values.sorted(by: { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }) {
            guard let n = m.now, Int(now.timeIntervalSince1970) - n.at <= onlineWindow else { continue }
            for text in n.blockers {
                let kind = text.hasPrefix("AWS") ? "aws" : text.contains("limited") ? "limit" : "other"
                out.append(Blocker(kid: m.kid, name: m.name, kind: kind, text: text))
            }
            for s in n.sessions where s.status == "waiting" {
                out.append(Blocker(kid: m.kid, name: m.name, kind: "waiting", text: "\(s.name ?? s.project) is waiting for you"))
            }
            if n.crashesToday > 0 {
                out.append(Blocker(kid: m.kid, name: m.name, kind: "crash", text: "\(n.crashesToday) crash\(n.crashesToday == 1 ? "" : "es") today"))
            }
        }
        return out
    }

    // MARK: headroom

    /// One fleet of one fresh member on the leader's headroom board
    /// (#221): the active account's lowest headroom, and how many other
    /// accounts could take over.
    public struct Headroom: Equatable, Sendable {
        public var kid: String
        public var name: String
        public var engine: String
        public var active: String?
        /// 100 − the active account's highest window pct; nil without one.
        public var headroom: Int?
        /// Accounts that are `ok` and not active.
        public var spare: Int
        public var dead: Int
    }

    /// Every fresh member's fleets, the one nearest running dry first. A
    /// `fleet.json` older than `onlineWindow` is skipped like a stale `now`.
    public static func headroom(_ reader: TeamReader, now: Date = Date()) -> [Headroom] {
        var out: [Headroom] = []
        for m in reader.members.values {
            guard let f = m.fleet, Int(now.timeIntervalSince1970) - f.at <= onlineWindow else { continue }
            for fleet in f.fleets {
                let active = fleet.accounts.first { $0.active }
                let used = active.map { ($0.windows + $0.models).map(\.pct).max() ?? 0 }
                out.append(Headroom(kid: m.kid, name: m.name, engine: fleet.engine, active: fleet.active,
                                    headroom: used.map { max(0, 100 - $0) },
                                    spare: fleet.accounts.filter { !$0.active && $0.status == TeamDocs.FleetDoc.ok }.count,
                                    dead: fleet.accounts.filter { $0.status == TeamDocs.FleetDoc.dead }.count))
            }
        }
        return out.sorted { x, y in
            (x.headroom ?? 101, x.name, x.kid, x.engine) < (y.headroom ?? 101, y.name, y.kid, y.engine)
        }
    }

    // MARK: cost, hours

    public struct Cost: Equatable, Sendable {
        public struct MemberCost: Equatable, Sendable {
            public var kid: String
            public var name: String
            public var usd: Double
        }
        public var total: Double
        /// Descending, then by name.
        public var byMember: [MemberCost]
        public var byModel: [String: Double]
        public var byRepo: [String: Double]
    }

    public static func cost(_ rows: [MemberRow], repos: [RepoRow]) -> Cost {
        var byModel: [String: Double] = [:]
        for r in rows { for (model, tally) in r.summary.total.byModel { byModel[model, default: 0] += tally.usd } }
        let byMember = rows.map { (r: MemberRow) -> Cost.MemberCost in Cost.MemberCost(kid: r.kid, name: r.name, usd: r.summary.total.usd) }
            .sorted { (x: Cost.MemberCost, y: Cost.MemberCost) -> Bool in x.usd == y.usd ? x.name < y.name : x.usd > y.usd }
        return Cost(total: rows.reduce(0) { $0 + $1.summary.total.usd }, byMember: byMember, byModel: byModel,
                    byRepo: Dictionary(repos.map { ($0.project, $0.usd) }, uniquingKeysWith: +))
    }

    /// The team's 168-slot heatmap (weekday × hour) for the rows' period.
    public static func hours(_ rows: [MemberRow]) -> [Int] {
        var out = Array(repeating: 0, count: 168)
        for r in rows { for (i, v) in r.summary.total.hours.prefix(168).enumerated() { out[i] += v } }
        return out
    }

    // MARK: members' view (§8.4)

    public struct ShareRow: Equatable, Sendable {
        public var kid: String
        public var name: String
        /// Kinds this teammate's audiences include me in, sorted.
        public var kinds: [String]
    }

    /// What each teammate shares TO `me`: the kinds of the envelopes `me`
    /// is a recipient of (`TeamReader.Member.kinds`, from the client's
    /// audience-filtered headers) — never the `now.sharesTo` hint, which
    /// readers must not rely on (spec §5). A teammate with nothing
    /// readable shows an empty row. Leaders are never listed as a
    /// teammate here — this is the members' view of each other (spec
    /// §8.4), not the leaders' comparison.
    public static func sharedWithMe(_ reader: TeamReader, roster: TeamRoster, me: String) -> [ShareRow] {
        roster.members.filter { $0.keys.kid != me }.map { member in
            ShareRow(kid: member.keys.kid, name: member.name, kinds: (reader.members[member.keys.kid]?.kinds ?? []).sorted())
        }
        .sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }
    }

    // MARK: aggregates (§8.3)

    public static func aggregates(_ reader: TeamReader, roster: TeamRoster, period: Stats.Period, now: Date = Date(),
                                  calendar: Calendar = .current) -> TeamDocs.Aggregates {
        let rows = comparison(reader, period: period, now: now, calendar: calendar)
        let team = Stats.fold(days: reader.teamDays(), period: period, now: now, calendar: calendar)
        let repos = repos(reader, period: period, now: now, calendar: calendar)
        let cost = cost(rows, repos: repos)
        var total = team.total.compacted(); total.hours = hours(rows)
        // Removed senders still fold (pre-removal history) but are never
        // republished to the team.
        let kids = Set(roster.everyone.map(\.keys.kid))
        let perMember: [TeamDocs.Aggregates.MemberTotal]? = roster.policy.membersSeeEachOther ? rows.filter { kids.contains($0.kid) }.map {
            TeamDocs.Aggregates.MemberTotal(kid: $0.kid, name: $0.name, role: $0.role, usd: $0.summary.total.usd,
                                            commits: $0.summary.total.commits, messages: $0.summary.total.messages,
                                            outputTokens: $0.summary.total.outputTokens, sessions: $0.summary.total.sessionCount, online: $0.online)
        } : nil
        return TeamDocs.Aggregates(period: period.rawValue, from: team.from, to: team.to, at: Int(now.timeIntervalSince1970),
                                   members: roster.everyone.count, total: total, previous: team.previous.compacted(),
                                   hours: hours(rows), repos: repos.map { TeamDocs.Aggregates.Repo(project: $0.project, usd: $0.usd, minutes: $0.minutes, members: $0.members.count) },
                                   byModel: cost.byModel, onNow: whoIsOn(reader, now: now).map(\.name), perMember: perMember)
    }
}
