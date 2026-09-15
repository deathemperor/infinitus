import Foundation

/// Delegated thread control (spec §8): the envelopes a driver and a
/// grantor exchange, and the pipeline the grantor runs before anything
/// reaches Infinitus desktop. Pure: every dependency with IO is injected
/// through `Endpoint`, so the whole thing is tested without a Mac, a
/// store or git, and mounts on the Linux tray unchanged.
public enum TeamControl {
    public static let defaultTTL = 120
    public static let maxTTL = 600
    /// The store lane's TTL: the grantor's fetch cadence (≤ 5 min) must not expire it.
    public static let storeTTL = 600
    /// A command "from the future" beyond this is a bad clock or a forgery.
    public static let maxFutureSkew = 300
    /// `Command.thread` for a `TeamGrants.machineScoped` action: the Mac, not a thread.
    public static let machineThread = "-"
    /// How long a command that needs the grantor's tap waits for it.
    public static let approvalTTL = 120
    /// The most a `view` answer carries, after redaction.
    public static let viewDetailCap = 4096

    /// One action on one thread, sealed by the driver to the grantor.
    public struct Command: Codable, Equatable, Sendable {
        public var schema = 1
        /// Minted by the driver; a store path segment, so `[a-z0-9-]{8,64}`.
        public var id: String
        /// The grantor's kid — sealed AND addressed, so a command sealed to
        /// me but naming someone else is refused.
        public var to: String
        /// A desktop thread id, or `machineThread` for `new`.
        public var thread: String
        /// A `TeamGrants.capabilities` member.
        public var action: String
        public var text: String?
        /// `new`: the project's title or id on the grantor's desktop.
        public var project: String?
        public var at: Int
        public var ttl: Int
        public init(id: String, to: String, thread: String, action: String, text: String?, project: String? = nil,
                    at: Int, ttl: Int = TeamControl.defaultTTL) {
            self.id = id; self.to = to; self.thread = thread; self.action = action; self.text = text; self.project = project
            self.at = at; self.ttl = ttl
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

    /// What the executor says about one verified command.
    public struct Reply: Equatable, Sendable {
        public var outcome: String
        public var detail: String?
        public init(outcome: String, detail: String? = nil) { self.outcome = outcome; self.detail = detail }
    }

    /// `Ack.outcome`.
    public enum Outcome {
        /// `send`: the prompt reached the thread.
        public static let delivered = "delivered"
        /// `interrupt`, `new`, `view`: ran; `view` and `new` carry a detail.
        public static let done = "done"
        /// The desktop refused, or nothing to run (no running turn, no
        /// project, no default model); the detail says which.
        public static let refused = "refused"
        public static let noGrant = "noGrant"
        public static let notLive = "notLive"
        public static let expired = "expired"
        public static let replayed = "replayed"
        public static let unknownSender = "unknownSender"
        public static let badRequest = "badRequest"
        public static let rateLimited = "rateLimited"
        /// Driver-side only: the store lane is waiting on the grantor's fetch.
        public static let queued = "queued"
        /// The grantor is being asked; a second ask while one waits; the
        /// grantor said no; the grant went away meanwhile.
        public static let pending = "pending"
        public static let alreadyPending = "alreadyPending"
        public static let denied = "denied"
        public static let revoked = "revoked"
        public static let refusals: Set<String> = [noGrant, notLive, expired, replayed, unknownSender, badRequest, rateLimited,
                                                   alreadyPending, denied, revoked, refused]
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

    // MARK: endpoints

    /// Where a grantor's desktop answers `POST /api/infinitus/team/command`
    /// (spec §8), published in `now.json` as a hint: the desktop's own
    /// base URL when it is not loopback, its LAN base URLs, the Mac's
    /// tunnel. The route is unauthenticated; the envelope authenticates.
    public struct Endpoints: Codable, Equatable, Sendable {
        public var httpBaseUrl: String?
        public var lanHttpBaseUrls: [String]?
        public var tunnel: String?
        public init(httpBaseUrl: String? = nil, lanHttpBaseUrls: [String]? = nil, tunnel: String? = nil) {
            self.httpBaseUrl = httpBaseUrl; self.lanHttpBaseUrls = lanHttpBaseUrls; self.tunnel = tunnel
        }
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
        /// The bucket for what asks (`interrupt`, `new`): rarer than prompts.
        public static let heavyCommands = 6
        public static let heavyWindow: TimeInterval = 60
        public let commands: Int
        public let window: TimeInterval
        private var stamps: [String: [Date]] = [:]
        public init(commands: Int = RateLimit.commands, window: TimeInterval = RateLimit.window) {
            self.commands = commands; self.window = window
        }
        public static var heavy: RateLimit { RateLimit(commands: heavyCommands, window: heavyWindow) }

        public mutating func allow(kid: String, now: Date) -> Bool {
            let recent = (stamps[kid] ?? []).filter { now.timeIntervalSince($0) < window }
            guard recent.count < commands else { stamps[kid] = recent; return false }
            stamps[kid] = recent + [now]
            return true
        }
    }
}

// MARK: - verification and execution

extension TeamControl {
    /// What the pipeline needs, injected: the app hands its identity,
    /// roster, grants file, the desktop's thread ids and its executor;
    /// the tests hand closures. The pipeline never touches disk itself
    /// except through `seen` (the caller persists it after `handle`).
    public struct Endpoint {
        public var identity: TeamIdentity
        public var roster: () -> TeamRoster?
        public var grants: () -> TeamGrants
        /// The thread ids Infinitus desktop has right now; empty when it
        /// does not answer, which reads as `notLive` for every thread.
        public var threads: () -> Set<String>
        /// Runs one verified command against the desktop.
        public var execute: (Command) -> Reply
        public var seen: SeenIDs
        public var limit: RateLimit
        /// The asking bucket (`RateLimit.heavy`).
        public var heavyLimit: RateLimit = .heavy
        public var now: () -> Date
        /// Commands waiting for the grantor's tap, by id. In memory: a
        /// process that forgets them has denied them, which is the safe
        /// reading; the driver's ack says `expired`.
        public var pending: [String: PendingCommand] = [:]
        /// Acks minted after the inline answer went out (a decision, an
        /// approval that timed out). The store lane drains it.
        public var outbox: Outbox = Outbox()

        public init(identity: TeamIdentity, roster: @escaping () -> TeamRoster?, grants: @escaping () -> TeamGrants,
                    threads: @escaping () -> Set<String>, execute: @escaping (Command) -> Reply,
                    seen: SeenIDs, limit: RateLimit, now: @escaping () -> Date = Date.init) {
            self.identity = identity; self.roster = roster; self.grants = grants; self.threads = threads
            self.execute = execute; self.seen = seen; self.limit = limit; self.now = now
        }
    }

    public struct Verified: Equatable {
        public var header: Envelope.Header
        public var command: Command
        public var grant: TeamGrants.Grant
    }

    /// A verified command the grantor has not yet allowed or denied.
    public struct PendingCommand: Equatable, Sendable {
        public var driver: String
        public var driverKeys: TeamKeys
        public var command: Command
        public var expires: Int
        public init(driver: String, driverKeys: TeamKeys, command: Command, expires: Int) {
            self.driver = driver; self.driverKeys = driverKeys; self.command = command; self.expires = expires
        }
    }

    /// Acks to publish later, persisted beside `control-seen.json` so an
    /// executed action's answer survives a relaunch (the driver's
    /// interrupt ran; it must learn so).
    public struct Outbox: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var to: String
            public var ack: Ack
            public init(to: String, ack: Ack) { self.to = to; self.ack = ack }
        }
        public var entries: [Entry] = []
        public init() {}

        public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("control-outbox.json") }

        public static func load(teamDir: URL) -> Outbox {
            (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(Outbox.self, from: $0) } ?? Outbox()
        }

        public func save(teamDir: URL) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
        }
    }

    public enum Refusal: Error, Equatable {
        case outcome(String, detail: String?)
    }

    /// Spec §8, first failure wins. Steps: 1 open (signature, roster at
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
        let action = command.action
        guard TeamGrants.capabilities.contains(action) else { return .failure(.outcome(Outcome.badRequest, detail: "action")) }
        // A machine-scoped action names the Mac and a project; every other
        // one names a thread.
        let machine = TeamGrants.machineScoped.contains(action)
        guard machine == (command.thread == machineThread), !command.thread.isEmpty else {
            return .failure(.outcome(Outcome.badRequest, detail: "thread"))
        }
        if machine, (command.project ?? "").isEmpty { return .failure(.outcome(Outcome.badRequest, detail: "project")) }
        // Step 4 is checked here but SPENT only after 5–6 pass: a replay of
        // an executed id must say `replayed`, while a refused id stays free.
        if endpoint.seen.expiry[command.id].map({ $0 > nowSec }) == true {
            return .failure(.outcome(Outcome.replayed, detail: nil))
        }
        guard let grant = endpoint.grants().permits(kid: header.from, thread: command.thread, capability: action,
                                                    roster: roster, now: nowSec) else {
            return .failure(.outcome(Outcome.noGrant, detail: nil))
        }
        if !machine, !endpoint.threads().contains(command.thread) { return .failure(.outcome(Outcome.notLive, detail: nil)) }
        let drive = TeamGrants.driveCapabilities.contains(action)
        let allowed = drive ? endpoint.limit.allow(kid: header.from, now: endpoint.now())
                            : endpoint.heavyLimit.allow(kid: header.from, now: endpoint.now())
        guard allowed else { return .failure(.outcome(Outcome.rateLimited, detail: nil)) }
        _ = endpoint.seen.admit(command.id, until: command.at + command.ttl, now: nowSec)
        return .success(Verified(header: header, command: command, grant: grant))
    }

    public struct Audit: Equatable, Sendable {
        public var driver: String
        public var thread: String
        public var action: String
        public var outcome: String
        public var detail: String?
        public init(driver: String, thread: String, action: String, outcome: String, detail: String?) {
            self.driver = driver; self.thread = thread; self.action = action; self.outcome = outcome; self.detail = detail
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
            let c = v.command
            func answer(_ outcome: String, _ detail: String?) -> (ack: Ack, audit: Audit, driverKeys: TeamKeys?) {
                (Ack(id: c.id, outcome: outcome, detail: detail, at: nowSec),
                 Audit(driver: v.header.from, thread: c.thread, action: c.action, outcome: outcome, detail: detail),
                 driverKeys)
            }
            // A capability the grant did not pre-authorize waits for the
            // grantor's tap. Its id is spent (a resend says `replayed`),
            // one wait per (driver, action, thread).
            if v.grant.requiresApproval(c.action) {
                expirePending(&endpoint, now: nowSec)
                if endpoint.pending.values.contains(where: { $0.driver == v.header.from && $0.command.action == c.action && $0.command.thread == c.thread }) {
                    return answer(Outcome.alreadyPending, nil)
                }
                guard let driverKeys else { return answer(Outcome.unknownSender, nil) }
                endpoint.pending[c.id] = PendingCommand(driver: v.header.from, driverKeys: driverKeys, command: c, expires: nowSec + approvalTTL)
                return answer(Outcome.pending, nil)
            }
            let reply = endpoint.execute(c)
            return answer(reply.outcome, reply.detail)
        case .failure(.outcome(let outcome, let detail)):
            let command = driverKeys != nil ? commandBody(file, as: endpoint.identity, roster: roster) : nil
            let unknown = outcome == Outcome.unknownSender || header == nil
            return (Ack(id: command?.id ?? "", outcome: outcome, detail: detail, at: nowSec),
                    Audit(driver: header?.from ?? "?", thread: command?.thread ?? "", action: command?.action ?? "",
                          outcome: outcome, detail: detail),
                    unknown ? nil : driverKeys)
        }
    }

    /// The refused command, when the envelope opens at all: its id names
    /// the ack, its thread and action the audit line.
    private static func commandBody(_ file: Data, as me: TeamIdentity, roster: TeamRoster?) -> Command? {
        guard let roster, let sealedAt = try? Envelope.header(of: file).at,
              let (_, body) = try? Envelope.open(file, as: me, senderKey: { roster.keys(for: $0, at: sealedAt) }) else { return nil }
        return try? CanonicalJSON.decode(Command.self, from: body)
    }
}

// MARK: - approvals

extension TeamControl {
    /// Drops every wait past its TTL and tells its driver `expired`
    /// through the outbox. Called before a new wait is recorded and by
    /// the grantor's store pass.
    public static func expirePending(_ endpoint: inout Endpoint, now: Int) {
        for (id, entry) in endpoint.pending where entry.expires <= now {
            endpoint.pending[id] = nil
            endpoint.outbox.entries.append(Outbox.Entry(to: entry.driver, ack: Ack(id: id, outcome: Outcome.expired, detail: nil, at: now)))
        }
    }

    /// The grantor's tap. Re-resolves everything at this instant: the
    /// grant (revoked or expired meanwhile ⇒ `revoked`), the thread (gone
    /// ⇒ `notLive`). The answer goes to the outbox — the inline ack said
    /// `pending` — and is returned for the grantor's own log. nil: no such wait.
    public static func decide(_ id: String, allow: Bool, endpoint: inout Endpoint) -> (ack: Ack, audit: Audit, driverKeys: TeamKeys)? {
        let nowSec = Int(endpoint.now().timeIntervalSince1970)
        expirePending(&endpoint, now: nowSec)
        guard let entry = endpoint.pending.removeValue(forKey: id) else { return nil }
        let c = entry.command
        let outcome: String
        let detail: String?
        if !allow {
            (outcome, detail) = (Outcome.denied, nil)
        } else if let roster = endpoint.roster(),
                  endpoint.grants().permits(kid: entry.driver, thread: c.thread, capability: c.action, roster: roster, now: nowSec) == nil {
            (outcome, detail) = (Outcome.revoked, nil)
        } else if !TeamGrants.machineScoped.contains(c.action), !endpoint.threads().contains(c.thread) {
            (outcome, detail) = (Outcome.notLive, nil)
        } else {
            let reply = endpoint.execute(c)
            (outcome, detail) = (reply.outcome, reply.detail)
        }
        let ack = Ack(id: id, outcome: outcome, detail: detail, at: nowSec)
        endpoint.outbox.entries.append(Outbox.Entry(to: entry.driver, ack: ack))
        return (ack, Audit(driver: entry.driver, thread: c.thread, action: c.action, outcome: outcome, detail: detail), entry.driverKeys)
    }
}
