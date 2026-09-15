import Foundation

/// `roster/team.json` (spec §5): who is in the team and with which keys.
/// Stored as `Signed<TeamRoster>`; `rev` only grows and only a leader of
/// the roster being replaced may sign the next one.
public struct TeamRoster: Codable, Equatable, Sendable {
    /// Where a member's files of one kind go (spec §1 audiences).
    public enum ShareTarget: Codable, Equatable, Sendable {
        /// Nobody: the kind stays on this Mac — nothing is chunked,
        /// sealed, copied to `published/` or re-shared, and `now.json`'s
        /// `sharesTo` hint does not mention it. Offered for every member
        /// kind, with consequences worth saying out loud: `now` off makes
        /// this member look offline to the whole team (there is no live
        /// state to read), and `stats` off drops them out of every leader
        /// aggregate and leaderboard.
        case off
        case leaders, team, members([String])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let kids = try? c.decode([String].self) { self = .members(kids); return }
            switch try c.decode(String.self) {
            case "off": self = .off
            case "leaders": self = .leaders
            case "team": self = .team
            case let other: throw DecodingError.dataCorruptedError(in: c, debugDescription: "share target \(other)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .off: try c.encode("off")
            case .leaders: try c.encode("leaders")
            case .team: try c.encode("team")
            case .members(let kids): try c.encode(kids)
            }
        }
    }

    public struct Member: Codable, Equatable, Sendable {
        public var keys: TeamKeys
        public var name: String
        public var since: Int
        public var founder: Bool
        public var devices: [String]
        /// Hint copied from the member's `now.json`; readers trust envelope
        /// recipients, never this.
        public var sharesTo: [String: ShareTarget]

        public init(keys: TeamKeys, name: String, since: Int, founder: Bool = false,
                    devices: [String] = [], sharesTo: [String: ShareTarget] = [:]) {
            self.keys = keys; self.name = name; self.since = since
            self.founder = founder; self.devices = devices; self.sharesTo = sharesTo
        }
    }

    public struct Removed: Codable, Equatable, Sendable {
        public var kid: String
        public var at: Int
        /// The keys the member had, kept so envelopes sealed AT OR
        /// BEFORE `at` still verify (spec §3: only what is published
        /// after removal is rejected). Nil in rosters written before
        /// this field existed.
        public var keys: TeamKeys?
        public init(kid: String, at: Int, keys: TeamKeys? = nil) { self.kid = kid; self.at = at; self.keys = keys }
    }

    public struct Policy: Codable, Equatable, Sendable {
        /// "open" | "code" | "off"
        public var requests: String
        public var membersSeeEachOther: Bool
        public init(requests: String = "code", membersSeeEachOther: Bool = false) {
            self.requests = requests; self.membersSeeEachOther = membersSeeEachOther
        }
    }

    public var schema: Int
    public var id: String
    public var name: String
    public var createdAt: Int
    public var leaders: [Member]
    public var members: [Member]
    public var removed: [Removed]
    public var policy: Policy
    public var rev: Int

    public static let schemaVersion = 1

    public init(id: String, name: String, createdAt: Int, leaders: [Member], members: [Member] = [],
                removed: [Removed] = [], policy: Policy = Policy(), rev: Int) {
        self.schema = Self.schemaVersion
        self.id = id; self.name = name; self.createdAt = createdAt
        self.leaders = leaders; self.members = members; self.removed = removed
        self.policy = policy; self.rev = rev
    }

    public var everyone: [Member] { leaders + members }

    public func keys(for kid: String) -> TeamKeys? {
        everyone.first { $0.keys.kid == kid }?.keys
    }

    /// The keys `kid` had at `at`: a current member's, or a removed
    /// member's for an envelope sealed at or before the removal instant.
    /// Spec §3 rejects an envelope only when the sender was removed
    /// AFTER its `at`, and §10 promises only that a removed member
    /// cannot read what is published after removal — the same boundary,
    /// read from the other side.
    public func keys(for kid: String, at: Int) -> TeamKeys? {
        if let current = keys(for: kid) { return current }
        guard let gone = removed.first(where: { $0.kid == kid }), at <= gone.at else { return nil }
        return gone.keys
    }

    public func isLeader(_ kid: String) -> Bool {
        leaders.contains { $0.keys.kid == kid }
    }

    /// `.leaders` wraps to the leaders, `.team` to everyone, `.members`
    /// to exactly the named kids (leaders included only when named —
    /// spec §8.4: a teammate's detail is visible only to who they chose).
    /// The sender is added by `Envelope.seal`.
    public func recipients(for target: ShareTarget) -> [TeamKeys] {
        switch target {
        case .off: return []
        case .leaders: return leaders.map(\.keys)
        case .team: return everyone.map(\.keys)
        case .members(let kids): return everyone.filter { kids.contains($0.keys.kid) }.map(\.keys)
        }
    }

    // MARK: acceptance

    public enum RosterError: Error, Equatable {
        case lowerRev, notALeader, badSignature, differentTeam, noLeaders, badSchema
    }

    public enum Acceptance {
        /// `previous` is the roster this client last accepted (nil on the
        /// very first fetch). Anyone holding the store credential can write
        /// `roster/team.json`, so on that first roster listing the trusted
        /// leader is not enough: `trustRoot` — the leader kid the team code
        /// carried — must be the kid that SIGNED it.
        public static func check(_ candidate: Signed<TeamRoster>, previous: Signed<TeamRoster>?,
                                 trustRoot: String? = nil) throws {
            let roster = candidate.doc
            guard roster.schema == TeamRoster.schemaVersion else { throw RosterError.badSchema }
            guard !roster.leaders.isEmpty else { throw RosterError.noLeaders }
            let authority = previous?.doc ?? roster
            if let previous {
                guard roster.id == previous.doc.id else { throw RosterError.differentTeam }
                guard roster.rev > previous.doc.rev else { throw RosterError.lowerRev }
            }
            if previous == nil, let trustRoot, candidate.by != trustRoot { throw RosterError.notALeader }
            guard let signer = authority.leaders.first(where: { $0.keys.kid == candidate.by }) else {
                throw RosterError.notALeader
            }
            do { try candidate.verify(with: signer.keys) } catch { throw RosterError.badSignature }
        }
    }
}
