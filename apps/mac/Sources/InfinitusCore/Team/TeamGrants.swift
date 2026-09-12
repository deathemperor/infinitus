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
    /// Phase 2 (#220, design 2026-09-12): each of these runs one of the
    /// grantor's own control verbs in-process, never a second path.
    public static let stop = "stop"
    public static let resumePast = "resume-past"
    public static let delete = "delete"
    public static let swap = "swap"
    public static let hold = "hold"
    public static let kill = "kill"
    public static let reclaim = "reclaim"
    public static let lifecycleCapabilities = [stop, resumePast, delete]
    public static let accountCapabilities = [swap, hold]
    public static let machineCapabilities = [kill, reclaim]
    public static let capabilities = [view] + driveCapabilities + lifecycleCapabilities + accountCapabilities + machineCapabilities
    /// Address the Mac, not a session: `Command.session` is
    /// `TeamControl.machineSession` and the grant's `sessions` is not consulted.
    public static let machineScoped: Set<String> = [swap, hold, kill, reclaim]
    /// Name a session that need not be live (a past transcript).
    public static let pastScoped: Set<String> = [resumePast, delete]
    /// Always ask the grantor, whatever the grant says: `add` drops them
    /// from `preauthorized`, and a hand-edited file is read the same way.
    public static let neverPreauthorized: Set<String> = [delete, kill, reclaim]

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
        /// Capabilities that run without asking. `view` and the drive set
        /// never ask and are not listed; `neverPreauthorized` cannot be.
        /// Absent in a Phase 1 file, which reads as "everything else asks".
        public var preauthorized: Set<String>
        /// Unix seconds; nil = until revoked.
        public var expires: Int?
        public init(id: String, audience: TeamRoster.ShareTarget, sessions: Sessions, capabilities: Set<String>, since: Int,
                    preauthorized: Set<String> = [], expires: Int? = nil) {
            self.id = id; self.audience = audience; self.sessions = sessions; self.capabilities = capabilities; self.since = since
            self.preauthorized = preauthorized.subtracting(TeamGrants.neverPreauthorized); self.expires = expires
        }

        enum CodingKeys: String, CodingKey { case id, audience, sessions, capabilities, since, preauthorized, expires }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id),
                      audience: try c.decode(TeamRoster.ShareTarget.self, forKey: .audience),
                      sessions: try c.decode(Sessions.self, forKey: .sessions),
                      capabilities: try c.decode(Set<String>.self, forKey: .capabilities),
                      since: try c.decode(Int.self, forKey: .since),
                      preauthorized: try c.decodeIfPresent(Set<String>.self, forKey: .preauthorized) ?? [],
                      expires: try c.decodeIfPresent(Int.self, forKey: .expires))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(audience, forKey: .audience)
            try c.encode(sessions, forKey: .sessions)
            try c.encode(capabilities.sorted(), forKey: .capabilities)
            try c.encode(since, forKey: .since)
            // Absent, not empty: a Phase 1 grant re-saved is byte-identical.
            if !preauthorized.isEmpty { try c.encode(preauthorized.sorted(), forKey: .preauthorized) }
            try c.encodeIfPresent(expires, forKey: .expires)
        }

        /// The grantor is asked before this capability runs.
        public func requiresApproval(_ capability: String) -> Bool {
            capability != TeamGrants.view && !TeamGrants.driveCapabilities.contains(capability) && !preauthorized.contains(capability)
        }

        func alive(at now: Int) -> Bool { expires.map { $0 > now } ?? true }
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
                             preauthorized: Set<String> = [], expires: Int? = nil,
                             now: Int = Int(Date().timeIntervalSince1970)) -> Grant {
        let id = "g-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let granted = capabilities.intersection(Self.capabilities)
        let grant = Grant(id: id, audience: audience, sessions: sessions, capabilities: granted, since: now,
                          preauthorized: preauthorized.intersection(granted)
                              .subtracting(Self.driveCapabilities).subtracting([Self.view]),
                          expires: expires)
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
    /// must still be in the roster (spec §2). A `machineScoped`
    /// capability addresses the Mac, so the grant's sessions are not
    /// consulted for it; an expired grant permits nothing.
    public func permits(kid: String, session: String, capability: String, roster: TeamRoster,
                        now: Int = Int(Date().timeIntervalSince1970)) -> Grant? {
        grants.first { grant in
            grant.capabilities.contains(capability)
                && grant.alive(at: now)
                && (Self.machineScoped.contains(capability) || grant.sessions.contains(session))
                && roster.recipients(for: grant.audience).contains { $0.kid == kid }
        }
    }

    /// The `now.json` copy: no ids, capabilities sorted, `all` as nil,
    /// `approval` the capabilities that ask (absent when none do).
    public var hints: [TeamDocs.GrantHint] {
        grants.map { grant in
            let sessions: [String]?
            switch grant.sessions {
            case .all: sessions = nil
            case .some(let ids): sessions = ids
            }
            let asks = grant.capabilities.filter(grant.requiresApproval).sorted()
            return TeamDocs.GrantHint(audience: grant.audience, sessions: sessions, capabilities: grant.capabilities.sorted(),
                                      approval: asks.isEmpty ? nil : asks, expires: grant.expires)
        }
    }
}
