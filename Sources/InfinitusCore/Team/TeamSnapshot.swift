import Foundation

/// One team as the Team pane, the control socket (`team-status`) and the
/// phone (`MirrorSnapshot.team`, plan 8) see it: roster rows with what
/// each member last published and today's effort, pending requests, and
/// the loop's last outcome. Built on the Mac from `TeamStatus`, the
/// accepted roster, a `TeamReader` and the leader's request list.
public struct TeamSnapshot: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable, Identifiable {
        public var kid: String
        public var name: String
        /// "leader" | "member"
        public var role: String
        public var isMe: Bool
        public var founder: Bool
        /// Unix seconds of the roster approval (team creation for the
        /// founder). Optional so a phone decodes an older Mac's snapshot.
        public var since: Int?
        /// Unix seconds of the newest envelope readable from this member.
        public var lastPublished: Int?
        /// Kinds readable from this member, sorted.
        public var kinds: [String]
        public var sessionsNow: Int
        public var blockers: [String]
        public var crashes: Int
        public var todayUSD: Double
        public var todayMessages: Int
        public var todayCommits: Int
        /// The member's fleets as last published (#221); additive, so an
        /// older phone decodes the row without it.
        public var fleet: TeamDocs.FleetDoc?
        /// What this member lets ME do to their sessions (#220), sorted;
        /// nil when nothing. Additive, so an older phone decodes without it.
        public var controls: [String]?
        public var id: String { kid }

        public init(kid: String, name: String, role: String, isMe: Bool, founder: Bool = false, since: Int? = nil,
                    lastPublished: Int? = nil, kinds: [String] = [], sessionsNow: Int = 0, blockers: [String] = [],
                    crashes: Int = 0, todayUSD: Double = 0, todayMessages: Int = 0, todayCommits: Int = 0,
                    fleet: TeamDocs.FleetDoc? = nil) {
            self.kid = kid; self.name = name; self.role = role; self.isMe = isMe; self.founder = founder; self.since = since
            self.lastPublished = lastPublished; self.kinds = kinds; self.sessionsNow = sessionsNow
            self.blockers = blockers; self.crashes = crashes; self.todayUSD = todayUSD
            self.todayMessages = todayMessages; self.todayCommits = todayCommits; self.fleet = fleet
        }
    }

    public struct Request: Codable, Equatable, Sendable, Identifiable {
        public var kid: String
        public var name: String
        public var platform: String
        public var devices: [String]
        public var at: Int
        public var id: String { kid }
        public init(kid: String, name: String, platform: String, devices: [String], at: Int) {
            self.kid = kid; self.name = name; self.platform = platform; self.devices = devices; self.at = at
        }
    }

    public var id: String
    public var name: String
    /// Always the masked form (`maskRemote`).
    public var remote: String
    /// My kid.
    public var kid: String
    /// "leader" | "member" | "pending"
    public var role: String
    public var rev: Int?
    public var members: [Member]
    public var requests: [Request]
    public var lastFetch: Int?
    public var lastPublish: Int?
    public var lastError: String?

    /// The union of every hint whose audience names `me`, sorted; nil
    /// when no hint does (the row reads as "cannot drive").
    public static func controls(hints: [TeamDocs.GrantHint]?, roster: TeamRoster?, me: String) -> [String]? {
        guard let hints, let roster else { return nil }
        var out = Set<String>()
        for hint in hints where roster.recipients(for: hint.audience).contains(where: { $0.kid == me }) {
            out.formUnion(hint.capabilities)
        }
        return out.isEmpty ? nil : out.sorted()
    }

    public static func make(status: TeamStatus, roster: TeamRoster?, reader: TeamReader?, requests: [Signed<TeamRequest>],
                            today: String, lastFetch: Int?, lastPublish: Int?, lastError: String?) -> TeamSnapshot {
        func row(_ m: TeamRoster.Member, role: String) -> Member {
            var out = Member(kid: m.keys.kid, name: m.name, role: role, isMe: m.keys.kid == status.kid, founder: m.founder, since: m.since)
            if let r = reader?.members[m.keys.kid] {
                out.lastPublished = r.lastPublished
                out.kinds = r.kinds.sorted()
                out.sessionsNow = r.now?.sessions.count ?? 0
                out.blockers = r.now?.blockers ?? []
                out.crashes = r.crashes.count
                out.fleet = r.fleet
                out.controls = TeamSnapshot.controls(hints: r.now?.grantsTo, roster: roster, me: status.kid)
                if let day = r.days[today] {
                    out.todayUSD = day.usd
                    out.todayMessages = day.messages
                    out.todayCommits = day.commits
                }
            }
            return out
        }
        func sorted(_ rows: [Member]) -> [Member] {
            rows.sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }
        }
        let members = sorted((roster?.leaders ?? []).map { row($0, role: "leader") })
            + sorted((roster?.members ?? []).map { row($0, role: "member") })
        var pending: [Request] = requests.map { signed in
            let doc = signed.doc
            return Request(kid: doc.keys.kid, name: doc.name, platform: doc.platform, devices: doc.devices, at: doc.at)
        }
        pending.sort { $0.at == $1.at ? $0.kid < $1.kid : $0.at < $1.at }
        return TeamSnapshot(id: status.id, name: status.name, remote: maskRemote(status.remote), kid: status.kid,
                            role: status.role, rev: status.rev, members: members, requests: pending,
                            lastFetch: lastFetch, lastPublish: lastPublish, lastError: lastError)
    }

    /// The remote without its userinfo (`https://user:token@host/…` →
    /// `https://host/…`). Scp-style remotes (`git@host:path`) fail to parse
    /// as a URL and are returned unchanged — the leading `git@` there is a
    /// fixed protocol user, not a secret. Any other remote that parses with
    /// credentials but can't be re-serialized once they're cleared is
    /// masked outright rather than risk returning the credentialed string.
    public static func maskRemote(_ remote: String) -> String {
        guard var parts = URLComponents(string: remote), parts.user != nil || parts.password != nil else { return remote }
        parts.user = nil
        parts.password = nil
        return parts.string ?? "<remote hidden>"
    }
}
