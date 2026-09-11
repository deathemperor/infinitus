import Foundation

/// The team side of Nearby (spec §6.4): what this machine advertises,
/// the two LAN routes (`GET /team/key`, `POST /team/request`) as pure
/// request → response functions so the Mac's MirrorServer and the
/// Linux PosixHTTPServer mount one handler, and where an incoming
/// request lands. `POST /team/invite` is the leader's half of §6.4: an
/// invite link sealed to one peer. Lives beside TeamClient, never in it:
/// TeamClient's surface is the publisher's.
public enum TeamNearby {
    public static let keyPath = "/team/key"
    public static let requestPath = "/team/request"
    public static let invitePath = "/team/invite"
    public static let routePrefix = "/team/"
    /// The UserDefaults bool the Mac app, its Team pane (plan 5) and
    /// `infinitusctl team-discoverable` share. Off by default.
    public static let discoverableDefaultsKey = "team_discoverable"
    /// Pending requests kept per team, bounded so an unauthenticated LAN
    /// peer can't grow the *offline* queue without limit — once the
    /// store is reachable, `save` deletes the pending copy right after
    /// the push succeeds, so the count rarely nears this. The
    /// `requests` branch itself has no such ceiling.
    public static let pendingCap = 100
    /// Invitations a machine will hold at once. An unauthenticated LAN
    /// peer can post one per kid, so the count is bounded the same way
    /// `pendingCap` bounds requests; a sender already in the book may
    /// always replace its own.
    public static let inviteCap = 20

    /// `GET /team/key`.
    public struct KeyReply: Codable, Equatable, Sendable {
        public var name: String
        public var keys: TeamKeys
        public var team: String?
        public var role: String

        public init(name: String, keys: TeamKeys, team: String?, role: String) {
            self.name = name; self.keys = keys; self.team = team; self.role = role
        }
    }

    /// `POST /team/request` body. `TeamRequest` names no team (a leader
    /// may lead several), so the LAN body says which one.
    public struct Request: Codable, Equatable, Sendable {
        public var team: String
        public var request: Signed<TeamRequest>

        public init(team: String, request: Signed<TeamRequest>) {
            self.team = team; self.request = request
        }
    }

    public struct RequestReply: Codable, Equatable, Sendable {
        public var ok: Bool
        /// "branch": the team's requests branch took it (the leader's
        /// `requests()` sees it); "pending": kept locally until it can.
        public var stored: String

        public init(ok: Bool, stored: String) { self.ok = ok; self.stored = stored }
    }

    /// `POST /team/invite` body (spec §6.4): the leader's keys and names,
    /// and the invite link (§6.2) sealed to the peer's encryption key.
    /// The link carries the store's write credential, so it exists on the
    /// wire and on disk only as ciphertext; `openInvite` is the only way
    /// back to the text, and it needs this machine's identity.
    public struct Invite: Codable, Equatable, Sendable, Identifiable {
        public var from: TeamKeys
        /// The inviting machine's display name, for "Loc invites you to Papaya".
        public var fromName: String
        public var teamName: String
        /// `Envelope.seal(Data(link.utf8), kind: "invite", …)`.
        public var envelope: Data

        public var id: String { from.kid }
        /// When the sender sealed it — read from the signed envelope
        /// header rather than a field of its own, so a THIRD PARTY can't
        /// backdate an invitation without breaking the signature. Display
        /// only: the sender itself may still set any `at` it likes, so
        /// eviction order and the 30-day prune key on the receiver's own
        /// clock (the invite file's modification date, set by
        /// `saveInvite`) instead — see `Store.savedAt`.
        public var at: Int { (try? Envelope.header(of: envelope).at) ?? 0 }

        public init(from: TeamKeys, fromName: String, teamName: String, envelope: Data) {
            self.from = from; self.fromName = fromName; self.teamName = teamName; self.envelope = envelope
        }
    }

    public struct InviteReply: Codable, Equatable, Sendable {
        public var ok: Bool
        public init(ok: Bool) { self.ok = ok }
    }

    // MARK: local standing

    public struct Local: Equatable, Sendable {
        public var record: NearbyRecord
        /// nil while hidden: no identity is minted for a machine that
        /// isn't advertising.
        public var keys: TeamKeys?
        /// False when this machine's local roster for the advertised
        /// team has closed requests (`policy.requests == "off"`, spec
        /// §6.3/§6.4): `POST /team/request` must be refused before
        /// anything is written. Checked for leader *and* member standing
        /// — a member's machine holds the same write credential and the
        /// same signed roster, so the check is load-bearing there too.
        /// True whenever there's no team to close. Reads the roster as
        /// persisted on disk, not freshly fetched, so a policy flip made
        /// on another device isn't seen here until this machine's next
        /// `fetch()`.
        public var requestsOpen: Bool

        public init(record: NearbyRecord, keys: TeamKeys?, requestsOpen: Bool = true) {
            self.record = record; self.keys = keys; self.requestsOpen = requestsOpen
        }

        public static let hidden = Local(record: .hidden, keys: nil)

        /// Leader of any team → leader of the first (sorted) such team;
        /// else member likewise; else none. Opens the team clones (file
        /// IO, no network on an existing mirror) — the app calls this off
        /// the main actor.
        public static func load(name: String, discoverable: Bool, paths: TeamPaths, secrets: TeamSecrets) -> Local {
            guard discoverable, let me = try? TeamClient.identity(paths: paths, secrets: secrets) else { return .hidden }
            var team: String? = nil
            var role = "none"
            var requestsOpen = true
            for id in paths.teamIDs() {
                guard let client = try? TeamClient.open(id: id, paths: paths, secrets: secrets) else { continue }
                if client.isLeader {
                    team = id; role = "leader"
                    requestsOpen = client.roster?.doc.policy.requests != "off"
                    break
                }
                if client.isMember, role == "none" {
                    team = id; role = "member"
                    requestsOpen = client.roster?.doc.policy.requests != "off"
                }
            }
            return Local(record: NearbyRecord(name: name, kid: me.kid, team: team, role: role, discoverable: true),
                         keys: me.keys, requestsOpen: requestsOpen)
        }
    }

    // MARK: routes

    /// What the routes need: the local standing, where a request goes
    /// (`store` returns "branch" or "pending") and where an invitation
    /// goes (`storeInvite`).
    public struct Endpoint {
        public var local: Local
        public var store: (Request) throws -> String
        /// Defaulted to a refusal so an endpoint built without one answers
        /// 503 rather than pretending it kept the invitation.
        public var storeInvite: (Invite) throws -> Void

        public init(local: Local, store: @escaping (Request) throws -> String,
                    storeInvite: @escaping (Invite) throws -> Void = { _ in throw StoreError.full }) {
            self.local = local; self.store = store; self.storeInvite = storeInvite
        }
    }

    /// nil = not a `/team/` route, keep routing. A hidden (or absent)
    /// endpoint answers 404 to every team route — the spec's "off ⇒ the
    /// endpoints answer 404". No pairing token here: peers have none.
    public static func respond(_ request: MirrorTransport.Request, endpoint: Endpoint?) -> Data? {
        guard request.path.hasPrefix(routePrefix) else { return nil }
        guard let endpoint, endpoint.local.record.discoverable, let keys = endpoint.local.keys else {
            return MirrorTransport.notFoundResponse()
        }
        switch (request.method, request.path) {
        case ("GET", TeamNearby.keyPath):
            let reply = KeyReply(name: endpoint.local.record.name, keys: keys,
                                 team: endpoint.local.record.team, role: endpoint.local.record.role)
            guard let body = try? CanonicalJSON.encode(reply) else { return MirrorTransport.notFoundResponse() }
            return MirrorTransport.jsonResponse(body)
        case ("POST", TeamNearby.requestPath):
            guard let incoming = try? CanonicalJSON.decode(Request.self, from: request.body),
                  (try? incoming.request.verify(with: incoming.request.doc.keys)) != nil else {
                return MirrorTransport.badRequestResponse()
            }
            guard incoming.team == endpoint.local.record.team else { return MirrorTransport.notFoundResponse() }
            // Stream ruling: policy.requests == "off" refuses outright,
            // no storage at all — checked before the store is ever
            // called, not inside it.
            guard endpoint.local.requestsOpen else {
                return MirrorTransport.response(status: 403, reason: "Forbidden", contentType: "text/plain",
                                                body: Data("requests closed\n".utf8))
            }
            do {
                let stored = try endpoint.store(incoming)
                guard let body = try? CanonicalJSON.encode(RequestReply(ok: true, stored: stored)) else {
                    return MirrorTransport.notFoundResponse()
                }
                return MirrorTransport.jsonResponse(body)
            } catch {
                return MirrorTransport.response(status: 503, reason: "Service Unavailable", contentType: "text/plain",
                                                body: Data("request not stored\n".utf8))
            }
        case ("POST", TeamNearby.invitePath):
            // The peer that sealed this must be the peer the body names,
            // and it must have sealed it to ME: an invitation nobody here
            // can open is refused rather than parked on disk. The
            // envelope's signature is checked here too — it needs only
            // the sender's PUBLIC key, which the body carries, so a
            // forged envelope is refused now rather than overwriting the
            // genuine invitation under the same kid. Everything else
            // about it — team, expiry, leader signature over the CODE —
            // is checked when it is opened (`openInvite`), on the
            // identity that can actually read it.
            guard let invite = try? CanonicalJSON.decode(Invite.self, from: request.body),
                  Store.isPathSegment(invite.from.kid),
                  let header = try? Envelope.header(of: invite.envelope),
                  header.kind == "invite",
                  header.from == invite.from.kid,
                  header.to.contains(where: { $0.kid == keys.kid }),
                  Self.sealedBySender(invite) else {
                return MirrorTransport.badRequestResponse()
            }
            do {
                try endpoint.storeInvite(invite)
                guard let body = try? CanonicalJSON.encode(InviteReply(ok: true)) else {
                    return MirrorTransport.notFoundResponse()
                }
                return MirrorTransport.jsonResponse(body)
            } catch {
                return MirrorTransport.response(status: 503, reason: "Service Unavailable", contentType: "text/plain",
                                                body: Data("invite not stored\n".utf8))
            }
        default:
            return MirrorTransport.notFoundResponse()
        }
    }

    /// Verifies `invite.envelope`'s signature against `invite.from`,
    /// mirroring `Envelope.open`'s own check (Envelope.swift) but without
    /// decrypting anything — the signature covers header-without-sig ‖
    /// body and needs only the sender's public Ed25519 key, which the
    /// body carries.
    private static func sealedBySender(_ invite: Invite) -> Bool {
        guard let header = try? Envelope.header(of: invite.envelope),
              header.v == Envelope.version,
              let split = invite.envelope.firstIndex(of: UInt8(ascii: "\n")),
              let sig = header.sig.flatMap({ Data(base64Encoded: $0) }) else { return false }
        var unsignedHeader = header
        unsignedHeader.sig = nil
        guard let unsigned = try? CanonicalJSON.encode(unsignedHeader) else { return false }
        let body = invite.envelope[(split + 1)...]
        return (try? invite.from.signingKey().isValidSignature(sig, for: unsigned + body)) == true
    }

    // MARK: storage

    public enum StoreError: Error, Equatable {
        case unknownTeam, badKid, full
        /// `removeInvite` on an invitation that is already gone.
        case noInvite
        /// `openInvite`: the sealed code names a different leader or team
        /// than the `Invite` body claims (spec §10) — the display strings
        /// are attacker-chosen and prove nothing on their own.
        case mismatchedInvite
    }

    public enum Store {
        public static func pendingDir(team: String, paths: TeamPaths) -> URL {
            paths.teamDir(team).appendingPathComponent("pending")
        }

        /// A kid names one file, so it is one path segment.
        static func isPathSegment(_ kid: String) -> Bool {
            !kid.isEmpty && !kid.contains("/") && kid != "." && kid != ".."
        }

        /// Keeps the request under `<team>/pending/<kid>.json`, then tries
        /// the team's `requests` branch; on success the pending copy goes
        /// (the leader's `requests()` sees it there). "branch" | "pending".
        public static func save(_ incoming: Request, paths: TeamPaths, secrets: TeamSecrets) throws -> String {
            let kid = incoming.request.doc.keys.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            guard paths.teamIDs().contains(incoming.team) else { throw StoreError.unknownTeam }
            let dir = pendingDir(team: incoming.team, paths: paths)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(kid).json")
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard existing.count < TeamNearby.pendingCap || FileManager.default.fileExists(atPath: file.path) else {
                throw StoreError.full
            }
            try CanonicalJSON.encode(incoming.request).write(to: file)
            do {
                try writeToRequestsBranch(team: incoming.team, signed: incoming.request, paths: paths, secrets: secrets)
            } catch {
                return "pending"
            }
            try? FileManager.default.removeItem(at: file)
            return "branch"
        }

        /// Requests that never reached the branch, by kid; unreadable or
        /// unverifiable files are skipped.
        public static func pending(team: String, paths: TeamPaths) -> [Signed<TeamRequest>] {
            let dir = pendingDir(team: team, paths: paths)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return names.compactMap { name in
                guard name.hasSuffix(".json"),
                      let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let signed = try? CanonicalJSON.decode(Signed<TeamRequest>.self, from: data),
                      name == "\(signed.doc.keys.kid).json",
                      (try? signed.verify(with: signed.doc.keys)) != nil else { return nil }
                return signed
            }
        }

        /// Invitations sit BESIDE the team dirs, not inside one: the
        /// invitee usually has no team yet. `teamIDs()` only counts
        /// directories with a config, so this one is never mistaken for
        /// a team.
        public static func invitesDir(paths: TeamPaths) -> URL {
            paths.base.appendingPathComponent("invites")
        }

        /// An invitation nobody has come back for in this long is dead
        /// weight: it can only fail `TeamCode.decode`'s expiry check by
        /// then (invite links top out at spec §6.2's week-scale expiry),
        /// so `invites` drops it rather than keep showing it.
        static let maxInviteAge = 30 * 86_400

        /// The receiver's own clock for a saved invite file: its
        /// modification date, set by `saveInvite`'s write and untouched
        /// by anything the sender claims. Both eviction order and the
        /// 30-day prune key on this rather than the signed `Invite.at`
        /// (remaining finding A) — a sender that back/forward-dates `at`
        /// can neither dodge eviction as "not the oldest" nor survive the
        /// prune by claiming to be freshly sent.
        static func savedAt(_ file: URL) -> Int? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return Int(date.timeIntervalSince1970)
        }

        /// `<base>/invites/<from kid>.json`, the invitation exactly as it
        /// arrived — the envelope stays SEALED here. One file per sender,
        /// so a peer can refresh its own invitation but not flood. At the
        /// cap, a NEW sender evicts the oldest invitation (by the
        /// receiver's own clock, `savedAt`) rather than being refused —
        /// the cap protects disk, not a queue position, so a stranger
        /// filling every slot with fresh identities can no longer lock a
        /// genuine leader's invite out permanently.
        public static func saveInvite(_ invite: Invite, paths: TeamPaths) throws {
            let kid = invite.from.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            let dir = invitesDir(paths: paths)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(kid).json")
            let existing = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".json") }
            if existing.count >= TeamNearby.inviteCap, !FileManager.default.fileExists(atPath: file.path) {
                let oldest = existing.compactMap { name -> (name: String, at: Int)? in
                    let path = dir.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: path),
                          (try? CanonicalJSON.decode(Invite.self, from: data)) != nil,
                          let at = savedAt(path) else { return nil }
                    return (name, at)
                }.min { $0.at < $1.at }
                if let oldest { try? FileManager.default.removeItem(at: dir.appendingPathComponent(oldest.name)) }
            }
            try CanonicalJSON.encode(invite).write(to: file)
        }

        /// Unreadable or misnamed files are skipped, like `pending`; one
        /// older than `maxInviteAge` is deleted here too, so an
        /// invitation nobody acted on eventually frees its slot instead
        /// of sitting on the shelf forever. Ages by `savedAt` (the
        /// receiver's clock), not the signed `Invite.at` — a file whose
        /// `savedAt` can't be read is kept rather than guessed at.
        public static func invites(paths: TeamPaths, now: Int = Int(Date().timeIntervalSince1970)) -> [Invite] {
            let dir = invitesDir(paths: paths)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return names.compactMap { name in
                let path = dir.appendingPathComponent(name)
                guard name.hasSuffix(".json"),
                      let data = try? Data(contentsOf: path),
                      let invite = try? CanonicalJSON.decode(Invite.self, from: data),
                      name == "\(invite.from.kid).json" else { return nil }
                guard let at = savedAt(path) else { return invite }
                guard now - at < maxInviteAge else {
                    try? FileManager.default.removeItem(at: path)
                    return nil
                }
                return invite
            }
        }

        /// Accept and Ignore both end here. A missing file is `noInvite`,
        /// never a silent success — the phone shows "that invitation is
        /// gone" instead of a green tick over nothing.
        public static func removeInvite(from kid: String, paths: TeamPaths) throws {
            guard isPathSegment(kid) else { throw StoreError.badKid }
            let file = invitesDir(paths: paths).appendingPathComponent("\(kid).json")
            guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.noInvite }
            try FileManager.default.removeItem(at: file)
        }

        /// `requests/<kid>.json` on the team's store, with whatever
        /// credential this machine holds: the leader's when a request
        /// arrives over the LAN, the joiner's own when it already has the
        /// code. TeamClient keeps its store private, so this opens the
        /// same bare mirror TeamClient uses (`paths.storeDir`).
        public static func writeToRequestsBranch(team: String, signed: Signed<TeamRequest>,
                                                 paths: TeamPaths, secrets: TeamSecrets) throws {
            let kid = signed.doc.keys.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            let config = try CanonicalJSON.decode(TeamConfig.self, from: try Data(contentsOf: paths.configFile(team)))
            let token = secrets.read(TeamClient.tokenName(team)).map { String(decoding: $0, as: UTF8.self) }
            let store = TeamGit(dir: paths.storeDir(team), remote: config.remote, token: token, author: config.kid)
            try store.open()
            try store.put("requests/\(kid).json", try CanonicalJSON.encode(signed))
        }
    }

    /// Opens an invitation with this machine's identity (spec §6.4). The
    /// sender key is pinned to the `from` the body carried, so a stranger
    /// cannot pass its own envelope off as the leader's; `TeamCode.decode`
    /// then checks the leader's signature over the code and its expiry,
    /// which is what makes an opened invitation safe to join with. Neither
    /// of those checks binds the code to `invite.fromName`/`teamName`
    /// though — those are attacker-chosen display strings — so the
    /// decoded code's OWN leader and team are pinned here too: without
    /// this, a LAN stranger could mint a genuine code for their own team,
    /// seal it to a victim, and label the body with someone else's name
    /// ("Loc invites you to Papaya"). The TEXT comes back as sealed — the
    /// caller hands that to `TeamClient.request(code:…)` rather than
    /// re-encoding the code, which would need the leader's key to sign.
    public static func openInvite(_ invite: Invite, identity: TeamIdentity,
                                  now: Int = Int(Date().timeIntervalSince1970)) throws -> (text: String, code: TeamCode) {
        let (_, plaintext) = try Envelope.open(invite.envelope, as: identity,
                                               senderKey: { $0 == invite.from.kid ? invite.from : nil })
        let text = String(decoding: plaintext, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let code = try TeamCode.decode(text, now: now)
        guard code.leader.kid == invite.from.kid, code.name == invite.teamName else {
            throw StoreError.mismatchedInvite
        }
        return (text, code)
    }
}

extension TeamNearby {
    /// One discovered machine (spec §6.4): its TXT record and address.
    public struct Peer: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var host: String
        public var port: UInt16
        public var kid: String?
        public var team: String?
        public var role: String
        public var discoverable: Bool
        public var id: String { kid ?? host + ":" + String(port) }
        public init(name: String, host: String, port: UInt16, kid: String?, team: String?, role: String, discoverable: Bool) {
            self.name = name; self.host = host; self.port = port; self.kid = kid; self.team = team; self.role = role; self.discoverable = discoverable
        }
    }

    /// The joiner's side of §6.4, shared by the CLI and the Mac pane so
    /// the "is the peer who its TXT says" check lives once. HTTP is
    /// injected: the CLI blocks on URLSession, tests route into
    /// `respond`, and the pane runs on its own queue.
    public enum Client {
        public typealias HTTP = @Sendable (_ method: String, _ host: String, _ port: UInt16, _ path: String, _ body: Data?) throws -> (Int, Data)
        public enum ClientError: Error, Equatable { case notALeader, keyMismatch(Int), refused(Int), unavailable }
        public struct Outcome: Equatable, Sendable {
            public var team: String, leader: String, kid: String, stored: String
        }

        public static func browse(seconds: TimeInterval) throws -> [Peer] {
            #if os(macOS) || os(Linux)
            return try MDNS.browse(seconds: seconds).map { peer in
                let record = NearbyRecord(txtStrings: peer.txt) ?? .hidden
                let host = peer.ipv4 ?? String(peer.host.dropLast(peer.host.hasSuffix(".") ? 1 : 0))
                return Peer(name: record.discoverable ? record.name : peer.instance, host: host, port: peer.port,
                            kid: record.discoverable ? record.kid : nil, team: record.discoverable ? record.team : nil,
                            role: record.role, discoverable: record.discoverable)
            }
            #else
            // MDNS's sockets are macOS + Linux only (like TeamGit's Process).
            throw ClientError.unavailable
            #endif
        }

        /// `host[:port]` as typed (an IPv6 literal in brackets); the port
        /// defaults to the app's (#355).
        public static func parseAddress(_ text: String, defaultPort: UInt16 = MirrorTransport.defaultPort) -> (host: String, port: UInt16)? {
            var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
            if s.hasSuffix("/") { s.removeLast() }
            guard !s.isEmpty else { return nil }
            if s.hasPrefix("[") {
                guard let close = s.firstIndex(of: "]") else { return nil }
                let host = String(s[s.index(after: s.startIndex)..<close])
                let rest = s[s.index(after: close)...]
                if rest.isEmpty { return (host, defaultPort) }
                guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
                return (host, port)
            }
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 1 { return (s, defaultPort) }
            if parts.count > 2 { return (s, defaultPort) }   // a bare IPv6 literal
            guard let port = UInt16(parts[1]), !parts[0].isEmpty else { return nil }
            return (String(parts[0]), port)
        }

        /// The peer behind an address, for a network that doesn't pass
        /// Bonjour between machines (#355): `GET /team/key` says who is
        /// there and what they lead, the same record a browse would have
        /// carried. `keyMismatch` carries the status when nothing answers
        /// or the reply isn't a key.
        public static func peer(host: String, port: UInt16, http: HTTP) throws -> Peer {
            let (status, body) = try http("GET", host, port, keyPath, nil)
            guard status == 200, let reply = try? CanonicalJSON.decode(KeyReply.self, from: body) else {
                throw ClientError.keyMismatch(status)
            }
            return Peer(name: reply.name, host: host, port: port, kid: reply.keys.kid, team: reply.team,
                        role: reply.role, discoverable: true)
        }

        public static func request(to peer: Peer, name: String, devices: [String], platform: String,
                                   paths: TeamPaths, secrets: TeamSecrets, http: HTTP,
                                   now: Int = Int(Date().timeIntervalSince1970)) throws -> Outcome {
            guard peer.role == "leader", let team = peer.team, let kid = peer.kid else { throw ClientError.notALeader }
            let (keyStatus, keyBody) = try http("GET", peer.host, peer.port, keyPath, nil)
            guard keyStatus == 200,
                  let leaderKey = try? CanonicalJSON.decode(KeyReply.self, from: keyBody),
                  leaderKey.keys.kid == kid else { throw ClientError.keyMismatch(keyStatus) }
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            let signed = try Signed.make(TeamRequest(keys: me.keys, name: name, devices: devices, platform: platform, at: now), by: me)
            let body = try CanonicalJSON.encode(Request(team: team, request: signed))
            let (status, replyBody) = try http("POST", peer.host, peer.port, requestPath, body)
            guard status == 200, let reply = try? CanonicalJSON.decode(RequestReply.self, from: replyBody) else { throw ClientError.refused(status) }
            var stored = reply.stored
            if paths.teamIDs().contains(team) {
                try Store.writeToRequestsBranch(team: team, signed: signed, paths: paths, secrets: secrets)
                stored = "branch"
            }
            return Outcome(team: team, leader: kid, kid: me.kid, stored: stored)
        }

        public struct InviteOutcome: Equatable, Sendable {
            public var team: String, teamName: String, to: String, ok: Bool
        }

        /// The leader's half of §6.4: mint an invite link, seal it to the
        /// keys `GET /team/key` hands back — checked against the TXT kid
        /// exactly as `request` does, so a peer that lies about who it is
        /// never receives a credential — and POST it. Nothing but
        /// ciphertext crosses the LAN. `team` picks which team when this
        /// machine leads several; nil takes the first it leads.
        public static func invite(to peer: Peer, fromName: String, days: Int = 7, team: String? = nil,
                                  paths: TeamPaths, secrets: TeamSecrets, http: HTTP,
                                  now: Int = Int(Date().timeIntervalSince1970)) throws -> InviteOutcome {
            guard peer.discoverable, let peerKid = peer.kid else { throw ClientError.notALeader }
            var mine: TeamClient?
            for id in team.map({ [$0] }) ?? paths.teamIDs() {
                guard let candidate = try? TeamClient.open(id: id, paths: paths, secrets: secrets),
                      candidate.isLeader else { continue }
                mine = candidate
                break
            }
            guard let client = mine else { throw ClientError.notALeader }
            let (keyStatus, keyBody) = try http("GET", peer.host, peer.port, keyPath, nil)
            guard keyStatus == 200,
                  let reply = try? CanonicalJSON.decode(KeyReply.self, from: keyBody),
                  reply.keys.kid == peerKid else { throw ClientError.keyMismatch(keyStatus) }
            let teamDir = paths.teamDir(client.config.id)
            let (link, nonce) = try TeamInvites.mint(client: client, teamDir: teamDir, days: days, now: now)
            // `mint` already committed the nonce; anything from here on
            // that fails must drop it again, or a refused/unreachable
            // peer leaves a dangling nonce nobody will ever redeem. The
            // nonce comes straight back from `mint` rather than being
            // re-derived by decoding `link` — a `days <= 0` (or any other
            // future reason `decode` might refuse it) would otherwise
            // leave the nonce dangling with no signal (remaining finding C).
            do {
                let sealed = try Envelope.seal(Data(link.utf8), kind: "invite", from: client.identity,
                                               to: [reply.keys], at: now)
                let body = try CanonicalJSON.encode(Invite(from: client.identity.keys, fromName: fromName,
                                                           teamName: client.config.name, envelope: sealed))
                let (status, replyBody) = try http("POST", peer.host, peer.port, invitePath, body)
                guard status == 200,
                      let sent = try? CanonicalJSON.decode(InviteReply.self, from: replyBody), sent.ok else {
                    throw ClientError.refused(status)
                }
            } catch {
                TeamInvites.drop(nonce: nonce, teamDir: teamDir)
                throw error
            }
            return InviteOutcome(team: client.config.id, teamName: client.config.name, to: peerKid, ok: true)
        }
    }
}
