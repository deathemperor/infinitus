import Foundation

/// Delegated session control (#220 §3–§4): the envelopes a driver and a
/// grantor exchange, and the pipeline the grantor runs before anything
/// reaches a session. Pure: every dependency with IO is injected
/// through `Endpoint`, so the whole thing is tested without a Mac, a
/// store or git, and mounts on the Linux tray unchanged.
public enum TeamControl {
    public static let defaultTTL = 120
    public static let maxTTL = 600
    /// The store lane's TTL: the grantor's fetch cadence (≤ 5 min) must not expire it.
    public static let storeTTL = 600
    /// A command "from the future" beyond this is a bad clock or a forgery.
    public static let maxFutureSkew = 300

    /// One action on one session, sealed by the driver to the grantor.
    public struct Command: Codable, Equatable, Sendable {
        public var schema = 1
        /// Minted by the driver; a store path segment, so `[a-z0-9-]{8,64}`.
        public var id: String
        /// The grantor's kid — sealed AND addressed, so a command sealed to
        /// me but naming someone else is refused.
        public var to: String
        public var session: String
        /// A `TeamGrants.driveCapabilities` member (= `SessionInput.Request.Kind`).
        public var action: String
        public var text: String?
        public var at: Int
        public var ttl: Int
        public init(id: String, to: String, session: String, action: String, text: String?, at: Int, ttl: Int = TeamControl.defaultTTL) {
            self.id = id; self.to = to; self.session = session; self.action = action; self.text = text; self.at = at; self.ttl = ttl
        }
    }

    /// The grantor's answer, sealed to the driver.
    public struct Ack: Codable, Equatable, Sendable {
        public var schema = 1
        public var id: String
        public var outcome: String
        public var detail: String?
        public var at: Int
        public init(id: String, outcome: String, detail: String?, at: Int) {
            self.id = id; self.outcome = outcome; self.detail = detail; self.at = at
        }
    }

    /// A leader's minted tunnel for a member (§5.4), sealed to the member.
    public struct Hostname: Codable, Equatable, Sendable {
        public var schema = 1
        public var hostname: String
        public var token: String
        public var at: Int
        public init(hostname: String, token: String, at: Int) { self.hostname = hostname; self.token = token; self.at = at }
    }

    /// `Ack.outcome`: `SessionInput.Reply.outcome` as it is, plus the refusals.
    public enum Outcome {
        public static let delivered = "delivered"
        public static let running = "running"
        public static let captured = "captured"
        public static let noSurface = "noSurface"
        public static let noChannel = "noChannel"
        public static let rejected = "rejected"
        public static let noGrant = "noGrant"
        public static let notLive = "notLive"
        public static let expired = "expired"
        public static let replayed = "replayed"
        public static let unknownSender = "unknownSender"
        public static let badRequest = "badRequest"
        public static let rateLimited = "rateLimited"
        /// Driver-side only: the store lane is waiting on the grantor's fetch.
        public static let queued = "queued"
        public static let refusals: Set<String> = [noGrant, notLive, expired, replayed, unknownSender, badRequest, rateLimited]
    }

    // MARK: envelopes

    public static func sealCommand(_ command: Command, from driver: TeamIdentity, to grantor: TeamKeys,
                                   at: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        try Envelope.seal(try CanonicalJSON.encode(command), kind: TeamKinds.command, from: driver, to: [grantor], at: at)
    }

    public static func sealAck(_ ack: Ack, from grantor: TeamIdentity, to driver: TeamKeys,
                               at: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        try Envelope.seal(try CanonicalJSON.encode(ack), kind: TeamKinds.ack, from: grantor, to: [driver], at: at)
    }

    public static func sealHostname(_ hostname: Hostname, from leader: TeamIdentity, to member: TeamKeys,
                                    at: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        try Envelope.seal(try CanonicalJSON.encode(hostname), kind: TeamKinds.hostname, from: leader, to: [member], at: at)
    }

    public static func openCommand(_ file: Data, as me: TeamIdentity,
                                   senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Command) {
        let (header, body) = try open(file, kind: TeamKinds.command, as: me, senderKey: senderKey)
        let command = try decode(Command.self, body)
        guard isPathSafeID(command.id) else { throw Envelope.EnvelopeError.malformed }
        return (header, command)
    }

    public static func openAck(_ file: Data, as me: TeamIdentity,
                               senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Ack) {
        let (header, body) = try open(file, kind: TeamKinds.ack, as: me, senderKey: senderKey)
        return (header, try decode(Ack.self, body))
    }

    public static func openHostname(_ file: Data, as me: TeamIdentity,
                                    senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Hostname) {
        let (header, body) = try open(file, kind: TeamKinds.hostname, as: me, senderKey: senderKey)
        return (header, try decode(Hostname.self, body))
    }

    /// Kinds are not interchangeable: an ack presented as a command is malformed.
    private static func open(_ file: Data, kind: String, as me: TeamIdentity,
                             senderKey: (String) -> TeamKeys?) throws -> (Envelope.Header, Data) {
        let (header, body) = try Envelope.open(file, as: me, senderKey: senderKey)
        guard header.kind == kind else { throw Envelope.EnvelopeError.malformed }
        return (header, body)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do { return try CanonicalJSON.decode(type, from: body) } catch { throw Envelope.EnvelopeError.malformed }
    }

    /// `[a-z0-9-]{8,64}`: the id becomes `…/commands/<id>.json`.
    static func isPathSafeID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { ($0.isASCII && $0.isLowercase && $0.isLetter) || ($0.isASCII && $0.isNumber) || $0 == "-" }
    }

    // MARK: store paths

    public static func commandPath(driver: String, id: String) -> String { "m/\(driver)/control/commands/\(id).json" }
    public static func ackPath(grantor: String, id: String) -> String { "m/\(grantor)/control/acks/\(id).json" }
    public static func hostnamePath(leader: String, member: String) -> String { "m/\(leader)/control/hostnames/\(member).json" }

    // MARK: endpoints

    /// Where a grantor's Mac answers (§5.1), published in `now.json` as a
    /// hint. `rendezvous` is the key its quick-tunnel URL sits under on
    /// infinitus.run; any roster member derives it, and the URL alone
    /// opens nothing.
    public struct Endpoints: Codable, Equatable, Sendable {
        public var lan: String?
        public var hostname: String?
        public var rendezvous: String?
        public init(lan: String? = nil, hostname: String? = nil, rendezvous: String? = nil) {
            self.lan = lan; self.hostname = hostname; self.rendezvous = rendezvous
        }
    }

    /// A verified command as the input the session lane understands
    /// (Mac grantor plan, ruling 2): `approve` is the prompt's Yes or Esc,
    /// never a session-wide ToolApproval rule; `key` only the allowed
    /// keys; `send` and `mode` need text. nil = nothing to run.
    public static func request(action: String, text: String?) -> SessionInput.Request? {
        let text = text ?? ""
        switch action {
        case TeamGrants.send: return text.isEmpty ? nil : SessionInput.Request(kind: .message, text: text)
        case TeamGrants.key: return SessionInput.allowedKeys.contains(text) ? SessionInput.Request(kind: .key, text: text) : nil
        case TeamGrants.approve:
            switch text {
            case "allow": return SessionInput.Request(kind: .key, text: "1")
            case "deny": return SessionInput.Request(kind: .key, text: "esc")
            default: return nil
            }
        case TeamGrants.mode: return text.isEmpty ? nil : SessionInput.Request(kind: .mode, text: text)
        case TeamGrants.resume: return SessionInput.Request(kind: .resume, text: text)
        default: return nil
        }
    }

    /// Distinct from the pairing key (`MirrorRendezvous.key(token:)`) by the
    /// label: a team id and kid are public to the roster, a pairing token is not.
    public static func rendezvousKey(team: String, kid: String) -> String {
        SHA256.hex(Array("team-control|\(team)|\(kid)".utf8))
    }
}

// MARK: - replay set, rate limit

extension TeamControl {
    /// Command ids already executed, kept for their TTL (§4 step 4): a
    /// stolen command file replays nowhere. Persisted so a relaunch
    /// inside a TTL does not reopen the window.
    public struct SeenIDs: Codable, Equatable, Sendable {
        public var expiry: [String: Int] = [:]
        public init() {}

        public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("control-seen.json") }

        public static func load(teamDir: URL) -> SeenIDs {
            (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(SeenIDs.self, from: $0) } ?? SeenIDs()
        }

        public func save(teamDir: URL) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
        }

        /// true = not seen before (now recorded until `until`).
        public mutating func admit(_ id: String, until: Int, now: Int) -> Bool {
            expiry = expiry.filter { $0.value > now }
            if expiry[id] != nil { return false }
            expiry[id] = until
            return true
        }
    }

    /// Per-driver token bucket (§4 step 7): `commands` per `window`.
    /// In memory only — a relaunch resets it, which is fine.
    public struct RateLimit: Equatable, Sendable {
        public static let commands = 5
        public static let window: TimeInterval = 10
        private var stamps: [String: [Date]] = [:]
        public init() {}

        public mutating func allow(kid: String, now: Date) -> Bool {
            let recent = (stamps[kid] ?? []).filter { now.timeIntervalSince($0) < Self.window }
            guard recent.count < Self.commands else { stamps[kid] = recent; return false }
            stamps[kid] = recent + [now]
            return true
        }
    }
}

// MARK: - verification and execution

extension TeamControl {
    /// What the pipeline needs, injected: the app hands its identity,
    /// roster, grants file, live-session table and `AppModel.send`; the
    /// tests hand closures. The pipeline never touches disk itself
    /// except through `seen` (the caller persists it after `handle`).
    public struct Endpoint {
        public var identity: TeamIdentity
        public var roster: () -> TeamRoster?
        public var grants: () -> TeamGrants
        public var liveSessions: () -> [String: Int32]
        public var execute: (_ action: String, _ text: String?, _ pid: Int32) -> SessionInput.Reply
        public var seen: SeenIDs
        public var limit: RateLimit
        public var now: () -> Date
        /// Set by `TeamControlRoute.respond` after each command so the
        /// mounting server can log it.
        public var lastAudit: Audit? = nil

        public init(identity: TeamIdentity, roster: @escaping () -> TeamRoster?, grants: @escaping () -> TeamGrants,
                    liveSessions: @escaping () -> [String: Int32],
                    execute: @escaping (String, String?, Int32) -> SessionInput.Reply,
                    seen: SeenIDs, limit: RateLimit, now: @escaping () -> Date = Date.init) {
            self.identity = identity; self.roster = roster; self.grants = grants; self.liveSessions = liveSessions
            self.execute = execute; self.seen = seen; self.limit = limit; self.now = now
        }
    }

    public struct Verified: Equatable {
        public var header: Envelope.Header
        public var command: Command
        public var pid: Int32
        public var grant: TeamGrants.Grant
    }

    public enum Refusal: Error, Equatable {
        case outcome(String, detail: String?)
    }

    /// Spec §4, first failure wins. Steps: 1 open (signature, roster at
    /// `at`, recipient), 2 addressed to me, 3 ttl/skew, 4 replay, 5 grant,
    /// 6 live, 7 rate. Only a command that passes 1–3 and 5–6 spends its
    /// id and a rate token, so a refused one can be resent.
    public static func verify(_ file: Data, endpoint: inout Endpoint) -> Result<Verified, Refusal> {
        guard let roster = endpoint.roster() else { return .failure(.outcome(Outcome.unknownSender, detail: "no roster")) }
        let sealedAt = (try? Envelope.header(of: file).at) ?? 0
        let header: Envelope.Header
        let command: Command
        do {
            (header, command) = try openCommand(file, as: endpoint.identity, senderKey: { roster.keys(for: $0, at: sealedAt) })
        } catch Envelope.EnvelopeError.unknownSender {
            return .failure(.outcome(Outcome.unknownSender, detail: nil))
        } catch {
            return .failure(.outcome(Outcome.badRequest, detail: "\(error)"))
        }
        guard command.to == endpoint.identity.kid else { return .failure(.outcome(Outcome.badRequest, detail: "addressed to another kid")) }
        // The roster was consulted at the sealed time; the body's clock must be the same one.
        guard command.at == header.at else { return .failure(.outcome(Outcome.badRequest, detail: "at differs from the envelope")) }
        let nowSec = Int(endpoint.now().timeIntervalSince1970)
        guard (1...maxTTL).contains(command.ttl) else { return .failure(.outcome(Outcome.badRequest, detail: "ttl")) }
        guard command.at <= nowSec + maxFutureSkew else { return .failure(.outcome(Outcome.badRequest, detail: "from the future")) }
        guard nowSec <= command.at + command.ttl else { return .failure(.outcome(Outcome.expired, detail: nil)) }
        guard TeamGrants.driveCapabilities.contains(command.action) else { return .failure(.outcome(Outcome.badRequest, detail: "action")) }
        // Step 4 is checked here but SPENT only after 5–6 pass: a replay of
        // an executed id must say `replayed`, while a refused id stays free.
        if endpoint.seen.expiry[command.id].map({ $0 > nowSec }) == true {
            return .failure(.outcome(Outcome.replayed, detail: nil))
        }
        guard let grant = endpoint.grants().permits(kid: header.from, session: command.session, capability: command.action, roster: roster) else {
            return .failure(.outcome(Outcome.noGrant, detail: nil))
        }
        guard let pid = endpoint.liveSessions()[command.session] else { return .failure(.outcome(Outcome.notLive, detail: nil)) }
        guard endpoint.limit.allow(kid: header.from, now: endpoint.now()) else { return .failure(.outcome(Outcome.rateLimited, detail: nil)) }
        _ = endpoint.seen.admit(command.id, until: command.at + command.ttl, now: nowSec)
        return .success(Verified(header: header, command: command, pid: pid, grant: grant))
    }

    public struct Audit: Equatable, Sendable {
        public var driver: String
        public var session: String
        public var action: String
        public var outcome: String
        public var detail: String?
        public init(driver: String, session: String, action: String, outcome: String, detail: String?) {
            self.driver = driver; self.session = session; self.action = action; self.outcome = outcome; self.detail = detail
        }
    }

    /// verify + execute. `driverKeys` is nil when there is nobody to
    /// answer (not a member, or not even an envelope): log and drop.
    public static func handle(_ file: Data, endpoint: inout Endpoint) -> (ack: Ack, audit: Audit, driverKeys: TeamKeys?) {
        let nowSec = Int(endpoint.now().timeIntervalSince1970)
        let header = try? Envelope.header(of: file)
        let roster = endpoint.roster()
        let driverKeys = header.flatMap { h in roster?.keys(for: h.from, at: h.at) }
        switch verify(file, endpoint: &endpoint) {
        case .success(let v):
            let reply = endpoint.execute(v.command.action, v.command.text, v.pid)
            return (Ack(id: v.command.id, outcome: reply.outcome, detail: reply.detail, at: nowSec),
                    Audit(driver: v.header.from, session: v.command.session, action: v.command.action, outcome: reply.outcome, detail: reply.detail),
                    driverKeys)
        case .failure(.outcome(let outcome, let detail)):
            let command = driverKeys != nil ? commandBody(file, as: endpoint.identity, roster: roster) : nil
            let unknown = outcome == Outcome.unknownSender || header == nil
            return (Ack(id: command?.id ?? "", outcome: outcome, detail: detail, at: nowSec),
                    Audit(driver: header?.from ?? "?", session: command?.session ?? "", action: command?.action ?? "",
                          outcome: outcome, detail: detail),
                    unknown ? nil : driverKeys)
        }
    }

    /// The refused command, when the envelope opens at all: its id names
    /// the ack, its session and action the audit line.
    private static func commandBody(_ file: Data, as me: TeamIdentity, roster: TeamRoster?) -> Command? {
        guard let roster, let sealedAt = try? Envelope.header(of: file).at,
              let (_, body) = try? Envelope.open(file, as: me, senderKey: { roster.keys(for: $0, at: sealedAt) }) else { return nil }
        return try? CanonicalJSON.decode(Command.self, from: body)
    }
}
