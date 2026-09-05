import Foundation
import Network
import UIKit
import InfinitusCore

/// The LAN transport (#9), one record per machine since the windows
/// plan: fetches `GET /snapshot` from every paired host at once and
/// attributes each answer to the host that produced it. A host is its
/// stored `host:port`/tunnel list plus token, with `_infinitus._tcp`
/// discovery as the fallback — its own token decides which advertiser is
/// which machine, so a second paired host can't be mistaken for the
/// first.
///
/// One shared instance: MirrorModel and MobileUsage both pull snapshots,
/// and two browsers scanning for the same service would be waste.
actor NetworkFleetMirror: FleetMirror {
    static let shared = NetworkFleetMirror()

    // The pre-multi-host keys. MirrorHostStore's migration reads them
    // once into host #0; afterwards they're dead — left in place so a
    // rollback still boots, never read or written again.
    /// The single host's route list (#9 pair once, every route).
    static let manualKey = "mirror_manual_endpoints"
    /// The old single-endpoint key, migrated into `manualKey` once.
    static let legacyManualKey = "mirror_manual_endpoint"
    /// Whichever endpoint last answered — one per host now
    /// (`MirrorHost.lastGood`); this key only feeds the migration.
    static let lastGoodKey = "mirror_last_good_endpoint"
    /// The single host's pairing token (#9 remote access).
    static let tokenKey = "mirror_pair_token"
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

    /// One Settings line per host — with two machines up, "offline" has
    /// to say which one.
    private(set) var statuses: [String: String] = [:]

    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []

    /// Migrates the old single-endpoint string into the list, once. The
    /// host migration (`MirrorHostStore`) runs after it, so the Mac's
    /// route list is whole when it becomes host #0's.
    static func migrateManualEndpointIfNeeded(_ defaults: UserDefaults = .standard) {
        guard let old = defaults.string(forKey: legacyManualKey), !old.isEmpty else { return }
        if ((defaults.array(forKey: manualKey) as? [String]) ?? []).isEmpty {
            defaults.set([old], forKey: manualKey)
        }
        defaults.removeObject(forKey: legacyManualKey)
    }

    /// The stored endpoint list, in the order the user (or a pairing QR)
    /// added them — migrating the legacy key first. Migration input only,
    /// now that each host carries its own list.
    static func storedEndpoints(_ defaults: UserDefaults = .standard) -> [String] {
        migrateManualEndpointIfNeeded(defaults)
        return (defaults.array(forKey: manualKey) as? [String]) ?? []
    }

    /// FleetMirror conformance — the single-snapshot face `ChainFleetMirror`
    /// and MobileUsage read: the first host that answered.
    func latest() async throws -> MirrorSnapshot? {
        for pair in await latestAll(MirrorHostStore.load()) {
            if let snapshot = pair.snapshot { return snapshot }
        }
        return nil
    }

    /// `GET /snapshot` from every host at once (04-phone's `latestAll`):
    /// a dead one costs its own 3 s, not the whole refresh's. Each
    /// element carries the host back because a fetch can update its
    /// record — a swapped quick-tunnel URL, a new last-good endpoint.
    func latestAll(_ hosts: [MirrorHost]) async -> [(host: MirrorHost, snapshot: MirrorSnapshot?)] {
        let answered = await withTaskGroup(of: (MirrorHost, MirrorSnapshot?).self) { group in
            for host in hosts {
                group.addTask { await self.latest(host: host) }
            }
            var out: [(MirrorHost, MirrorSnapshot?)] = []
            for await pair in group { out.append(pair) }
            return out
        }
        // The caller's order — host #0 stays host #0 no matter who
        // answered first.
        return hosts.map { host in
            guard let found = answered.first(where: { $0.0.id == host.id }) else {
                return (host: host, snapshot: nil)
            }
            return (host: found.0, snapshot: found.1)
        }
    }

    /// One host's stored routes (last-good first), then its tunnel
    /// rendezvous, then Bonjour — the old `latest()`, scoped to a
    /// record. A 401 from a STORED route still stops: the host is right
    /// there refusing us, and the other routes would only repeat it.
    /// Discovery keeps going instead — with two daemons advertising, a
    /// 401 usually just means "that's the other host's port".
    private func latest(host: MirrorHost) async -> (MirrorHost, MirrorSnapshot?) {
        let token = host.normalizedToken
        var failures: [String] = []
        for text in host.candidateEndpoints {
            guard let manual = MirrorTransport.parseEndpoint(text) else { continue }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            do {
                let (data, _) = try await fetch(endpoint, path: MirrorTransport.snapshotPath,
                                                hostHeader: manual.host,
                                                useTLS: manual.useTLS, token: token,
                                                timeout: Self.candidateTimeout)
                let snapshot = try MirrorHostStore.decodeSnapshot(data)
                MirrorHostStore.update(host.id) { $0.lastGood = text }
                statuses[host.id] = "\(snapshot.machineName) at \(text)"
                return (host, snapshot)
            } catch MirrorTransportError.http(401) {
                // The host is right there and refusing us: that's a
                // pairing problem, not a network one, and the fix is one
                // field away.
                statuses[host.id] = "pairing token required — scan the QR in the Mac's "
                    + "Devices settings"
                return (host, nil)
            } catch {
                failures.append("\(Self.routeLabel(text)) \(Self.failureWord(error))")
            }
        }
        // Every saved route is dead. If one of them was a quick-tunnel
        // URL, this host may simply have restarted onto a new one and
        // published it to the rendezvous (MirrorRendezvous) — swap it in
        // and try once more before giving up.
        if let stale = host.endpoints.first(where: MirrorRendezvous.isEphemeral),
           let fresh = await rendezvousLookup(token: token), fresh != stale,
           let manual = MirrorTransport.parseEndpoint(fresh) {
            let swapped = host.endpoints.map { $0 == stale ? fresh : $0 }
            MirrorHostStore.update(host.id) { $0.endpoints = swapped }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            if let (data, _) = try? await fetch(endpoint, path: MirrorTransport.snapshotPath,
                                                hostHeader: manual.host, useTLS: manual.useTLS,
                                                token: token, timeout: Self.candidateTimeout),
               let snapshot = try? MirrorHostStore.decodeSnapshot(data) {
                MirrorHostStore.update(host.id) { $0.lastGood = fresh }
                statuses[host.id] = "\(snapshot.machineName) at \(fresh) (new tunnel address)"
                var named = host
                named.endpoints = swapped
                return (named, snapshot)
            }
            failures.append("new tunnel address didn't answer either")
        }
        // No stored endpoint answered (or none is stored) — Bonjour is
        // the last resort, and only worth trying while on the LAN. Every
        // discovered endpoint is tried with THIS host's token, and a 401
        // only means the advertiser is someone else's host.
        startBrowsing()
        var unauthorized = false
        for discovered in await allEndpoints() {
            do {
                let (data, remote) = try await fetch(discovered, path: MirrorTransport.snapshotPath,
                                                     hostHeader: "infinitus",
                                                     useTLS: false, token: token,
                                                     timeout: Self.candidateTimeout)
                let snapshot = try MirrorHostStore.decodeSnapshot(data)
                statuses[host.id] = "\(snapshot.machineName) at \(remote)"
                return (host, snapshot)
            } catch MirrorTransportError.http(401) {
                unauthorized = true
            } catch {
                failures.append("Wi-Fi discovery \(Self.failureWord(error))")
            }
        }
        statuses[host.id] = unauthorized && failures.isEmpty
            ? "pairing token required — scan the QR in the Mac's Devices settings"
            : (failures.isEmpty
               ? "no Mac found on this Wi-Fi"
               : "couldn't reach any saved Mac — " + failures.joined(separator: " · "))
        return (host, nil)
    }

    /// The session feed (#17 layer 1). `since`/`wait` make it a
    /// long-poll: the host holds the reply until the transcript changes
    /// or `wait` seconds pass. A long-poll goes to the route that last
    /// answered only, with a timeout past `wait` — falling through
    /// routes with a 30 s timeout each would be a minute of nothing; the
    /// caller retries the plain form on failure.
    /// Session screens call this without a host until W14 routes them —
    /// that means host #0, the Mac, exactly the old behaviour.
    func sessionTail(host: MirrorHost? = nil, pid: Int32, limit: Int,
                     since: String? = nil, wait: TimeInterval = 0) async throws -> SessionFeed {
        let host = host ?? MirrorHostStore.load().first ?? MirrorHost()
        var path = MirrorTransport.sessionTailPath(pid: pid) + "?n=\(limit)"
        if let since, wait > 0 {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            path += "&\(MirrorTransport.tailSinceQueryName)="
                + (since.addingPercentEncoding(withAllowedCharacters: allowed) ?? since)
                + "&\(MirrorTransport.tailWaitQueryName)=\(Int(wait))"
            guard let text = host.candidateEndpoints.first,
                  let manual = MirrorTransport.parseEndpoint(text) else {
                throw MirrorTransportError.timedOut
            }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            let (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                            useTLS: manual.useTLS, token: host.normalizedToken,
                                            timeout: wait + 10)
            return try Self.decodeFeed(data)
        }
        let data = try await fetchStoredThenDiscovered(host: host, path: path,
                                                       timeout: Self.candidateTimeout)
        return try Self.decodeFeed(data)
    }

    /// A feed image's thumbnail (`SessionFeedItem.images`, 2026-09-04):
    /// the bytes, since AsyncImage can't carry the pairing token.
    func sessionImage(host: MirrorHost? = nil, pid: Int32, id: String) async throws -> Data {
        let host = host ?? MirrorHostStore.load().first ?? MirrorHost()
        return try await fetchStoredThenDiscovered(
            host: host, path: MirrorTransport.sessionImagePath(pid: pid, id: id),
            timeout: Self.candidateTimeout)
    }

    /// Tries every stored endpoint of one host (last-good first) and
    /// then discovery — the plain GETs' path. `nil` from the stored walk
    /// means none of them answered for network reasons; a bad pairing
    /// token still throws, since that's equally actionable.
    private func fetchFromStored(host: MirrorHost, path: String, timeout: TimeInterval,
                                 method: String = "GET", body: Data? = nil) async throws -> Data? {
        for text in host.candidateEndpoints {
            guard let manual = MirrorTransport.parseEndpoint(text) else { continue }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            do {
                let (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                                useTLS: manual.useTLS, token: host.normalizedToken,
                                                timeout: timeout, method: method, body: body)
                MirrorHostStore.update(host.id) { $0.lastGood = text }
                return data
            } catch MirrorTransportError.http(401) {
                throw MirrorTransportError.http(401)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Every discovered endpoint, this host's token — a 401 only means
    /// the advertiser belongs to another host, so the walk goes on.
    /// `everyEndpoint: false` (the POSTs) tries the first advertiser
    /// only: a POST isn't idempotent, and delivering it twice because
    /// the first connection died after the host got it would type two
    /// messages into one terminal.
    private func fetchDiscovered(host: MirrorHost, path: String, timeout: TimeInterval,
                                 method: String = "GET", body: Data? = nil,
                                 everyEndpoint: Bool = true) async throws -> Data {
        startBrowsing()
        var candidates = await allEndpoints()
        if !everyEndpoint, candidates.count > 1 { candidates = [candidates[0]] }
        var lastError: Error = MirrorTransportError.timedOut
        for endpoint in candidates {
            do {
                let (data, _) = try await fetch(endpoint, path: path, hostHeader: "infinitus",
                                                useTLS: false, token: host.normalizedToken,
                                                timeout: timeout, method: method, body: body)
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetchStoredThenDiscovered(host: MirrorHost, path: String,
                                           timeout: TimeInterval) async throws -> Data {
        if let data = try await fetchFromStored(host: host, path: path, timeout: timeout) {
            return data
        }
        return try await fetchDiscovered(host: host, path: path, timeout: timeout)
    }

    /// Layer 2 of #17: posts a reply or a key press into a session's
    /// terminal. Unlike the feed, a host that's simply offline has
    /// nothing sensible to fall back to, so every failure throws.
    /// A POST is not idempotent: typing into a terminal twice is two
    /// messages. So unlike the GETs this never falls through to another
    /// stored route — it goes to the endpoint that last answered (the
    /// one the feed on screen came from) with a timeout long enough for
    /// the host's settle sleeps, and a failure is reported, not retried.
    static let inputTimeout: TimeInterval = 15
    /// Attachments push the body into the megabytes and the host writes
    /// each one to disk before delivering — longer than a bare keystroke
    /// or text line needs (2026-09-03 "add features to allow attachments").
    static let attachmentInputTimeout: TimeInterval = 60

    func sessionInput(host: MirrorHost? = nil, pid: Int32,
                      request: SessionInput.Request) async throws -> SessionInput.Reply {
        let host = host ?? MirrorHostStore.load().first ?? MirrorHost()
        let timeout = (request.attachments?.isEmpty == false) ? Self.attachmentInputTimeout : Self.inputTimeout
        let path = MirrorTransport.sessionInputPath(pid: pid)
        let body = try JSONEncoder().encode(request)
        let data: Data
        if let text = host.candidateEndpoints.first, let manual = MirrorTransport.parseEndpoint(text) {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                        useTLS: manual.useTLS, token: host.normalizedToken,
                                        timeout: timeout, method: "POST", body: body)
        } else {
            data = try await fetchDiscovered(host: host, path: path, timeout: timeout,
                                             method: "POST", body: body, everyEndpoint: false)
        }
        return try JSONDecoder().decode(SessionInput.Reply.self, from: data)
    }

    /// AWS sign-in from the phone: start (idempotent — returns the
    /// in-flight state, so it doubles as the poll), the intercepted
    /// relay callback, or the paste-back code. Same route as replies.
    func awsLoginStart(host: MirrorHost? = nil,
                       _ request: AwsLogin.StartRequest) async throws -> AwsLogin.Reply {
        try await postJSON(AwsLogin.startPath, host: host, body: request)
    }

    /// A new session on a host (#91): opens a terminal there and waits
    /// for the session to register, so this takes seconds. Multi-host
    /// (04-phone): the sheet names the machine to start it on, same
    /// `host:` seam every other POST takes.
    func startSession(host: MirrorHost? = nil,
                      _ request: SessionStart.Request) async throws -> SessionStart.Reply {
        try await postJSON(SessionStart.path, host: host, body: request,
                           timeout: Self.attachmentInputTimeout)
    }
    func awsLoginCallback(host: MirrorHost? = nil,
                          _ request: AwsLogin.CallbackRequest) async throws -> AwsLogin.Reply {
        try await postJSON(AwsLogin.callbackPath, host: host, body: request)
    }
    func awsLoginCode(host: MirrorHost? = nil,
                      _ request: AwsLogin.CodeRequest) async throws -> AwsLogin.Reply {
        try await postJSON(AwsLogin.codePath, host: host, body: request)
    }

    private func postJSON<B: Encodable, R: Decodable>(
        _ path: String, host: MirrorHost? = nil, body: B,
        timeout: TimeInterval = NetworkFleetMirror.inputTimeout
    ) async throws -> R {
        let host = host ?? MirrorHostStore.load().first ?? MirrorHost()
        let payload = try JSONEncoder().encode(body)
        let data: Data
        if let text = host.candidateEndpoints.first, let manual = MirrorTransport.parseEndpoint(text) {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(manual.host),
                port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
            (data, _) = try await fetch(endpoint, path: path, hostHeader: manual.host,
                                        useTLS: manual.useTLS, token: host.normalizedToken,
                                        timeout: timeout, method: "POST", body: payload)
        } else {
            data = try await fetchDiscovered(host: host, path: path, timeout: timeout,
                                             method: "POST", body: payload, everyEndpoint: false)
        }
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// A crash/hang report to the Mac (`POST /crashes`). Best effort:
    /// false when no Mac answered — the spool retries at the next launch.
    func postCrash(_ report: CrashReport) async -> Bool {
        let token = MirrorPairing.normalize(
            UserDefaults.standard.string(forKey: Self.tokenKey) ?? "")
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
    /// or app launch tries again. The Mac only: a Windows daemon has no
    /// APNs pusher, so LiveActivities never names a host here.
    func registerActivityToken(_ registration: ActivityPushRegistration,
                               host: MirrorHost? = nil) async -> Bool {
        let host = host ?? MirrorHostStore.load().first ?? MirrorHost()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(registration),
              let text = host.candidateEndpoints.first,
              let manual = MirrorTransport.parseEndpoint(text) else { return false }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(manual.host),
            port: NWEndpoint.Port(rawValue: manual.port) ?? .any)
        do {
            _ = try await fetch(endpoint, path: MirrorTransport.activityTokenPath, hostHeader: manual.host,
                                useTLS: manual.useTLS, token: host.normalizedToken,
                                timeout: Self.inputTimeout, method: "POST", body: body)
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

    private static func decodeFeed(_ data: Data) throws -> SessionFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFeed.self, from: data)
    }

    // MARK: - Discovery

    private func startBrowsing() {
        guard browser == nil else { return }
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
        // Discovery is host-agnostic (every paired machine advertises the
        // same service), so the failure is every host's LAN route dying.
        for host in MirrorHostStore.load() {
            statuses[host.id] = "discovery failed: \(error.localizedDescription)"
        }
    }

    /// Discovery takes a moment; without a short wait the very first
    /// refresh would come up empty and the screen would sit on its empty
    /// state for a whole 10s poll. The whole result set, once it has
    /// stopped growing (or the wait is up) — two daemons advertising on
    /// one LAN is exactly the shape multi-host matching exists for.
    private func allEndpoints(timeout: TimeInterval = 2) async -> [NWEndpoint] {
        let deadline = Date().addingTimeInterval(timeout)
        var count = 0
        while Date() < deadline {
            if endpoints.count == count, !endpoints.isEmpty { break }
            count = endpoints.count
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return endpoints
    }

    // MARK: - Fetch

    /// Returns the response body and the resolved `host:port` it came
    /// from (the Bonjour endpoint alone never names a port). `method`/
    /// `body` default to a plain `GET` (#17 layer 2's `POST
    /// /sessions/<pid>/input` is the only other caller).
    /// GET the rendezvous entry for this token — the quick-tunnel URL
    /// the host last published, or nil (unpublished, expired, offline).
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
