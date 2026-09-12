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
    /// `Command.session` for a `TeamGrants.machineScoped` action: the Mac, not a session.
    public static let machineSession = "-"
    /// How long a command that needs the grantor's tap waits for it (#220 Phase 2 §4).
    public static let approvalTTL = 120

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
        /// Phase 2 approvals: the grantor is being asked; a second ask while
        /// one waits; the grantor said no; the grant went away meanwhile.
        public static let pending = "pending"
        public static let alreadyPending = "alreadyPending"
        public static let denied = "denied"
        public static let revoked = "revoked"
        public static let refusals: Set<String> = [noGrant, notLive, expired, replayed, unknownSender, badRequest, rateLimited,
                                                   alreadyPending, denied, revoked]
        /// A non-drive action's answer (#220 Phase 2): the verb ran, or it
        /// refused — its own result never travels, an account verb's error
        /// text neither.
        public static let done = "done"
        public static let refused = "refused"
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
        /// The bucket for everything that is not a keystroke (#220 Phase 2):
        /// a stop, a swap, a kill are rarer than prompts.
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
    /// roster, grants file, live-session table and `AppModel.send`; the
    /// tests hand closures. The pipeline never touches disk itself
    /// except through `seen` (the caller persists it after `handle`).
    public struct Endpoint {
        public var identity: TeamIdentity
        public var roster: () -> TeamRoster?
        public var grants: () -> TeamGrants
        public var liveSessions: () -> [String: Int32]
        /// Runs one verified action. `pid` is nil for a `machineScoped`
        /// or `pastScoped` action (the Mac, or a past transcript, is the
        /// target); the session id travels for those.
        public var execute: (_ action: String, _ text: String?, _ session: String, _ pid: Int32?) -> SessionInput.Reply
        public var seen: SeenIDs
        public var limit: RateLimit
        /// The non-drive bucket (`RateLimit.heavy`).
        public var heavyLimit: RateLimit = .heavy
        public var now: () -> Date
        /// Commands waiting for the grantor's tap, by id (#220 Phase 2
        /// §4). In memory: a process that forgets them has denied them,
        /// which is the safe reading; the driver's ack says `expired`.
        public var pending: [String: PendingCommand] = [:]
        /// Acks minted after the inline answer went out (a decision, an
        /// approval that timed out). The store lane drains it.
        public var outbox: Outbox = Outbox()
        /// Set by `TeamControlRoute.respond` after each command so the
        /// mounting server can log it.
        public var lastAudit: Audit? = nil

        public init(identity: TeamIdentity, roster: @escaping () -> TeamRoster?, grants: @escaping () -> TeamGrants,
                    liveSessions: @escaping () -> [String: Int32],
                    execute: @escaping (String, String?, String, Int32?) -> SessionInput.Reply,
                    seen: SeenIDs, limit: RateLimit, now: @escaping () -> Date = Date.init) {
            self.identity = identity; self.roster = roster; self.grants = grants; self.liveSessions = liveSessions
            self.execute = execute; self.seen = seen; self.limit = limit; self.now = now
        }
    }

    public struct Verified: Equatable {
        public var header: Envelope.Header
        public var command: Command
        /// nil for a machine- or past-scoped action.
        public var pid: Int32?
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
    /// executed action's answer survives a relaunch (the driver's stop
    /// ran; it must learn so).
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
        let action = command.action
        guard action != TeamGrants.view, TeamGrants.capabilities.contains(action) else {
            return .failure(.outcome(Outcome.badRequest, detail: "action"))
        }
        // A machine-scoped action names the Mac and nothing else; every
        // other one names a session.
        let machine = TeamGrants.machineScoped.contains(action)
        guard machine == (command.session == machineSession), !command.session.isEmpty else {
            return .failure(.outcome(Outcome.badRequest, detail: "session"))
        }
        // Step 4 is checked here but SPENT only after 5–6 pass: a replay of
        // an executed id must say `replayed`, while a refused id stays free.
        if endpoint.seen.expiry[command.id].map({ $0 > nowSec }) == true {
            return .failure(.outcome(Outcome.replayed, detail: nil))
        }
        guard let grant = endpoint.grants().permits(kid: header.from, session: command.session, capability: action,
                                                    roster: roster, now: nowSec) else {
            return .failure(.outcome(Outcome.noGrant, detail: nil))
        }
        let pid = endpoint.liveSessions()[command.session]
        if !machine, !TeamGrants.pastScoped.contains(action), pid == nil { return .failure(.outcome(Outcome.notLive, detail: nil)) }
        let drive = TeamGrants.driveCapabilities.contains(action)
        let allowed = drive ? endpoint.limit.allow(kid: header.from, now: endpoint.now())
                            : endpoint.heavyLimit.allow(kid: header.from, now: endpoint.now())
        guard allowed else { return .failure(.outcome(Outcome.rateLimited, detail: nil)) }
        _ = endpoint.seen.admit(command.id, until: command.at + command.ttl, now: nowSec)
        return .success(Verified(header: header, command: command, pid: machine ? nil : pid, grant: grant))
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
            let c = v.command
            func answer(_ outcome: String, _ detail: String?) -> (ack: Ack, audit: Audit, driverKeys: TeamKeys?) {
                (Ack(id: c.id, outcome: outcome, detail: detail, at: nowSec),
                 Audit(driver: v.header.from, session: c.session, action: c.action, outcome: outcome, detail: detail),
                 driverKeys)
            }
            // Phase 2 §4: a capability the grant did not pre-authorize waits
            // for the grantor's tap. Its id is spent (a resend says
            // `replayed`), one wait per (driver, action, session).
            if v.grant.requiresApproval(c.action) {
                expirePending(&endpoint, now: nowSec)
                if endpoint.pending.values.contains(where: { $0.driver == v.header.from && $0.command.action == c.action && $0.command.session == c.session }) {
                    return answer(Outcome.alreadyPending, nil)
                }
                guard let driverKeys else { return answer(Outcome.unknownSender, nil) }
                endpoint.pending[c.id] = PendingCommand(driver: v.header.from, driverKeys: driverKeys, command: c, expires: nowSec + approvalTTL)
                return answer(Outcome.pending, nil)
            }
            let reply = endpoint.execute(c.action, c.text, c.session, v.pid)
            return answer(reply.outcome, reply.detail)
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

// MARK: - approvals (#220 Phase 2 §4) and the local verb each action runs

extension TeamControl {
    /// Drops every wait past its TTL and tells its driver `expired`
    /// through the outbox. Called before a new wait is recorded and by
    /// the grantor's periodic pass.
    public static func expirePending(_ endpoint: inout Endpoint, now: Int) {
        for (id, entry) in endpoint.pending where entry.expires <= now {
            endpoint.pending[id] = nil
            endpoint.outbox.entries.append(Outbox.Entry(to: entry.driver, ack: Ack(id: id, outcome: Outcome.expired, detail: nil, at: now)))
        }
    }

    /// The grantor's tap. Re-resolves everything at this instant: the
    /// grant (revoked or expired meanwhile ⇒ `revoked`), the session's
    /// pid (gone ⇒ `notLive`, never a signal to a reused pid). The
    /// answer goes to the outbox — the inline ack said `pending` — and is
    /// returned for the grantor's own log. nil: no such wait.
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
                  endpoint.grants().permits(kid: entry.driver, session: c.session, capability: c.action, roster: roster, now: nowSec) == nil {
            (outcome, detail) = (Outcome.revoked, nil)
        } else {
            let machine = TeamGrants.machineScoped.contains(c.action)
            let pid = machine ? nil : endpoint.liveSessions()[c.session]
            if !machine, !TeamGrants.pastScoped.contains(c.action), pid == nil {
                (outcome, detail) = (Outcome.notLive, nil)
            } else {
                let reply = endpoint.execute(c.action, c.text, c.session, pid)
                (outcome, detail) = (reply.outcome, reply.detail)
            }
        }
        let ack = Ack(id: id, outcome: outcome, detail: detail, at: nowSec)
        endpoint.outbox.entries.append(Outbox.Entry(to: entry.driver, ack: ack))
        return (ack, Audit(driver: entry.driver, session: c.session, action: c.action, outcome: outcome, detail: detail), entry.driverKeys)
    }

    /// One of the grantor's own control verbs, exactly as `infinitusctl`
    /// would send it: the Mac runs it through the same dispatch, so a
    /// teammate, the phone and the CLI share one code path and one set of
    /// refusals. `text` is the action's argument line, validated here so
    /// nothing shell-shaped reaches the verb: a fleet is `[a-z0-9-]`, a
    /// number a positive int. nil = badRequest.
    public struct LocalVerb: Equatable, Sendable {
        public var command: String
        public var args: [String]
        public var options: [String: String]
        public init(command: String, args: [String] = [], options: [String: String] = [:]) {
            self.command = command; self.args = args; self.options = options
        }
    }

    public static func localVerb(action: String, text: String?, session: String, pid: Int32?) -> LocalVerb? {
        let words = (text ?? "").split(separator: " ").map(String.init)
        func fleet(_ s: String) -> String? {
            (1...32).contains(s.count) && s.allSatisfy { ($0.isASCII && $0.isLowercase && $0.isLetter) || ($0.isASCII && $0.isNumber) || $0 == "-" } ? s : nil
        }
        func number(_ s: String) -> String? { Int(s).map { $0 > 0 ? String($0) : nil } ?? nil }
        switch action {
        case TeamGrants.stop:
            guard let pid, words.isEmpty else { return nil }
            return LocalVerb(command: "session-stop", args: [String(pid)], options: ["yes": ""])
        case TeamGrants.resumePast:
            switch words {
            case []: return LocalVerb(command: "resume-session", args: [session])
            case ["fork"]: return LocalVerb(command: "resume-session", args: [session], options: ["fork": ""])
            default: return nil
            }
        case TeamGrants.delete:
            guard words.isEmpty else { return nil }
            return LocalVerb(command: "session-delete", args: [session], options: ["yes": ""])
        case TeamGrants.swap:
            guard words.count == 2, let f = fleet(words[0]), let n = number(words[1]) else { return nil }
            return LocalVerb(command: "switch", args: [f, n])
        case TeamGrants.hold:
            guard (2...3).contains(words.count), let f = fleet(words[0]), let n = number(words[1]) else { return nil }
            switch words.count == 3 ? words[2] : "on" {
            case "on": return LocalVerb(command: "hold", args: [f, n])
            case "off": return LocalVerb(command: "unhold", args: [f, n])
            default: return nil
            }
        default:
            return nil
        }
    }

    /// A local verb's `ControlReply` as the driver's ack: `done` with no
    /// detail, or `refused` with the verb's error — except the account verbs
    /// (`switch`, `hold`, `unhold`), whose errors can name accounts (#220 §4).
    public static func verbReply(_ verb: LocalVerb, ok: Bool, error: String?) -> SessionInput.Reply {
        if ok { return SessionInput.Reply(outcome: Outcome.done, detail: nil) }
        let account = ["switch", "hold", "unhold"].contains(verb.command)
        return SessionInput.Reply(outcome: Outcome.refused, detail: account ? nil : error)
    }
}
