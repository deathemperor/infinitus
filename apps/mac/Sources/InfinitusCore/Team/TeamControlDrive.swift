import Foundation

// The driver's half of spec §8: the lane walk (the grantor's desktop over
// its LAN base URLs, then its tunnel, then the store), pure over an
// injected HTTP closure so the Mac, the CLI and the tests share one order.
extension TeamControl {
    public enum Lane: String, Codable, Sendable {
        case lan, tunnel, store
        /// What the driver's UI says next to the outcome.
        public var label: String {
            switch self {
            case .lan: return "via LAN"
            case .tunnel: return "via tunnel"
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

    /// `[a-z0-9-]{8,64}` (TeamKinds' path rule): "c-" + 16 lower hex.
    public static func newCommandID() -> String {
        var g = SystemRandomNumberGenerator()
        return "c-" + (0..<16).map { _ in String(Int.random(in: 0..<16, using: &g), radix: 16) }.joined()
    }

    /// The desktop's route (`packages/contracts/src/infinitusTeamControl.ts`):
    /// `{envelope: base64}` in, `{ack: base64 | null}` out.
    public static let routePath = "/api/infinitus/team/command"

    public struct Deliver {
        public typealias HTTP = @Sendable (_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?,
                                           _ timeout: TimeInterval) throws -> (Int, Data)
        public static let lanTimeout: TimeInterval = 2
        public static let tunnelTimeout: TimeInterval = 5

        public var http: HTTP

        public init(http: @escaping HTTP) { self.http = http }

        /// A base URL that names this same machine: never dialed from
        /// another one.
        public static func isLoopback(_ base: String) -> Bool {
            guard let host = URL(string: base)?.host?.lowercased() else { return true }
            return host == "localhost" || host == "::1" || host.hasPrefix("127.") || host == "0.0.0.0"
        }

        /// The network lanes in order: every LAN base URL (the desktop's
        /// own when it is not loopback), then the tunnel. Each is dialed
        /// with its lane's timeout; there is no subnet pre-check, an
        /// unreachable address simply times out.
        public static func lanes(_ endpoints: Endpoints) -> [(lane: Lane, base: String)] {
            var out: [(Lane, String)] = []
            for base in (endpoints.lanHttpBaseUrls ?? []) + [endpoints.httpBaseUrl].compactMap({ $0 }) where !isLoopback(base) {
                if !out.contains(where: { $0.1 == base }) { out.append((.lan, base)) }
            }
            if let tunnel = endpoints.tunnel, !tunnel.isEmpty { out.append((.tunnel, tunnel)) }
            return out
        }

        /// The walk. nil ⇒ no network lane answered 2xx with an ack (the
        /// caller falls to the store). Any throw or non-2xx moves to the
        /// next lane: the store is the authoritative fallback.
        public func exchange(sealed: Data, endpoints: Endpoints) -> (lane: Lane, ack: Data?)? {
            let body = try? JSONEncoder().encode(["envelope": sealed.base64EncodedString()])
            let headers = ["Content-Type": "application/json", "Accept": "application/json"]
            for (lane, base) in Self.lanes(endpoints) {
                guard let url = URL(string: base.hasSuffix("/") ? String(base.dropLast()) + routePath : base + routePath),
                      let (status, data) = try? http("POST", url, headers, body, lane == .lan ? Self.lanTimeout : Self.tunnelTimeout),
                      (200..<300).contains(status) else { continue }
                return (lane, Self.ack(in: data))
            }
            return nil
        }

        /// `{ack: base64}` → the sealed ack; `{ack: null}` or anything else → nil.
        static func ack(in data: Data) -> Data? {
            guard let reply = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                  case .string(let base64)? = reply["ack"] else { return nil }
            return Data(base64Encoded: base64)
        }
    }

    public enum DriveError: Error, Equatable {
        case noRoster
        case unknownKid(String)
    }

    public enum Drive {
        /// The network lanes. nil when none answered; the caller stores.
        public static func network(_ command: Command, identity: TeamIdentity, roster: TeamRoster,
                                   endpoints: Endpoints?, deliver: Deliver) throws -> Delivery? {
            guard let grantor = roster.keys(for: command.to, at: command.at) else { throw DriveError.unknownKid(command.to) }
            guard let endpoints else { return nil }
            let sealed = try sealCommand(command, from: identity, to: grantor, at: command.at)
            guard let (lane, ack) = deliver.exchange(sealed: sealed, endpoints: endpoints) else { return nil }
            guard let ack else { return Delivery(id: command.id, lane: lane, outcome: Outcome.badRequest, detail: "no ack") }
            let sealedAt = (try? Envelope.header(of: ack).at) ?? 0
            let (_, opened) = try openAck(ack, as: identity, senderKey: { roster.keys(for: $0, at: sealedAt) })
            return Delivery(id: command.id, lane: lane, outcome: opened.outcome, detail: opened.detail)
        }

        /// The store lane: the command under my branch, ttl raised to
        /// `storeTTL`, sealed at `command.at` (verify binds the two).
        public static func store(_ command: Command, client: TeamClient) throws -> Delivery {
            var stored = command
            stored.ttl = storeTTL
            try client.publish(kind: TeamKinds.command, path: "control/commands/\(command.id).json",
                               plaintext: try CanonicalJSON.encode(stored), audience: .members([command.to]), now: command.at)
            return Delivery(id: command.id, lane: .store, outcome: Outcome.queued, detail: "next fetch")
        }

        public static func send(_ command: Command, client: TeamClient, endpoints: Endpoints?, deliver: Deliver) throws -> Delivery {
            guard let roster = client.roster?.doc else { throw DriveError.noRoster }
            if let d = try network(command, identity: client.identity, roster: roster, endpoints: endpoints, deliver: deliver) { return d }
            return try store(command, client: client)
        }
    }
}
