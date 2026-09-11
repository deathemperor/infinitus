import Foundation

// The driver's half of #220 §5.3: the lane walk (LAN → hostname →
// rendezvous, then the store), pure over an injected HTTP closure so the
// Mac, the CLI and the tests share one order.
extension TeamControl {
    public enum Lane: String, Codable, Sendable {
        case lan, hostname, rendezvous, store
        /// What the driver's UI says next to the outcome.
        public var label: String {
            switch self {
            case .lan: return "via LAN"
            case .hostname, .rendezvous: return "via tunnel"
            case .store: return "via store, next fetch"
            }
        }
    }

    /// What one command came to: the lane that carried it and the
    /// grantor's outcome (or `queued` while the store lane waits).
    public struct Delivery: Codable, Equatable, Sendable {
        public var id: String
        public var lane: Lane
        public var outcome: String
        public var detail: String?
        public init(id: String, lane: Lane, outcome: String, detail: String?) {
            self.id = id; self.lane = lane; self.outcome = outcome; self.detail = detail
        }
    }

    public struct Interface: Equatable, Sendable {
        public var address: String
        public var mask: String
        public init(address: String, mask: String) { self.address = address; self.mask = mask }
    }

    /// `[a-z0-9-]{8,64}` (TeamKinds' path rule): "c-" + 16 lower hex.
    public static func newCommandID() -> String {
        var g = SystemRandomNumberGenerator()
        return "c-" + (0..<16).map { _ in String(Int.random(in: 0..<16, using: &g), radix: 16) }.joined()
    }

    public struct Deliver {
        public typealias HTTP = @Sendable (_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?,
                                           _ timeout: TimeInterval) throws -> (Int, Data)
        public static let lanTimeout: TimeInterval = 2
        public static let tunnelTimeout: TimeInterval = 5

        public var http: HTTP
        public var interfaces: [Interface]
        public var rendezvousBase: String
        /// kid → tunnel base URL, refreshed on the first refused connection.
        public var rendezvous: [String: String] = [:]

        public init(http: @escaping HTTP, interfaces: [Interface], rendezvousBase: String = MirrorRendezvous.defaultBase) {
            self.http = http; self.interfaces = interfaces; self.rendezvousBase = rendezvousBase
        }

        /// Spec §5.3 step 1: a LAN address is dialed only when it sits in
        /// one of this host's own IPv4 subnets.
        public static func sameSubnet(_ address: String, interfaces: [Interface]) -> Bool {
            guard let a = MirrorPairing.ipv4Octets(address) else { return false }
            return interfaces.contains { i in
                guard let n = MirrorPairing.ipv4Octets(i.address), let m = MirrorPairing.ipv4Octets(i.mask) else { return false }
                return zip(zip(a, n), m).allSatisfy { $0.0 & $1 == $0.1 & $1 }
            }
        }

        /// The walk. nil ⇒ no network lane answered 2xx (the caller falls
        /// to the store). Any throw or non-2xx moves to the next lane: the
        /// store is the authoritative fallback.
        public mutating func exchange(method: String, path: String, headers: [String: String] = [:], body: Data?,
                                      endpoints: Endpoints, kid: String) -> (lane: Lane, status: Int, body: Data)? {
            func attempt(_ base: String, _ timeout: TimeInterval) -> (Int, Data)? {
                guard let url = URL(string: base + path),
                      let r = try? http(method, url, headers, body, timeout), (200..<300).contains(r.0) else { return nil }
                return r
            }
            if let lan = endpoints.lan, let host = lan.split(separator: ":").first,
               Self.sameSubnet(String(host), interfaces: interfaces),
               let r = attempt("http://\(lan)", Self.lanTimeout) { return (.lan, r.0, r.1) }
            if let hostname = endpoints.hostname, let r = attempt("https://\(hostname)", Self.tunnelTimeout) {
                return (.hostname, r.0, r.1)
            }
            if let key = endpoints.rendezvous {
                if let cached = rendezvous[kid], let r = attempt(cached, Self.tunnelTimeout) { return (.rendezvous, r.0, r.1) }
                if let fresh = lookup(key), fresh != rendezvous[kid] {
                    rendezvous[kid] = fresh
                    if let r = attempt(fresh, Self.tunnelTimeout) { return (.rendezvous, r.0, r.1) }
                }
            }
            return nil
        }

        private func lookup(_ key: String) -> String? {
            guard let url = MirrorRendezvous.url(key: key, base: rendezvousBase),
                  let (status, data) = try? http("GET", url, [:], nil, Self.tunnelTimeout), status == 200 else { return nil }
            return MirrorRendezvous.parseLookup(data)
        }
    }

    public enum DriveError: Error, Equatable {
        case noRoster
        case unknownKid(String)
    }

    public enum Drive {
        /// Lanes 1–3. nil when none answered; the caller stores.
        public static func network(_ command: Command, identity: TeamIdentity, roster: TeamRoster,
                                   endpoints: Endpoints?, deliver: inout Deliver) throws -> Delivery? {
            guard let grantor = roster.keys(for: command.to, at: command.at) else { throw DriveError.unknownKid(command.to) }
            guard let endpoints else { return nil }
            let sealed = try sealCommand(command, from: identity, to: grantor, at: command.at)
            guard let (lane, _, body) = deliver.exchange(method: "POST", path: TeamControlRoute.commandPath, body: sealed,
                                                         endpoints: endpoints, kid: command.to) else { return nil }
            guard !body.isEmpty else { return Delivery(id: command.id, lane: lane, outcome: Outcome.badRequest, detail: "no ack") }
            let sealedAt = (try? Envelope.header(of: body).at) ?? 0
            let (_, ack) = try openAck(body, as: identity, senderKey: { roster.keys(for: $0, at: sealedAt) })
            return Delivery(id: command.id, lane: lane, outcome: ack.outcome, detail: ack.detail)
        }

        /// Lane 4: the command under my branch, ttl raised to `storeTTL`,
        /// sealed at `command.at` (verify binds the two).
        public static func store(_ command: Command, client: TeamClient) throws -> Delivery {
            var stored = command
            stored.ttl = storeTTL
            try client.publish(kind: TeamKinds.command, path: "control/commands/\(command.id).json",
                               plaintext: try CanonicalJSON.encode(stored), audience: .members([command.to]), now: command.at)
            return Delivery(id: command.id, lane: .store, outcome: Outcome.queued, detail: "next fetch")
        }

        public static func send(_ command: Command, client: TeamClient, endpoints: Endpoints?, deliver: inout Deliver) throws -> Delivery {
            guard let roster = client.roster?.doc else { throw DriveError.noRoster }
            if let d = try network(command, identity: client.identity, roster: roster, endpoints: endpoints, deliver: &deliver) { return d }
            return try store(command, client: client)
        }

        /// The tail route over the same lanes; never the store.
        public static func tail(kid: String, session: String, since: String?, identity: TeamIdentity, endpoints: Endpoints?,
                                deliver: inout Deliver, now: Date = Date()) throws -> (lane: Lane, body: Data)? {
            guard let endpoints else { return nil }
            let header = try TeamControlRoute.signTail(sessionId: session, by: identity, now: now)
            let path = TeamControlRoute.tailPath(sessionId: session) + (since.map { "?since=\($0)" } ?? "")
            guard let (lane, _, body) = deliver.exchange(method: "GET", path: path, headers: [TeamControlRoute.tailHeader: header],
                                                         body: nil, endpoints: endpoints, kid: kid) else { return nil }
            return (lane, body)
        }
    }
}
