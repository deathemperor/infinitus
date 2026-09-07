import Foundation

// #220 §5.4: a leader mints a Cloudflare named tunnel + DNS record for a
// member and seals the tunnel token to them as a `hostname` envelope.
// The API token stays in `TeamSecrets` (`secretName`); `cloudflare.json`
// under the team dir remembers ids only (zone, account, per-member
// tunnel + dns record), never a token.
public enum TeamHostnames {
    public static let secretName = "cloudflare-api"
    public static let defaultLabel = "team"
    static let mirrorPort = 47824
    public static let apiBase = URL(string: "https://api.cloudflare.com/client/v4")!

    public enum HostnameError: Error, Equatable {
        case notConfigured
        case badName(String)
        case api(Int, String)
        case unknownMember
        /// Hostnames exist under another zone; a new token must not strand them.
        case zoneInUse(String, Int)
    }

    public struct Record: Codable, Equatable, Sendable {
        public var hostname: String
        public var tunnelID: String
        public var dnsID: String?
        public var at: Int
    }

    public struct Ledger: Codable, Equatable, Sendable {
        public var zone: String
        public var label: String
        public var zoneID: String?
        public var accountID: String?
        public var records: [String: Record] = [:]
        public init(zone: String, label: String = TeamHostnames.defaultLabel) { self.zone = zone; self.label = label }

        public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("cloudflare.json") }
        public static func load(teamDir: URL) -> Ledger? {
            (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
        }
        public func save(teamDir: URL) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            try enc.encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
        }

        /// Records whose member left the roster — deletable once a token is present.
        public func orphans(roster: TeamRoster) -> [(kid: String, record: Record)] {
            records.filter { roster.keys(for: $0.key) == nil }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        }
    }

    /// The ledger a new token starts from: names validated, earlier records
    /// carried over under the same zone (ids are re-fetched so the token is
    /// checked), refused while hostnames exist under another zone.
    public static func ledger(zone: String, label: String, teamDir: URL) throws -> Ledger {
        let ledger = Ledger(zone: zone.trimmingCharacters(in: .whitespaces).lowercased(),
                            label: label.trimmingCharacters(in: .whitespaces).lowercased())
        guard validName(ledger.zone), validName(ledger.label) else { throw HostnameError.badName("\(ledger.label).\(ledger.zone)") }
        var out = ledger
        if let old = Ledger.load(teamDir: teamDir), !old.records.isEmpty {
            guard old.zone == ledger.zone else { throw HostnameError.zoneInUse(old.zone, old.records.count) }
            out.records = old.records
        }
        return out
    }

    // MARK: names

    /// Lowercase alphanumerics, runs of anything else collapsed to one `-`, no leading/trailing dash.
    public static func slug(_ name: String) -> String {
        var out = ""
        var dash = false
        for scalar in name.lowercased().unicodeScalars {
            if isLabelChar(scalar) { out.unicodeScalars.append(scalar); dash = false }
            else if !dash, !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private static func isLabelChar(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 97 && s.value <= 122) || (s.value >= 48 && s.value <= 57)
    }

    /// A DNS label or zone as the user typed it: lowercase alphanumerics, `-` and `.`, non-empty.
    public static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { isLabelChar($0) || $0 == "-" || $0 == "." }
    }

    /// `<slug>.<label>.<zone>`; an empty slug falls back to the kid's first
    /// 8, a hostname another record holds gets `-<kid4>` appended.
    public static func hostname(name: String, kid: String, label: String, zone: String, taken: Set<String>) -> String {
        var head = slug(name)
        if head.isEmpty { head = String(kid.prefix(8)) }
        let first = "\(head).\(label).\(zone)"
        return taken.contains(first) ? "\(head)-\(kid.prefix(4)).\(label).\(zone)" : first
    }

    // MARK: Cloudflare

    public struct Cloudflare: Sendable {
        public var token: String
        public var http: TeamControl.Deliver.HTTP
        public var base: URL
        public init(token: String, http: @escaping TeamControl.Deliver.HTTP, base: URL = TeamHostnames.apiBase) {
            self.token = token; self.http = http; self.base = base
        }

        /// One v4 call; only `errors[].message` (or the status) leaves here.
        @discardableResult
        func call(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Any? {
            guard let url = URL(string: base.absoluteString + path) else { throw HostnameError.badName(path) }
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json"]
            let (status, reply) = try http(method, url, headers, data, 20)
            let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            let success = json?["success"] as? Bool ?? false
            guard (200..<300).contains(status), success else {
                let messages = (json?["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
                throw HostnameError.api(status, messages.isEmpty ? "HTTP \(status)" : messages.joined(separator: "; "))
            }
            return json?["result"]
        }

        /// `GET /zones?name=` once; the ids land in the ledger.
        public func ids(ledger: inout Ledger) throws -> (account: String, zone: String) {
            if let a = ledger.accountID, let z = ledger.zoneID { return (a, z) }
            let result = try call("GET", "/zones?name=\(ledger.zone)") as? [[String: Any]]
            guard let zone = result?.first, let zoneID = zone["id"] as? String,
                  let accountID = (zone["account"] as? [String: Any])?["id"] as? String else {
                throw HostnameError.api(200, "no zone named \(ledger.zone) for this token")
            }
            ledger.zoneID = zoneID
            ledger.accountID = accountID
            return (accountID, zoneID)
        }

        /// The four calls of §5.4; `progress` after every step so a failure
        /// leaves a record `forget` can clean.
        func mint(team: String, kid: String, hostname: String, ledger: inout Ledger, now: Int,
                  progress: (Ledger) throws -> Void) throws -> (record: Record, token: String) {
            let (account, zone) = try ids(ledger: &ledger)
            try progress(ledger)
            let created = try call("POST", "/accounts/\(account)/cfd_tunnel",
                                   body: ["name": "infinitus-\(team)-\(kid.prefix(8))", "config_src": "cloudflare"]) as? [String: Any]
            guard let tunnelID = created?["id"] as? String else { throw HostnameError.api(200, "tunnel created without an id") }
            var record = Record(hostname: hostname, tunnelID: tunnelID, dnsID: nil, at: now)
            ledger.records[kid] = record
            try progress(ledger)
            try call("PUT", "/accounts/\(account)/cfd_tunnel/\(tunnelID)/configurations",
                     body: ["config": ["ingress": [["hostname": hostname, "service": "http://localhost:\(TeamHostnames.mirrorPort)"],
                                                   ["service": "http_status:404"]]]])
            let dns = try call("POST", "/zones/\(zone)/dns_records",
                               body: ["type": "CNAME", "name": hostname, "content": "\(tunnelID).cfargotunnel.com",
                                      "proxied": true, "ttl": 1]) as? [String: Any]
            guard let dnsID = dns?["id"] as? String else { throw HostnameError.api(200, "dns record created without an id") }
            record.dnsID = dnsID
            ledger.records[kid] = record
            try progress(ledger)
            guard let token = try call("GET", "/accounts/\(account)/cfd_tunnel/\(tunnelID)/token") as? String, !token.isEmpty else {
                throw HostnameError.api(200, "tunnel token missing")
            }
            return (record, token)
        }

        public func delete(_ record: Record, ledger: inout Ledger) throws {
            let (account, zone) = try ids(ledger: &ledger)
            if let dnsID = record.dnsID { try call("DELETE", "/zones/\(zone)/dns_records/\(dnsID)") }
            try call("DELETE", "/accounts/\(account)/cfd_tunnel/\(record.tunnelID)?cascade=true")
        }
    }

    // MARK: give / inbox / forget

    static func storePath(_ kid: String) -> String { "control/hostnames/\(kid).json" }

    /// Mint for `kid` (a half-minted record is deleted first), seal the
    /// token to them, publish under my branch. The ledger is saved as it goes.
    public static func give(client: TeamClient, kid: String, cloudflare: Cloudflare, ledger: inout Ledger,
                            now: Int = Int(Date().timeIntervalSince1970)) throws -> Record {
        guard validName(ledger.zone), validName(ledger.label) else { throw HostnameError.badName("\(ledger.label).\(ledger.zone)") }
        guard let roster = client.roster?.doc, roster.keys(for: kid) != nil else { throw HostnameError.unknownMember }
        let dir = client.teamDir
        if let stale = ledger.records[kid] {
            try cloudflare.delete(stale, ledger: &ledger)
            ledger.records[kid] = nil
            try ledger.save(teamDir: dir)
        }
        let name = (roster.leaders + roster.members).first { $0.keys.kid == kid }?.name ?? ""
        let taken = Set(ledger.records.values.map(\.hostname))
        let host = hostname(name: name, kid: kid, label: ledger.label, zone: ledger.zone, taken: taken)
        let (record, token) = try cloudflare.mint(team: client.config.id, kid: kid, hostname: host, ledger: &ledger, now: now) {
            try $0.save(teamDir: dir)
        }
        let body = try CanonicalJSON.encode(TeamControl.Hostname(hostname: host, token: token, at: now))
        try client.publish(kind: TeamKinds.hostname, path: storePath(kid), plaintext: body, audience: .members([kid]), now: now)
        return record
    }

    /// The newest `hostname` envelope a current leader sealed to me that
    /// `handled` has not seen; every candidate is marked. nil = nothing new.
    public static func inbox(client: TeamClient, handled: inout TeamControl.Handled,
                             headers: [TeamClient.ReadableHeader]? = nil) throws -> (hostname: TeamControl.Hostname, from: String)? {
        guard let roster = client.roster?.doc else { return nil }
        let me = client.identity.kid
        let candidates = try (headers ?? client.readableHeaders()).filter { entry, header in
            header.kind == TeamKinds.hostname && roster.isLeader(header.from)
                && entry.path == TeamControl.hostnamePath(leader: header.from, member: me) && !handled.contains(entry)
        }
        guard let newest = candidates.max(by: { $0.header.at < $1.header.at }) else { return nil }
        for (entry, _) in candidates { handled.mark(entry) }
        guard let file = try client.raw(newest.entry.path) else { return nil }
        let (_, hostname) = try TeamControl.openHostname(file, as: client.identity) { roster.keys(for: $0, at: newest.header.at) }
        return (hostname, newest.header.from)
    }

    /// Removal cleanup: the envelope goes; the Cloudflare records go when a
    /// token is at hand (true), else the ledger record stays for the orphan list.
    public static func forget(client: TeamClient, kid: String, cloudflare: Cloudflare?, ledger: inout Ledger) throws -> Bool {
        if try client.raw("m/\(client.identity.kid)/\(storePath(kid))") != nil { try client.unpublish(path: storePath(kid)) }
        guard let record = ledger.records[kid], let cloudflare else { return false }
        try cloudflare.delete(record, ledger: &ledger)
        ledger.records[kid] = nil
        return true
    }
}

extension TeamHostnames.HostnameError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "no Cloudflare token yet (Settings › Team › Hostnames, or `infinitusctl team hostname token <zone>`)"
        case .badName(let name): return "not a DNS name: \(name)"
        case .api(let status, let message): return "Cloudflare: \(message) (HTTP \(status))"
        case .unknownMember: return "no such teammate"
        case .zoneInUse(let zone, let n): return "\(n) hostname\(n == 1 ? "" : "s") exist under \(zone); delete them before switching zones"
        }
    }
}
