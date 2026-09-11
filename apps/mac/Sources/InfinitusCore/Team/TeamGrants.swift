import Foundation

/// Spec #220 §2: who may do what to which of MY sessions. Lives on the
/// grantor's machine only (`<teamDir>/grants.json`) and is read at
/// execution time, so revoking is deleting the entry — nothing to
/// propagate, the next command fails `noGrant`. `hints` is the copy
/// that goes into `now.json` so teammates can draw controls; readers
/// treat it as a hint, this file decides.
public struct TeamGrants: Codable, Equatable, Sendable {
    public static let view = "view"
    public static let send = "send"
    public static let approve = "approve"
    public static let mode = "mode"
    public static let resume = "resume"
    public static let key = "key"
    /// `view` reads the live tail; the rest are `SessionInput.Request.Kind`
    /// names — a grant that lists `send` only cannot answer a prompt.
    public static let driveCapabilities = [send, approve, mode, resume, key]
    public static let capabilities = [view] + driveCapabilities

    /// `"all"` or a list of Claude Code session ids (never pids: the id
    /// is stable for a transcript, the pid is resolved at execution).
    public enum Sessions: Codable, Equatable, Sendable {
        case all
        case some([String])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let word = try? c.decode(String.self), word == "all" { self = .all; return }
            self = .some(try c.decode([String].self))
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .all: try c.encode("all")
            case .some(let ids): try c.encode(ids)
            }
        }
        func contains(_ id: String) -> Bool {
            switch self {
            case .all: return true
            case .some(let ids): return ids.contains(id)
            }
        }
    }

    public struct Grant: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var audience: TeamRoster.ShareTarget
        public var sessions: Sessions
        public var capabilities: Set<String>
        public var since: Int
        public init(id: String, audience: TeamRoster.ShareTarget, sessions: Sessions, capabilities: Set<String>, since: Int) {
            self.id = id; self.audience = audience; self.sessions = sessions; self.capabilities = capabilities; self.since = since
        }
    }

    public var schema = 1
    public var grants: [Grant] = []

    public init() {}

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("grants.json") }

    /// Missing or unreadable is "no grants" — the safe reading (#220: default off).
    public static func load(teamDir: URL) -> TeamGrants {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamGrants.self, from: $0) }
            ?? TeamGrants()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }

    @discardableResult
    public mutating func add(audience: TeamRoster.ShareTarget, sessions: Sessions, capabilities: Set<String>,
                             now: Int = Int(Date().timeIntervalSince1970)) -> Grant {
        let id = "g-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let grant = Grant(id: id, audience: audience, sessions: sessions,
                          capabilities: capabilities.intersection(Self.capabilities), since: now)
        grants.append(grant)
        return grant
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = grants.count
        grants.removeAll { $0.id == id }
        return grants.count != before
    }

    /// The first grant that lets `kid` do `capability` to `session`, or nil.
    /// Audience resolves through the roster AS IT IS NOW: "leaders"
    /// follows promotions, a removed kid never matches, and a named kid
    /// must still be in the roster (spec §2).
    public func permits(kid: String, session: String, capability: String, roster: TeamRoster) -> Grant? {
        grants.first { grant in
            grant.capabilities.contains(capability)
                && grant.sessions.contains(session)
                && roster.recipients(for: grant.audience).contains { $0.kid == kid }
        }
    }

    /// The `now.json` copy: no ids, capabilities sorted, `all` as nil.
    public var hints: [TeamDocs.GrantHint] {
        grants.map { grant in
            let sessions: [String]?
            switch grant.sessions {
            case .all: sessions = nil
            case .some(let ids): sessions = ids
            }
            return TeamDocs.GrantHint(audience: grant.audience, sessions: sessions, capabilities: grant.capabilities.sorted())
        }
    }
}
