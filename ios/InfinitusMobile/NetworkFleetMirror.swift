import CryptoKit
import Foundation
import Network
import UIKit
import InfinitusCore

/// The LAN transport (#9): finds the Mac's `_infinitus._tcp`
/// advertisement and fetches `GET /snapshot` over it. A free personal
/// team means no CloudKit, so the phone reads the fleet the same way it
/// would read a file — just over Wi-Fi, and only while on the same
/// network as the Mac.
///
/// One shared instance: MirrorModel and MobileUsage both pull snapshots,
/// and two browsers scanning for the same service would be waste.
actor NetworkFleetMirror: FleetMirror {
    static let shared = NetworkFleetMirror()

    /// Every endpoint a QR or the Settings field has ever added (#9 pair
    /// once, every route) — read fresh every fetch so a Settings edit
    /// takes effect at once. Replaces the old single `mirror_manual_endpoint`
    /// string (migrated below).
    static let manualKey = "mirror_manual_endpoints"
    /// The old single-endpoint key, migrated into `manualKey` once.
    static let legacyManualKey = "mirror_manual_endpoint"
    /// Whichever endpoint last answered — tried first next time, so a
    /// dead tunnel URL from a restarted Mac doesn't cost a timeout on
    /// every single refresh.
    static let lastGoodKey = "mirror_last_good_endpoint"
    /// The pairing token (#9 remote access) — every request carries it,
    /// Bonjour-discovered Macs included.
    static let tokenKey = "mirror_pair_token"
    /// #168: the primary Mac's identity for what the phone keeps on disk —
    /// twelve hex of the pairing token's hash, so a token never lands in a
    /// file name; "local" before the first pairing.
    nonisolated static func parkedKey(defaults: UserDefaults = .standard) -> String {
        let token = MirrorPairing.normalize(defaults.string(forKey: tokenKey) ?? "")
        guard !token.isEmpty else { return "local" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static var parkedCache: ParkedCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ParkedCache(root: support.appendingPathComponent("parked").appendingPathComponent(parkedKey()))
    }

    /// True when the last `latest()` answered from the cache because no
    /// route reached the Mac — the phone is "parked".
    private(set) var lastServedFromCache = false
    /// How the Mac's "Connected devices" list tells phones apart: a
    /// per-install id, minted once, plus the device's name.
    static let deviceIdKey = "mirror_device_id"
    static let deviceId: String = {
        if let stored = UserDefaults.standard.string(forKey: deviceIdKey), !stored.isEmpty { return stored }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: deviceIdKey)
        return fresh
    }()
    static let deviceName: String = {
        if let bridged = UserDefaults.standard.string(forKey: ShareBridge.deviceNameKey),
           !bridged.isEmpty { return bridged }
        let name = UIDevice.current.name.filter { $0.isASCII && !$0.isNewline }
        return name.isEmpty ? UIDevice.current.model : name
    }()
    /// Per-candidate connect timeout: several stored endpoints may be
    /// dead (a Mac off, a tunnel gone), so trying them all still has to
    /// land well inside one refresh.
    static let candidateTimeout: TimeInterval = 3

    /// One line for the Settings screen.
    private(set) var statusText = "looking for a Mac on this Wi-Fi…"

    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    /// The last snapshot that arrived — a dropped Wi-Fi then shows the
    /// staleness banner instead of falling back to "Waiting for the fleet".
    private var cached: MirrorSnapshot?

    /// Where this instance reads its endpoints/token and writes its
    /// last-good route (#144 phase 1). `.shared` keeps reading the plain
    /// UserDefaults keys; a per-Mac instance carries its own `MacPairing`
    /// instead — `var` so a successful fetch's last-good write (via
    /// `onLastGood`) is reflected the next time `candidateEndpoints()`
    /// runs on this same cached actor.
    private enum Storage {
        case defaults
        case pairing(MacPairing)

        var isDefaults: Bool { if case .defaults = self { return true } else { return false } }
    }
    private var storage: Storage
    /// Persists a per-Mac pairing's last-good endpoint (MirrorModel keeps
    /// the `MacPairing` list in UserDefaults); unused for `.shared`.
    private let onLastGood: (@Sendable (String) -> Void)?
    /// #168: disk cache for the primary Mac. `ParkedCache` keeps an
    /// in-memory "last saved" marker, so this actor holds ONE instance;
    /// other Macs stay read-only in phase 1 (`nil`). `var` so
    /// `forgetCached()` can re-resolve it against a new pairing token.
    private var parked: ParkedCache?

    init() {
        storage = .defaults
        onLastGood = nil
        parked = Self.parkedCache
        cached = parked?.loadSnapshot()
    }

    /// One OTHER paired Mac (#144 phase 1): its own endpoints and token,
    /// Bonjour skipped (it can't yet tell which Mac answered), and a
    /// successful route reported back so the caller can persist it.
    init(pairing: MacPairing, onLastGood: (@Sendable (String) -> Void)? = nil) {
        storage = .pairing(pairing)
        self.onLastGood = onLastGood
        parked = nil
        // The default line above is about Bonjour, which this instance
        // never uses — the Settings caption would otherwise say so
        // before the first fetch even runs.
        statusText = "not reached yet"
    }

    /// Drops the cached snapshot and resets the status line — used when
    /// the PAIRING itself changes underneath this instance (#144 phase
    /// 1's "make primary"), so a `latest()` that fails right after a
    /// swap doesn't quietly keep showing the previous Mac's fleet.
    func forgetCached() {
        cached = nil
        parked?.clear()
        // The primary just changed underneath this instance — `parkedKey()`
        // now hashes a different token, so the cache must move with it.
        parked = Self.parkedCache
        lastServedFromCache = false
        statusText = "looking for a Mac on this Wi-Fi…"
    }

    /// The token this instance authenticates with.
    private func pairToken() -> String {
        switch storage {
        case .defaults: return MirrorPairing.normalize(UserDefaults.standard.string(forKey: Self.tokenKey) ?? "")
        case .pairing(let pairing): return MirrorPairing.normalize(pairing.token)
        }
    }

    /// Records the endpoint that just answered as the one to try first
    /// next time.
    private func recordLastGood(_ text: String) {
        switch storage {
        case .defaults:
            UserDefaults.standard.set(text, forKey: Self.lastGoodKey)
        case .pairing(let pairing):
            var updated = pairing
            updated.lastGood = text
            storage = .pairing(updated)
            onLastGood?(text)
        }
    }

    /// Migrates the old single-endpoint string into the list, once. Both
    /// this actor and `MirrorModel` read defaults independently, so they
    /// share this one entry point rather than each rolling its own.
    static func migrateManualEndpointIfNeeded(_ defaults: UserDefaults = .standard) {
        guard let old = defaults.string(forKey: legacyManualKey), !old.isEmpty else { return }
        if ((defaults.array(forKey: manualKey) as? [String]) ?? []).isEmpty {
            defaults.set([old], forKey: manualKey)
        }
        defaults.removeObject(forKey: legacyManualKey)
    }

    /// The stored endpoint list, in the order the user (or a pairing QR)
    /// added them — migrating the legacy key first.
    static func storedEndpoints(_ defaults: UserDefaults = .standard) -> [String] {
        migrateManualEndpointIfNeeded(defaults)
        return (defaults.array(forKey: manualKey) as? [String]) ?? []
    }

    /// Stored endpoints with the last-successful one moved to the front —
    /// the order candidates are tried in, so a Mac that answered last
    /// time answers first this time.
    private func candidateEndpoints() -> [String] {
        var list: [String]
        var lastGood: String?
        switch storage {
        case .defaults:
            list = Self.storedEndpoints()
            lastGood = UserDefaults.standard.string(forKey: Self.lastGoodKey)
        case .pairing(let pairing):
            list = pairing.endpoints
            lastGood = pairing.lastGood
        }
        if let lastGood, let index = list.firstIndex(of: lastGood), index != 0 {
            list.remove(at: index)
            list.insert(lastGood, at: 0)
        }
        return list
    }

    func latest() async throws -> MirrorSnapshot? {
        let token = pairToken()
        let stored = candidateEndpoints()
        var lastError: Error?
        // One short clause per route that failed, so the Settings line
        // says WHICH way in is dead — "offline" alone sent the user
        // rescanning when only the tunnel had changed.
        var failures: [String] = []
        for text in stored {
            guard let manual = MirrorTransport.parseEndpoint(text) else { continue }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            do {
                let (data, _) = try await fetch(endpoint, path: MirrorTransport.snapshotPath,
                                                hostHeader: manual.host,
                                                useTLS: manual.useTLS, token: token,
                                                timeout: Self.candidateTimeout)
                let snapshot = try Self.decode(data)
                cached = snapshot
                try? parked?.saveSnapshot(snapshot)
                lastServedFromCache = false
                recordLastGood(text)
                statusText = "\(snapshot.machineName) at \(text)"
                return snapshot
            } catch MirrorTransportError.http(401) {
                // The Mac is right there and refusing us: that's a pairing
                // problem, not a network one, and the fix is one field
                // away — stop trying the rest, they'd only repeat it.
                // Not parked: the Mac answered.
                lastServedFromCache = false
                statusText = "pairing token required — scan the QR in the Mac's "
                    + "Devices settings"
                return cached
            } catch {
                lastError = error
                failures.append("\(Self.routeLabel(text)) \(Self.failureWord(error))")
            }
        }
        // Every saved route is dead. If one of them was a quick-tunnel
        // URL, the Mac may simply have restarted onto a new one and
        // published it to the rendezvous (MirrorRendezvous) — swap it in
        // and try once more before giving up. Not for a per-Mac pairing:
        // `Self.manualKey` is the PRIMARY's list, and writing into it here
        // would overwrite it with another Mac's address.
        if storage.isDefaults, let stale = stored.first(where: MirrorRendezvous.isEphemeral),
           let fresh = await rendezvousLookup(token: token), fresh != stale,
           let manual = MirrorTransport.parseEndpoint(fresh) {
            var list = Self.storedEndpoints()
            list = list.map { $0 == stale ? fresh : $0 }
            UserDefaults.standard.set(list, forKey: Self.manualKey)
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            if let (data, _) = try? await fetch(endpoint, path: MirrorTransport.snapshotPath,
                                                hostHeader: manual.host, useTLS: manual.useTLS,
                                                token: token, timeout: Self.candidateTimeout),
               let snapshot = try? Self.decode(data) {
                cached = snapshot
                try? parked?.saveSnapshot(snapshot)
                lastServedFromCache = false
                recordLastGood(fresh)
                statusText = "\(snapshot.machineName) at \(fresh) (new tunnel address)"
                return snapshot
            }
            failures.append("new tunnel address didn't answer either")
        }
        // No stored endpoint answered (or none is stored) — Bonjour is
        // the last resort, worth trying while on the LAN, for the
        // primary only: it can't yet tell which of several Macs answered
        // (#144 phase 1), so a per-Mac pairing stops here.
        guard storage.isDefaults else {
            statusText = stored.isEmpty
                ? "no address saved for this Mac"
                : "couldn't reach it — " + failures.joined(separator: " · ")
            if cached == nil, let lastError, lastError is DecodingError { throw lastError }
            lastServedFromCache = cached != nil
            return cached
        }
        startBrowsing()
        guard let discovered = await firstEndpoint() else {
            statusText = stored.isEmpty
                ? "no Mac found on this Wi-Fi"
                : "couldn't reach any saved Mac — " + failures.joined(separator: " · ")
            if cached == nil, let lastError, lastError is DecodingError { throw lastError }
            lastServedFromCache = cached != nil
            return cached
        }
        do {
            let (data, remote) = try await fetch(discovered, path: MirrorTransport.snapshotPath,
                                                 hostHeader: "infinitus",
                                                 useTLS: false, token: token,
                                                 timeout: Self.candidateTimeout)
            let snapshot = try Self.decode(data)
            cached = snapshot
            try? parked?.saveSnapshot(snapshot)
            lastServedFromCache = false
            statusText = "\(snapshot.machineName) at \(remote)"
            return snapshot
        } catch MirrorTransportError.http(401) {
            // Not parked: the Mac answered.
            lastServedFromCache = false
            statusText = "pairing token required — scan the QR in the Mac's "
                + "Devices settings"
            return cached
        } catch {
            failures.append("Wi-Fi discovery \(Self.failureWord(error))")
            statusText = (cached == nil ? "couldn't reach the Mac — " : "offline — ")
                + failures.joined(separator: " · ")
            // A decode failure is a real error; a network one just means
            // the Mac stepped away, and the cached fleet stays on screen.
            if cached == nil, error is DecodingError { throw error }
            lastServedFromCache = cached != nil
            return cached
        }
    }

    /// The Mac's past sessions (#164): `GET /sessions/past?limit=&q=`,
    /// same stored-endpoint → discovery path as the plain feed fetch.
    func pastSessions(limit: Int = 50, search: String? = nil) async throws -> PastSessions.Reply {
        let token = pairToken()
        var path = PastSessions.path + "?\(PastSessions.limitQueryName)=\(limit)"
        if let search, !search.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            path += "&\(PastSessions.searchQueryName)="
                + (search.addingPercentEncoding(withAllowedCharacters: allowed) ?? search)
        }
        let data: Data
        if let stored = try await fetchFromStored(path: path, token: token, timeout: Self.candidateTimeout) {
            data = stored
        } else {
            startBrowsing()
            guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
            (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: Self.candidateTimeout)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PastSessions.Reply.self, from: data)
    }

    /// A session's checkpoint timeline (#167 phase 2): `GET /sessions/<pid>/checkpoints`.
    func checkpoints(pid: Int32) async throws -> Checkpoints.Reply {
        try await getJSON(MirrorTransport.sessionCheckpointsPath(pid: pid), dates: true)
    }

    /// One checkpoint against another (`to`) or the working tree now.
    func checkpointDiff(pid: Int32, n: Int, to: Int? = nil) async throws -> Checkpoints.Diff {
        var path = MirrorTransport.sessionCheckpointPath(pid: pid, n: n, action: .diff)
        if let to { path += "?\(MirrorTransport.checkpointToQueryName)=\(to)" }
        return try await getJSON(path)
    }

    /// Rewrites the session's folder to checkpoint `n` on the Mac (the
    /// state before is checkpointed first, so this is undoable there).
    func restoreCheckpoint(pid: Int32, n: Int) async throws -> Checkpoints.RestoreReply {
        try await postJSON(MirrorTransport.sessionCheckpointPath(pid: pid, n: n, action: .restore),
                           body: [String: String](), timeout: Self.attachmentInputTimeout)
    }

    /// A plain GET decoded as JSON: the stored endpoint first, discovery
    /// as the fallback — the `pastSessions` path, generalised.
    /// Star/unstar, pause/resume one account of the primary Mac
    /// (`POST /accounts/action`); the Mac runs the popup's own guards.
    func accountAction(_ request: AccountAction.Request) async throws -> AccountAction.Reply {
        try await postJSON(AccountAction.path, body: request)
    }

    private func getJSON<R: Decodable>(_ path: String, dates: Bool = false) async throws -> R {
        let token = pairToken()
        let data: Data
        if let stored = try await fetchFromStored(path: path, token: token, timeout: Self.candidateTimeout) {
            data = stored
        } else {
            startBrowsing()
            guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
            (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: Self.candidateTimeout)
        }
        let decoder = JSONDecoder()
        if dates { decoder.dateDecodingStrategy = .iso8601 }
        return try decoder.decode(R.self, from: data)
    }

    /// The session feed (#17 layer 1): same candidate/token/Host picking
    /// logic as `latest()`, factored into `fetchFromStored` so both share
    /// it — no snapshot-style caching here, a failed fetch just throws.
    /// `since`/`wait` make it a long-poll (#17): the Mac holds the reply
    /// until the transcript changes or `wait` seconds pass. A long-poll
    /// goes to the route that last answered only, with a timeout past
    /// `wait` — falling through routes with a 30 s timeout each would be
    /// a minute of nothing; the caller retries the plain form on failure.
    func sessionTail(pid: Int32, limit: Int, since: String? = nil,
                     wait: TimeInterval = 0) async throws -> SessionFeed {
        let token = pairToken()
        var path = MirrorTransport.sessionTailPath(pid: pid) + "?n=\(limit)"
        if let since, wait > 0 {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            path += "&\(MirrorTransport.tailSinceQueryName)="
                + (since.addingPercentEncoding(withAllowedCharacters: allowed) ?? since)
                + "&\(MirrorTransport.tailWaitQueryName)=\(Int(wait))"
            guard let text = candidateEndpoints().first,
                  let manual = MirrorTransport.parseEndpoint(text) else {
                throw MirrorTransportError.timedOut
            }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            let (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                            useTLS: manual.useTLS, token: token,
                                            timeout: wait + 10)
            let feed = try Self.decodeFeed(data)
            try? parked?.saveTail(feed, pid: pid)
            return feed
        }
        if let data = try await fetchFromStored(path: path, token: token, timeout: Self.candidateTimeout) {
            let feed = try Self.decodeFeed(data)
            try? parked?.saveTail(feed, pid: pid)
            return feed
        }
        startBrowsing()
        guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
        let (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: Self.candidateTimeout)
        let feed = try Self.decodeFeed(data)
        try? parked?.saveTail(feed, pid: pid)
        return feed
    }

    /// #168: the last tail fetched for this session, from disk — read
    /// while parked so a transcript stays scrollable with no route to
    /// the Mac.
    func parkedTail(pid: Int32) -> SessionFeed? { parked?.loadTail(pid: pid) }

    /// A feed image's thumbnail (`SessionFeedItem.images`, 2026-09-04):
    /// the bytes, since AsyncImage can't carry the pairing token. Same
    /// stored-endpoint → discovery path as the plain feed fetch.
    func sessionImage(pid: Int32, id: String) async throws -> Data {
        let token = pairToken()
        let path = MirrorTransport.sessionImagePath(pid: pid, id: id)
        if let data = try await fetchFromStored(path: path, token: token, timeout: Self.candidateTimeout) {
            return data
        }
        startBrowsing()
        guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
        let (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: Self.candidateTimeout)
        return data
    }

    /// Tries every stored endpoint (last-good first), same as `latest()`'s
    /// own loop — `nil` means none of them answered for network reasons;
    /// a bad pairing token still throws, since that's equally actionable
    /// for either caller.
    private func fetchFromStored(path: String, token: String, timeout: TimeInterval,
                                 method: String = "GET", body: Data? = nil) async throws -> Data? {
        for text in candidateEndpoints() {
            guard let manual = MirrorTransport.parseEndpoint(text) else { continue }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            do {
                let (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                                useTLS: manual.useTLS, token: token, timeout: timeout,
                                                method: method, body: body)
                recordLastGood(text)
                return data
            } catch MirrorTransportError.http(401) {
                throw MirrorTransportError.http(401)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Layer 2 of #17: posts a reply or a key press into a session's
    /// terminal. Same candidate/token/discovery path as `sessionTail`;
    /// unlike the feed, a Mac that's simply offline has nothing sensible
    /// to fall back to, so every failure throws.
    /// A POST is not idempotent: typing into a terminal twice is two
    /// messages. So unlike the GETs this never falls through to another
    /// stored route — it goes to the endpoint that last answered (the one
    /// the feed on screen came from) with a timeout long enough for the
    /// Mac's settle sleeps, and a failure is reported, not retried.
    static let inputTimeout: TimeInterval = 15
    /// Attachments push the body into the megabytes and the Mac writes
    /// each one to disk before delivering — longer than a bare keystroke
    /// or text line needs (2026-09-03 "add features to allow attachments").
    static let attachmentInputTimeout: TimeInterval = 60

    func sessionInput(pid: Int32, request: SessionInput.Request) async throws -> SessionInput.Reply {
        // #168: a retried delivery needs its own id for the Mac's dedup —
        // give every hand-typed send one too, so a timeout-then-retry from
        // the composer is never mistaken for the same request twice.
        let request = request.requestId == nil
            ? SessionInput.Request(kind: request.kind, text: request.text, attachments: request.attachments,
                                   requestId: UUID().uuidString, queuedAt: request.queuedAt, sessionId: request.sessionId)
            : request
        let timeout = (request.attachments?.isEmpty == false) ? Self.attachmentInputTimeout : Self.inputTimeout
        let token = pairToken()
        let path = MirrorTransport.sessionInputPath(pid: pid)
        let body = try JSONEncoder().encode(request)
        let data: Data
        if let text = candidateEndpoints().first, let manual = MirrorTransport.parseEndpoint(text) {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                        useTLS: manual.useTLS, token: token,
                                        timeout: timeout, method: "POST", body: body)
        } else {
            startBrowsing()
            guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
            (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: timeout,
                                        method: "POST", body: body)
        }
        return try JSONDecoder().decode(SessionInput.Reply.self, from: data)
    }

    /// AWS sign-in from the phone: start (idempotent — returns the
    /// in-flight state, so it doubles as the poll), the intercepted
    /// relay callback, or the paste-back code. Same route as replies.
    /// A new session on the Mac (#91): opens a terminal there and waits
    /// for the session to register, so this takes seconds.
    func startSession(_ request: SessionStart.Request) async throws -> SessionStart.Reply {
        try await postJSON(SessionStart.path, body: request, timeout: Self.attachmentInputTimeout)
    }

    /// Triggers this Mac's own update (#121) — the reply comes back as
    /// soon as the Mac has decided/kicked off `brew upgrade`, not once
    /// it's done.
    func updateMac() async throws -> AppUpdate.Reply {
        try await postJSON(MirrorTransport.appUpdatePath, body: [String: String]())
    }

    func awsLoginStart(_ request: AwsLogin.StartRequest) async throws -> AwsLogin.Reply {
        try await postJSON(AwsLogin.startPath, body: request)
    }
    func awsLoginCallback(_ request: AwsLogin.CallbackRequest) async throws -> AwsLogin.Reply {
        try await postJSON(AwsLogin.callbackPath, body: request)
    }
    func awsLoginCode(_ request: AwsLogin.CodeRequest) async throws -> AwsLogin.Reply {
        try await postJSON(AwsLogin.codePath, body: request)
    }

    // MARK: team (spec §9 step 8) — `/mirror/team/*`, token-gated like everything else

    private func teamGet<R: Decodable>(_ path: String, timeout: TimeInterval = NetworkFleetMirror.candidateTimeout) async throws -> R {
        let token = pairToken()
        let data: Data
        if let stored = try await fetchFromStored(path: path, token: token, timeout: timeout) {
            data = stored
        } else {
            startBrowsing()
            guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
            (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: timeout)
        }
        return try JSONDecoder().decode(R.self, from: data)
    }

    func teamAggregates() async throws -> [String: TeamDocs.Aggregates] { try await teamGet(TeamMirror.aggregatesPath) }
    func teamMember(kid: String, period: Stats.Period) async throws -> TeamMirror.MemberReply {
        try await teamGet(TeamMirror.memberPath + "?" + TeamMirror.memberQuery(kid: kid, period: period))
    }
    // Queues behind the team's serial git queue (a sync pass mid-push holds
    // this for as long as git does), so it gets a git-scale timeout like
    // join/code rather than the input-echo default the other GETs use.
    func teamTranscript(kid: String, session: String) async throws -> [SessionFeedItem] {
        try await teamGet(TeamMirror.transcriptPath + "?" + TeamMirror.transcriptQuery(kid: kid, session: session),
                          timeout: 30)
    }
    // approve/decline do a git fetch + push (with a re-fetch/retry loop) on
    // the Mac, same as join/code: 60 s, not the input timeout.
    func teamApprove(kid: String) async throws -> TeamMirror.ActionReply { try await postJSON(TeamMirror.approvePath, body: TeamMirror.KidRequest(kid: kid), timeout: 60) }
    func teamDecline(kid: String) async throws -> TeamMirror.ActionReply { try await postJSON(TeamMirror.declinePath, body: TeamMirror.KidRequest(kid: kid), timeout: 60) }
    func teamJoin(code: String, name: String) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.joinPath, body: TeamMirror.JoinRequest(code: code, name: name), timeout: 60)
    }
    func teamCode(days: Int, invite: Bool) async throws -> TeamMirror.ActionReply {
        try await postJSON(TeamMirror.codePath, body: TeamMirror.CodeRequest(days: days, invite: invite), timeout: 60)
    }

    private func postJSON<B: Encodable, R: Decodable>(_ path: String, body: B,
                                                      timeout: TimeInterval = NetworkFleetMirror.inputTimeout) async throws -> R {
        let token = pairToken()
        let payload = try JSONEncoder().encode(body)
        let data: Data
        if let text = candidateEndpoints().first, let manual = MirrorTransport.parseEndpoint(text) {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                        useTLS: manual.useTLS, token: token,
                                        timeout: timeout, method: "POST", body: payload)
        } else {
            startBrowsing()
            guard let discovered = await firstEndpoint() else { throw MirrorTransportError.timedOut }
            (data, _) = try await fetch(discovered, path: path, hostHeader: "infinitus",
                                        useTLS: false, token: token, timeout: timeout,
                                        method: "POST", body: payload)
        }
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// A crash/hang report to the Mac (`POST /crashes`). Best effort:
    /// false when no Mac answered — the spool retries at the next launch.
    func postCrash(_ report: CrashReport) async -> Bool {
        let token = pairToken()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(report),
              let text = candidateEndpoints().first,
              let manual = MirrorTransport.parseEndpoint(text) else { return false }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(manual.host),
            port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
        do {
            _ = try await fetch(endpoint, path: MirrorTransport.crashesPath, hostHeader: manual.host,
                                useTLS: manual.useTLS, token: token, timeout: Self.attachmentInputTimeout,
                                method: "POST", body: body)
            return true
        } catch {
            return false
        }
    }

    /// Hands a Live Activity push token to the Mac (`POST
    /// /activities/token`) so its APNs pusher can reach this phone.
    /// Best effort: false when no Mac answered — the next token update
    /// or app launch tries again.
    func registerActivityToken(_ registration: ActivityPushRegistration) async -> Bool {
        let token = pairToken()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(registration),
              let text = candidateEndpoints().first,
              let manual = MirrorTransport.parseEndpoint(text) else { return false }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(manual.host),
            port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
        do {
            _ = try await fetch(endpoint, path: MirrorTransport.activityTokenPath, hostHeader: manual.host,
                                useTLS: manual.useTLS, token: token, timeout: Self.inputTimeout,
                                method: "POST", body: body)
            return true
        } catch {
            return false
        }
    }

    /// `192.168.2.36:47824` / `abc.trycloudflare.com` — the stored text
    /// without its scheme, short enough for one status line.
    private static func routeLabel(_ text: String) -> String {
        guard let manual = MirrorTransport.parseEndpoint(text) else { return text }
        let standardPort = manual.useTLS ? manual.port == 443 : manual.port == 80
        return standardPort ? manual.host : "\(manual.host):\(manual.port)"
    }

    private static func failureWord(_ error: Error) -> String {
        switch error {
        case MirrorTransportError.http(let status): return "answered \(status)"
        case MirrorTransportError.timedOut, MirrorTransportError.closed: return "didn't answer"
        case is DecodingError: return "sent something unreadable"
        default: return "unreachable"
        }
    }

    private static func decode(_ data: Data) throws -> MirrorSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MirrorSnapshot.self, from: data)
    }

    private static func decodeFeed(_ data: Data) throws -> SessionFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFeed.self, from: data)
    }

    // MARK: - Discovery

    private func startBrowsing() {
        // A per-Mac pairing skips Bonjour entirely (#144 phase 1) — it
        // can't yet tell which of several advertising Macs answered.
        guard storage.isDefaults, browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: MirrorTransport.bonjourType, domain: nil),
            using: params)
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.map(\.endpoint)
            Task { await self.apply(endpoints: found) }
        }
        browser.stateUpdateHandler = { state in
            guard case .failed(let error) = state else { return }
            Task { await self.browseFailed(error) }
        }
        self.browser = browser
        browser.start(queue: .global(qos: .utility))
    }

    private func apply(endpoints: [NWEndpoint]) {
        self.endpoints = endpoints
    }

    private func browseFailed(_ error: NWError) {
        browser?.cancel()
        browser = nil
        statusText = "discovery failed: \(error.localizedDescription)"
    }

    /// Discovery takes a moment; without a short wait the very first
    /// refresh would come up empty and the screen would sit on its empty
    /// state for a whole 10s poll.
    private func firstEndpoint(timeout: TimeInterval = 2) async -> NWEndpoint? {
        guard storage.isDefaults else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while endpoints.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return endpoints.first
    }

    // MARK: - Fetch

    /// Returns the response body and the resolved `host:port` it came
    /// from (the Bonjour endpoint alone never names a port). `method`/
    /// `body` default to a plain `GET` (#17 layer 2's `POST
    /// /sessions/<pid>/input` is the only other caller).
    /// GET the rendezvous entry for this token — the quick-tunnel URL the
    /// Mac last published, or nil (unpublished, expired, offline).
    private func rendezvousLookup(token: String) async -> String? {
        guard let url = MirrorRendezvous.url(token: token) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return MirrorRendezvous.parseLookup(data)
    }

    private func fetch(_ endpoint: NWEndpoint, path: String, hostHeader: String, useTLS: Bool,
                       token: String, timeout: TimeInterval = 5,
                       method: String = "GET", body: Data? = nil) async throws -> (Data, String) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        // A quick tunnel answers on 443 with a real certificate; the LAN
        // and tailnet paths stay plain TCP.
        let params = useTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "run.infinitus.mobile.mirror")
        let once = ContinuationOnce()
        return try await withCheckedThrowingContinuation { continuation in
            once.attach(continuation) { connection.cancel() }
            // Belt and braces: a half-open TCP connection can otherwise
            // hang past the connect timeout with no bytes ever arriving.
            queue.asyncAfter(deadline: .now() + timeout + 2) {
                once.finish(.failure(MirrorTransportError.timedOut))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint
                        .map(String.init(describing:)) ?? String(describing: endpoint)
                    var head = "\(method) \(path) HTTP/1.1\r\n"
                        + "Host: \(hostHeader)\r\n"
                        + "Authorization: Bearer \(token)\r\n"
                        + "\(MirrorClient.idHeader): \(Self.deviceId)\r\n"
                        + "\(MirrorClient.nameHeader): \(Self.deviceName)\r\n"
                    if let body {
                        head += "Content-Type: application/json\r\n"
                        head += "Content-Length: \(body.count)\r\n"
                    }
                    head += "Connection: close\r\n\r\n"
                    var request = Data(head.utf8)
                    if let body { request.append(body) }
                    connection.send(content: request,
                                    completion: .contentProcessed { error in
                        if let error { once.finish(.failure(error)) }
                    })
                    Self.receive(connection, buffer: Data(), remote: remote, once: once)
                case .failed(let error):
                    once.finish(.failure(error))
                case .cancelled:
                    once.finish(.failure(MirrorTransportError.closed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func receive(_ connection: NWConnection, buffer: Data,
                                remote: String, once: ContinuationOnce) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let response = MirrorTransport.parseResponse(buffer) {
                guard response.status == 200 else {
                    once.finish(.failure(MirrorTransportError.http(response.status)))
                    return
                }
                once.finish(.success((response.body, remote)))
                return
            }
            if let error {
                once.finish(.failure(error))
                return
            }
            guard !isComplete else {
                once.finish(.failure(MirrorTransportError.closed))
                return
            }
            receive(connection, buffer: buffer, remote: remote, once: once)
        }
    }
}

enum MirrorTransportError: LocalizedError {
    case http(Int)
    case closed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .http(let status): return "the Mac answered \(status)"
        case .closed: return "the Mac closed the connection"
        case .timedOut: return "the Mac didn't answer"
        }
    }
}

/// Resumes a checked continuation exactly once, from whichever network
/// callback gets there first, and tears the connection down after.
private final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, String), Error>?
    private var cleanup: (() -> Void)?

    func attach(_ continuation: CheckedContinuation<(Data, String), Error>,
                cleanup: @escaping () -> Void) {
        lock.lock()
        self.continuation = continuation
        self.cleanup = cleanup
        lock.unlock()
    }

    func finish(_ result: Result<(Data, String), Error>) {
        lock.lock()
        let continuation = self.continuation
        let cleanup = self.cleanup
        self.continuation = nil
        self.cleanup = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
        cleanup?()
    }
}

/// Tries each mirror in turn and takes the first snapshot anyone has —
/// LAN first, the Documents copy as the offline fallback (#9).
struct ChainFleetMirror: FleetMirror {
    let mirrors: [FleetMirror]

    func latest() async throws -> MirrorSnapshot? {
        var firstError: Error?
        for mirror in mirrors {
            do {
                if let snapshot = try await mirror.latest() { return snapshot }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return nil
    }
}
