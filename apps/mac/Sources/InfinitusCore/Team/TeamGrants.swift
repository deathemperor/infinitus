import Foundation

/// Spec §8: who may do what to which of MY threads. Lives on the
/// grantor's machine only (`<teamDir>/grants.json`) and is read at
/// execution time, so revoking is deleting the entry — nothing to
/// propagate, the next command fails `noGrant`. `hints` is the copy
/// that goes into `now.json` so teammates can draw controls; readers
/// treat it as a hint, this file decides.
public struct TeamGrants: Codable, Equatable, Sendable {
    /// Read a thread's last turn through the grantor, redacted.
    public static let view = "view"
    /// Type a prompt into a thread (a steer while a turn runs).
    public static let send = "send"
    /// Interrupt a thread's running turn.
    public static let interrupt = "interrupt"
    /// Start a thread in a named project on the grantor's desktop.
    public static let new = "new"
    /// Never ask: reading a thread and typing into it are what a grant is for.
    public static let driveCapabilities = [view, send]
    /// Ask the grantor at execution unless the grant pre-authorises them.
    public static let askingCapabilities = [interrupt, new]
    public static let capabilities = driveCapabilities + askingCapabilities
    /// Address the Mac, not a thread: `Command.thread` is
    /// `TeamControl.machineThread`, `Command.project` names the project,
    /// and the grant's `threads` is not consulted.
    public static let machineScoped: Set<String> = [new]

    /// `"all"` or a list of desktop thread ids.
    public enum Threads: Codable, Equatable, Sendable {
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
        public var threads: Threads
        public var capabilities: Set<String>
        public var since: Int
        /// Capabilities that run without asking. The drive set never asks
        /// and is not listed. Absent in the file reads as "the rest asks".
        public var preauthorized: Set<String>
        /// Unix seconds; nil = until revoked.
        public var expires: Int?
        public init(id: String, audience: TeamRoster.ShareTarget, threads: Threads, capabilities: Set<String>, since: Int,
                    preauthorized: Set<String> = [], expires: Int? = nil) {
            self.id = id; self.audience = audience; self.threads = threads; self.capabilities = capabilities; self.since = since
            self.preauthorized = preauthorized; self.expires = expires
        }

        enum CodingKeys: String, CodingKey { case id, audience, threads, capabilities, since, preauthorized, expires }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id),
                      audience: try c.decode(TeamRoster.ShareTarget.self, forKey: .audience),
                      threads: try c.decode(Threads.self, forKey: .threads),
                      capabilities: try c.decode(Set<String>.self, forKey: .capabilities),
                      since: try c.decode(Int.self, forKey: .since),
                      preauthorized: try c.decodeIfPresent(Set<String>.self, forKey: .preauthorized) ?? [],
                      expires: try c.decodeIfPresent(Int.self, forKey: .expires))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(audience, forKey: .audience)
            try c.encode(threads, forKey: .threads)
            try c.encode(capabilities.sorted(), forKey: .capabilities)
            try c.encode(since, forKey: .since)
            // Absent, not empty: a grant that asks for everything re-saves byte-identical.
            if !preauthorized.isEmpty { try c.encode(preauthorized.sorted(), forKey: .preauthorized) }
            try c.encodeIfPresent(expires, forKey: .expires)
        }

        /// The grantor is asked before this capability runs.
        public func requiresApproval(_ capability: String) -> Bool {
            !TeamGrants.driveCapabilities.contains(capability) && !preauthorized.contains(capability)
        }

        func alive(at now: Int) -> Bool { expires.map { $0 > now } ?? true }
    }

    public var schema = 1
    public var grants: [Grant] = []

    public init() {}

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("grants.json") }

    /// Missing or unreadable is "no grants" — the safe reading (default off).
    public static func load(teamDir: URL) -> TeamGrants {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamGrants.self, from: $0) }
            ?? TeamGrants()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
    }

    @discardableResult
    public mutating func add(audience: TeamRoster.ShareTarget, threads: Threads, capabilities: Set<String>,
                             preauthorized: Set<String> = [], expires: Int? = nil,
                             now: Int = Int(Date().timeIntervalSince1970)) -> Grant {
        let id = "g-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let granted = capabilities.intersection(Self.capabilities)
        let grant = Grant(id: id, audience: audience, threads: threads, capabilities: granted, since: now,
                          preauthorized: preauthorized.intersection(granted).subtracting(Self.driveCapabilities),
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

    /// The first grant that lets `kid` do `capability` to `thread`, or nil.
    /// Audience resolves through the roster AS IT IS NOW: "leaders"
    /// follows promotions, a removed kid never matches, and a named kid
    /// must still be in the roster (spec §2). A `machineScoped`
    /// capability addresses the Mac, so the grant's threads are not
    /// consulted for it; an expired grant permits nothing.
    public func permits(kid: String, thread: String, capability: String, roster: TeamRoster,
                        now: Int = Int(Date().timeIntervalSince1970)) -> Grant? {
        grants.first { grant in
            grant.capabilities.contains(capability)
                && grant.alive(at: now)
                && (Self.machineScoped.contains(capability) || grant.threads.contains(thread))
                && roster.recipients(for: grant.audience).contains { $0.kid == kid }
        }
    }

    /// The `now.json` copy: no ids, capabilities sorted, `all` as nil,
    /// `approval` the capabilities that ask (absent when none do).
    public var hints: [TeamDocs.GrantHint] {
        grants.map { grant in
            let threads: [String]?
            switch grant.threads {
            case .all: threads = nil
            case .some(let ids): threads = ids
            }
            let asks = grant.capabilities.filter(grant.requiresApproval).sorted()
            return TeamDocs.GrantHint(audience: grant.audience, threads: threads, capabilities: grant.capabilities.sorted(),
                                      approval: asks.isEmpty ? nil : asks, expires: grant.expires)
        }
    }
}
