import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux
#endif

// MARK: - CLIProxyAPI behind the AccountEngine seam (#8)
//
// Everything goes over the proxy's Management API (`/v0/management/…`,
// bearer key). Never its config file, never its auth files — the same
// isolation cswap gets, HTTP instead of a subprocess. Portable: no
// AppKit, so the phone could talk to a proxy on the LAN one day.
//
// Verified live 2026-09-02 against cliproxyapi 7.2.145 (brew): root
// answers 200, management routes answer 401 without the key (the 81e1b53
// research note said 404 — that is the no-key-configured case), and
// `/api-call` relays Anthropic's 401 "OAuth access token has expired"
// for a stale credential, which maps to the relogin_required row.

public actor CLIProxyEngine: AccountEngine {
    public static let engineID = "cliproxy"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8317")!

    public nonisolated let id = CLIProxyEngine.engineID
    public nonisolated var displayName: String { "CLIProxyAPI" }
    public nonisolated var capabilities: EngineCapabilities {
        [.switch, .hold, .rename, .remove, .addOAuth, .costReport, .prefer]
    }

    let baseURL: URL
    private let key: String
    private let session: URLSession
    private let ledger: ProxyUsageLedger?
    /// Fan-out cap for the per-credential usage calls.
    private let usageConcurrency = 4
    private let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private let profileURL = "https://api.anthropic.com/api/oauth/profile"

    // Last-snapshot bookkeeping: the popup speaks ordinals, the proxy
    // speaks auth-file names.
    private var ordinals: [Provider: [String]] = [:]
    private var authIndexByName: [String: String] = [:]
    private var emailByName: [String: String] = [:]
    private var priorityByName: [String: Int] = [:]
    private var profiles: [String: (profile: ProxyProfile, at: Date)] = [:]
    /// Per-credential usage backoff after a 429 (Retry-After or 5 min).
    private var usageBackoff: [String: Date] = [:]
    /// Last good usage per credential, reused until `usageTTL` old: the
    /// gauges refresh every minute, Anthropic's usage endpoint does not
    /// take that per credential (429s, user 2026-09-02).
    private var usageCache: [String: (usage: Usage, at: Date)] = [:]
    private let usageTTL: TimeInterval
    /// Usage another engine fetched for the same email this refresh —
    /// the same account in two fleets gets one poll, not two.
    private var sharedUsage: [String: SharedUsage] = [:]
    /// Credentials whose token Anthropic rejected as expired — sticky
    /// until a usage call succeeds again (a 429 in between says nothing
    /// about the token).
    private var expiredNames: Set<String> = []
    private var pendingOAuth: (state: String, provider: Provider)?
    /// `GET /routing/strategy` as of the last snapshot.
    public private(set) var routingStrategy: String?
    /// `GET /routing/session-affinity` (upstream PR #5447) as of the last
    /// snapshot; nil while the proxy lacks the route (404) — the pane then
    /// falls back to telling the user where the YAML knob is.
    public private(set) var sessionAffinity: Bool?

    public init(baseURL: URL = CLIProxyEngine.defaultBaseURL, managementKey: String,
                session: URLSession = .shared, ledgerURL: URL? = nil,
                usageTTL: TimeInterval = 300) {
        self.baseURL = baseURL
        self.key = managementKey
        self.session = session
        self.ledger = ledgerURL.map { ProxyUsageLedger(url: $0) }
        self.usageTTL = usageTTL
    }

    public func offerSharedUsage(_ byEmail: [String: SharedUsage]) async {
        sharedUsage = Dictionary(byEmail.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { a, _ in a })
    }

    // MARK: HTTP

    struct Envelope: Decodable {
        let statusCode: Int
        let body: String
        enum CodingKeys: String, CodingKey { case statusCode = "status_code", body }
    }

    private func request(_ method: String, _ path: String,
                         query: [String: String] = [:],
                         json: [String: Any]? = nil) async throws -> (Int, Data) {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v0/management/" + path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 5
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
            req.timeoutInterval = 20   // api-call relays an upstream round-trip
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw EngineError.unreachable(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 404 { throw EngineError.unauthorized }
        guard (200..<300).contains(status) else {
            throw EngineError.remote(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return (status, data)
    }

    /// Test hook: one management GET, raw bytes.
    func rawGet(_ path: String) async throws -> (Int, Data) { try await request("GET", path) }

    /// `POST /api-call`: the proxy substitutes `$TOKEN$` with the
    /// credential's access token, so the token never reaches us.
    func apiCall(authIndex: String, url: String) async throws -> Envelope {
        let (_, data) = try await request("POST", "api-call", json: [
            "auth_index": authIndex,
            "method": "GET",
            "url": url,
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "infinitus/1.0",
            ],
        ])
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    // MARK: snapshot

    /// What the pane's "Test connection" shows.
    public struct Probe: Sendable, Equatable {
        public let credentialFiles: Int
        public let strategy: String?
    }

    public func probe() async throws -> Probe {
        let (_, data) = try await request("GET", "auth-files")
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
        return Probe(credentialFiles: files.count, strategy: try? await fetchStrategy())
    }

    private func fetchStrategy() async throws -> String {
        let (_, data) = try await request("GET", "routing/strategy")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["strategy"] as? String) ?? ""
    }

    private func fetchSessionAffinity() async throws -> Bool {
        let (_, data) = try await request("GET", "routing/session-affinity")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let enabled = obj?["enabled"] as? Bool else {
            throw EngineError.remote(status: 200, body: String(decoding: data, as: UTF8.self))
        }
        return enabled
    }

    /// `PUT /routing/session-affinity {"enabled": …}` — same persist +
    /// hot-reload as the strategy. Throws `.unauthorized` on a proxy
    /// without the route (its 404 maps there).
    public func setSessionAffinity(_ enabled: Bool) async throws {
        _ = try await request("PUT", "routing/session-affinity", json: ["enabled": enabled])
        sessionAffinity = enabled
    }

    /// The proxy's selector modes (config_basic.go `normalizeRoutingStrategy`).
    public static let routingStrategies = ["fill-first", "round-robin", "weighted-round-robin"]

    /// `PUT /routing/strategy {"value": …}` — the proxy persists it to
    /// its config and hot-reloads. Session affinity (config only, no
    /// management route) is what keeps a conversation on one credential
    /// under the round-robin modes.
    public func setRoutingStrategy(_ strategy: String) async throws {
        _ = try await request("PUT", "routing/strategy", json: ["value": strategy])
        routingStrategy = strategy
    }

    private enum UsageOutcome { case ok(Usage?), expired, failed }

    public func snapshot() async throws -> [EngineFleet] {
        let now = Date()
        let (_, data) = try await request("GET", "auth-files")
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
        routingStrategy = try? await fetchStrategy()
        sessionAffinity = try? await fetchSessionAffinity()

        // Gauges: only Claude credentials expose oauth/usage; held ones
        // are skipped (nothing routes to them). One Anthropic call per
        // ACCOUNT per usageTTL, not per credential per refresh: a fresh
        // cache entry, or usage another engine fetched for the same
        // email, is reused, and two credentials with one email share a
        // call — the 429 budget is per account (user 2026-09-02).
        func fresh(_ at: Date) -> Bool { now.timeIntervalSince(at) < usageTTL }
        var usage: [String: Usage] = [:]
        var wanted: [ProxyAuthFile] = []
        var leaderByEmail: [String: String] = [:]
        var followers: [String: [String]] = [:]
        for f in files where ProxyMapping.provider(for: f.provider ?? "") == .claude && f.disabled != true {
            let email = f.email?.lowercased()
            if let email, let shared = sharedUsage[email], fresh(shared.at) {
                usage[f.name] = shared.usage
                continue
            }
            if let cached = usageCache[f.name], fresh(cached.at) {
                usage[f.name] = cached.usage
                continue
            }
            guard usageBackoff[f.name].map({ $0 <= now }) ?? true else { continue }
            // An expired credential always probes itself (only a 200
            // clears the sticky state); the rest share a leader per email.
            if let email, !expiredNames.contains(f.name) {
                if let leader = leaderByEmail[email] {
                    followers[leader, default: []].append(f.name)
                    continue
                }
                leaderByEmail[email] = f.name
            }
            wanted.append(f)
        }
        var failed: Set<String> = []
        await withTaskGroup(of: (String, UsageOutcome, ProxyProfile?).self) { group in
            var pending = wanted.makeIterator()
            var inFlight = 0
            func launch(_ file: ProxyAuthFile) {
                let name = file.name, authIndex = file.authIndex ?? file.id ?? file.name
                let wantProfile = profiles[name].map { now.timeIntervalSince($0.at) > 86_400 } ?? true
                group.addTask { [self] in
                    guard let env = try? await self.apiCall(authIndex: authIndex, url: self.usageURL) else {
                        return (name, .failed, nil)
                    }
                    switch env.statusCode {
                    case 200:
                        let parsed = OAuthUsage.parse(Data(env.body.utf8), now: now)
                        var profile: ProxyProfile?
                        if wantProfile,
                           let p = try? await self.apiCall(authIndex: authIndex, url: self.profileURL),
                           p.statusCode == 200 {
                            profile = ProxyProfile.parse(Data(p.body.utf8))
                        }
                        return (name, .ok(parsed), profile)
                    case 401:
                        return (name, .expired, nil)
                    case 429:
                        await self.noteBackoff(name: name)
                        return (name, .failed, nil)
                    default:
                        return (name, .failed, nil)
                    }
                }
                inFlight += 1
            }
            while inFlight < usageConcurrency, let next = pending.next() { launch(next) }
            for await (name, outcome, profile) in group {
                inFlight -= 1
                switch outcome {
                case .ok(let u):
                    expiredNames.remove(name)
                    if let u {
                        for n in [name] + (followers[name] ?? []) {
                            usage[n] = u
                            usageCache[n] = (u, now)
                        }
                    }
                case .expired:
                    expiredNames.insert(name)
                    followers[name]?.forEach { failed.insert($0) }
                case .failed:
                    failed.insert(name)
                    followers[name]?.forEach { failed.insert($0) }
                }
                if let profile { profiles[name] = (profile, now) }
                if let next = pending.next() { launch(next) }
            }
        }

        let mapped = ProxyMapping.fleets(
            engineID: Self.engineID, files: files, usage: usage,
            profiles: profiles.mapValues(\.profile), now: now)
        ordinals = mapped.ordinals
        authIndexByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.authIndex ?? $0.id ?? $0.name) })
        emailByName = Dictionary(uniqueKeysWithValues: files.compactMap { f in f.email.map { (f.name, $0) } })
        priorityByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.priority ?? 0) })

        await drainUsageQueue()

        // An expired token is a re-login, not an outage: the row gets the
        // relogin action instead of an error line. A fetch that failed
        // (429 budget, network) must not pose as a healthy row either.
        let expired = expiredNames
        // Skipped while backing off = still unknown, not healthy.
        let backedOff = Set(files.filter { usageBackoff[$0.name].map { $0 > now } ?? false }.map(\.name))
        let unavailable = failed.union(backedOff).subtracting(expired)
        guard !expired.isEmpty || !unavailable.isEmpty else { return mapped.fleets }
        return mapped.fleets.map { fleet in
            let names = ordinals[fleet.provider] ?? []
            let accounts = fleet.accounts.map { a -> Account in
                guard a.number - 1 < names.count, a.usageStatus == "ok" else { return a }
                let name = names[a.number - 1]
                let status: String
                if expired.contains(name) { status = "relogin_required" }
                else if unavailable.contains(name) && a.usage == nil { status = "usage_unavailable" }
                else { return a }
                return Account(number: a.number, email: a.email,
                               organizationName: a.organizationName,
                               organizationUuid: a.organizationUuid,
                               isOrganization: a.isOrganization, active: a.active,
                               usageStatus: status, usage: nil,
                               alias: a.alias, icon: a.icon, plan: a.plan,
                               disabled: a.disabled)
            }
            // A credential that needs a re-login can't be "next".
            var next = fleet.nextCandidate
            if let n = next, accounts.first(where: { $0.number == n })?.usageStatus == "relogin_required" {
                next = accounts.first {
                    !$0.active && $0.disabled != true && $0.usageStatus == "ok"
                        && !AccountVitals.isDead($0.usage)
                }?.number
            }
            return EngineFleet(engineID: fleet.engineID, provider: fleet.provider,
                               accounts: accounts, activeNumber: fleet.activeNumber,
                               nextCandidate: next,
                               nextRecovery: fleet.nextRecovery,
                               liveSessions: nil, raw: nil)
        }
    }

    private func noteBackoff(name: String) {
        usageBackoff[name] = Date().addingTimeInterval(300)
    }

    /// The proxy's usage queue is a destructive 60-second buffer: every
    /// poll pops what accumulated into our own ledger.
    private func drainUsageQueue() async {
        guard let ledger else { return }
        guard let (_, data) = try? await request("GET", "usage-queue", query: ["count": "500"]) else { return }
        let records = ProxyUsageRecord.decodeQueue(data)
        guard !records.isEmpty else { return }
        try? await ledger.append(records)
    }

    // MARK: actions

    /// Internal for the live round-trip test.
    func name(_ provider: Provider, _ number: Int) throws -> String {
        let names = ordinals[provider] ?? []
        guard number >= 1, number <= names.count else {
            throw EngineError.remote(status: 0, body: "no account #\(number) in the last snapshot")
        }
        return names[number - 1]
    }

    /// "Switch" on a proxy = make this credential the top priority tier
    /// (selector.go: highest integer wins). Meaningful under fill-first.
    public func switchTo(fleet: Provider, number: Int) async throws {
        let target = try name(fleet, number)
        let top = priorityByName.values.max() ?? 0
        _ = try await request("PATCH", "auth-files/fields",
                              json: ["name": target, "priority": top + 1])
        priorityByName[target] = top + 1
    }

    /// Pick-first on a proxy = the priority tiers above the floor (the
    /// fleet's lowest priority, missing = 0): fill-first drains a starred
    /// credential before an unstarred one. A star joins the tier just
    /// above the floor — under anything switched to (top+1), so the active
    /// credential stays the top pick; unstarring drops to the floor.
    public func setPreferred(fleet: Provider, number: Int, _ on: Bool) async throws {
        let target = try name(fleet, number)
        let floor = (ordinals[fleet] ?? []).map { priorityByName[$0] ?? 0 }.min() ?? 0
        let current = priorityByName[target] ?? 0
        if on ? current > floor : current == floor { return }
        try await setPriority(fleet: fleet, number: number, on ? floor + 1 : floor)
    }

    /// Internal: the live switch test puts the priority back.
    func setPriority(fleet: Provider, number: Int, _ priority: Int) async throws {
        let target = try name(fleet, number)
        _ = try await request("PATCH", "auth-files/fields",
                              json: ["name": target, "priority": priority])
        priorityByName[target] = priority
    }

    public func setHold(fleet: Provider, number: Int, held: Bool) async throws {
        let target = try name(fleet, number)
        _ = try await request("PATCH", "auth-files/status",
                              json: ["name": target, "disabled": held])
    }

    public func rename(fleet: Provider, number: Int, _ alias: String) async throws {
        let target = try name(fleet, number)
        _ = try await request("PATCH", "auth-files/fields",
                              json: ["name": target,
                                     "note": alias.trimmingCharacters(in: .whitespaces)])
    }

    public func remove(fleet: Provider, number: Int) async throws {
        let target = try name(fleet, number)
        _ = try await request("DELETE", "auth-files", query: ["name": target])
    }

    /// The proxy runs its own OAuth callback server; we open the URL
    /// and poll the session state.
    public func beginOAuthAdd(fleet: Provider) async throws -> URL {
        let path: String
        switch fleet {
        case .claude: path = "anthropic-auth-url"
        case .codex: path = "codex-auth-url"
        case .gemini, .kiro, .other: throw EngineError.unsupported("addOAuth for \(fleet.rawValue)")
        }
        // is_webui: only then does the proxy open the local callback
        // listener (port 54545 for Anthropic) that forwards the OAuth
        // redirect to its own /anthropic/callback. Without it the
        // redirect hits a closed port (user 2026-09-02:
        // ERR_CONNECTION_REFUSED; auth_files_oauth_callback.go).
        let (_, data) = try await request("GET", path, query: ["is_webui": "true"])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let urlString = obj?["url"] as? String, let url = URL(string: urlString),
              let state = obj?["state"] as? String else {
            throw EngineError.remote(status: 200, body: String(decoding: data, as: UTF8.self))
        }
        pendingOAuth = (state, fleet)
        return url
    }

    public func awaitOAuthAdd() async throws {
        guard let pending = pendingOAuth else { throw EngineError.unsupported("no OAuth in progress") }
        defer { pendingOAuth = nil }
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            let (_, data) = try await request("GET", "get-auth-status", query: ["state": pending.state])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch obj?["status"] as? String {
            case "ok": return
            case "error":
                throw EngineError.remote(status: 200, body: (obj?["error"] as? String) ?? "OAuth failed")
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw EngineError.remote(status: 0, body: "OAuth sign-in timed out (5 min)")
    }

    public func usageReport(days: Int) async throws -> UsageReport {
        guard let ledger else { throw EngineError.unsupported("costReport") }
        var numbers: [String: Int] = [:], emails: [String: String] = [:]
        for (provider, names) in ordinals where provider == .claude {
            for (i, n) in names.enumerated() {
                if let idx = authIndexByName[n] {
                    numbers[idx] = i + 1
                    if let e = emailByName[n] { emails[idx] = e }
                }
            }
        }
        return await ledger.report(days: days, numbers: numbers, emails: emails)
    }
}
