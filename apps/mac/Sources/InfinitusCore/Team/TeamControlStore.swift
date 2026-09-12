import Foundation

// #220 §5.3 lane 4, both sides. The grantor's pass runs after every
// fetch through the SAME Endpoint the HTTP route uses (one replay set,
// one rate limit); the driver reads acks off the reader.
extension TeamControl {
    /// Store commands already answered, by path and blob version, so a
    /// refused command is refused once, not on every fetch.
    /// `<team dir>/control-handled.json`.
    public struct Handled: Codable, Equatable, Sendable {
        public var versions: [String: String] = [:]
        public init() {}
        public static let commandsFile = "control-handled.json"
        /// The member side of §5.4: which `hostname` blobs this Mac applied.
        public static let hostnamesFile = "control-hostname.json"
        public static func file(teamDir: URL, name: String = commandsFile) -> URL { teamDir.appendingPathComponent(name) }
        public static func load(teamDir: URL, name: String = commandsFile) -> Handled {
            (try? Data(contentsOf: file(teamDir: teamDir, name: name))).flatMap { try? JSONDecoder().decode(Handled.self, from: $0) } ?? Handled()
        }
        public func save(teamDir: URL, name: String = commandsFile) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.file(teamDir: teamDir, name: name), options: .atomic)
        }
        public func contains(_ entry: StoreEntry) -> Bool { versions[entry.path] == entry.version }
        public mutating func mark(_ entry: StoreEntry) { versions[entry.path] = entry.version }
        public mutating func prune(keeping paths: Set<String>) { versions = versions.filter { paths.contains($0.key) } }
    }

    public enum Store {
        /// Commands addressed to me that no earlier pass answered: verify +
        /// execute, ack under my branch (one commit each; commands are
        /// rare), remember the blob. Acks of mine older than 2 × storeTTL
        /// are deleted here too. Returns the audits for the log.
        public static func grantorPass(client: TeamClient, endpoint: inout Endpoint, handled: inout Handled,
                                       now: Int = Int(Date().timeIntervalSince1970)) throws -> [Audit] {
            let me = client.identity.kid
            let headers = try client.readableHeaders()
            let inbox = headers.filter { $0.header.kind == TeamKinds.command && $0.header.from != me }
            handled.prune(keeping: Set(inbox.map(\.entry.path)))
            var audits: [Audit] = []
            for (entry, _) in inbox where !handled.contains(entry) {
                guard let file = try client.raw(entry.path) else { continue }
                let (ack, audit, driverKeys) = handle(file, endpoint: &endpoint)
                handled.mark(entry)
                audits.append(audit)
                guard let driverKeys, !ack.id.isEmpty else { continue }
                try client.publish(kind: TeamKinds.ack, path: "control/acks/\(ack.id).json", plaintext: try CanonicalJSON.encode(ack),
                                   audience: .members([driverKeys.kid]), now: ack.at)
            }
            for (entry, header) in headers where header.kind == TeamKinds.ack && header.from == me && header.at + 2 * storeTTL < now {
                try client.unpublish(path: String(entry.path.dropFirst("m/\(me)/".count)))
            }
            // Phase 2: the answers minted after an inline `pending` — a
            // decision, a wait that timed out — go out here, on the same
            // path as the first ack (replaced, so the reader sees one per
            // id). A driver no longer in the roster gets nothing.
            expirePending(&endpoint, now: now)
            let roster = client.roster?.doc
            for entry in endpoint.outbox.entries {
                guard let keys = roster?.keys(for: entry.to, at: now) else { continue }
                try client.publish(kind: TeamKinds.ack, path: "control/acks/\(entry.ack.id).json", plaintext: try CanonicalJSON.encode(entry.ack),
                                   audience: .members([keys.kid]), now: entry.ack.at)
            }
            endpoint.outbox.entries.removeAll()
            return audits
        }

        /// The driver deletes its own commands once acked, or once too old
        /// for any grantor to accept. Returns how many went.
        public static func driverReap(client: TeamClient, acks: Set<String>, headers: [TeamClient.ReadableHeader]? = nil,
                                      now: Int = Int(Date().timeIntervalSince1970)) throws -> Int {
            let me = client.identity.kid
            var gone = 0
            for (entry, header) in try headers ?? client.readableHeaders() where header.kind == TeamKinds.command && header.from == me {
                let id = URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent
                guard acks.contains(id) || header.at + storeTTL + maxFutureSkew < now else { continue }
                try client.unpublish(path: String(entry.path.dropFirst("m/\(me)/".count)))
                gone += 1
            }
            return gone
        }
    }
}
