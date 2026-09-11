import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux
#endif

/// The 9Router engine (decolua/9router): a third `AccountEngine`, one
/// Claude fleet over 9Router's dashboard API on loopback. 9Router rotates
/// connections per request in priority order with cooldown fallback, so
/// "switch" = make a connection priority 1, hold = `isActive:false`,
/// remove = delete. Rotation policy stays 9Router's; the app only sets
/// its knobs. Auth is the dashboard password (keychain-held), exchanged
/// for a 24h session cookie on demand — 9Router's loopback API refuses
/// anonymous calls unless its "require login" setting is off, which we
/// honor by only logging in after a 401. Never reads `~/.9router`.
public actor NineRouterEngine: AccountEngine {
    public static let engineID = "9router"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:20128")!

    public nonisolated let id = NineRouterEngine.engineID
    public nonisolated var displayName: String { "9Router" }
    public nonisolated var capabilities: EngineCapabilities { [.switch, .hold, .remove] }

    let baseURL: URL
    private let password: String
    private let session: URLSession
    private let usageConcurrency = 4
    private let usageTTL: TimeInterval

    private var ordinals: [Provider: [String]] = [:]
    private var usageCache: [String: (usage: Usage, at: Date)] = [:]
    /// Plan names ride the usage reply, so they outlive the usage TTL here.
    private var planCache: [String: String] = [:]
    private var usageBackoff: [String: Date] = [:]
    private var sharedUsage: [String: SharedUsage] = [:]
    private var expiredIDs: Set<String> = []
    private var loggedIn = false

    public init(baseURL: URL = NineRouterEngine.defaultBaseURL, password: String,
                session: URLSession? = nil, usageTTL: TimeInterval = 300) {
        self.baseURL = baseURL
        self.password = password
        // A private cookie jar: the session cookie must never leak into
        // the shared storage, and an ephemeral one keeps it in memory.
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.usageTTL = usageTTL
    }

    public func offerSharedUsage(_ byEmail: [String: SharedUsage]) async {
        sharedUsage = Dictionary(byEmail.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { a, _ in a })
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String,
                         json: [String: Any]? = nil, retryAuth: Bool = true) async throws -> (Int, Data) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/" + path))
        req.httpMethod = method
        req.timeoutInterval = 20   // usage relays an upstream round-trip
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw EngineError.unreachable(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            guard retryAuth else { throw EngineError.unauthorized }
            try await login()
            return try await request(method, path, json: json, retryAuth: false)
        }
        guard (200..<300).contains(status) else {
            throw EngineError.remote(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return (status, data)
    }

    /// `POST /api/auth/login` — the cookie lands in this session's jar.
    private func login() async throws {
        guard !password.isEmpty else { throw EngineError.unauthorized }
        let (status, _) = try await request("POST", "auth/login", json: ["password": password], retryAuth: false)
        loggedIn = (200..<300).contains(status)
    }

    /// Test hook: one dashboard GET, raw bytes.
    func rawGet(_ path: String) async throws -> (Int, Data) { try await request("GET", path) }

    // MARK: snapshot

    public struct Probe: Sendable, Equatable {
        public let connections: Int
        public let claudeConnections: Int
    }

    public func probe() async throws -> Probe {
        let (_, data) = try await request("GET", "providers")
        let list = try JSONDecoder().decode(NineRouterConnectionList.self, from: data).connections
        return Probe(connections: list.count, claudeConnections: list.filter(NineRouterMapping.isClaude).count)
    }

    public func snapshot() async throws -> [EngineFleet] {
        let now = Date()
        let (_, data) = try await request("GET", "providers")
        let connections = try JSONDecoder().decode(NineRouterConnectionList.self, from: data).connections
        let known = NineRouterMapping.providers(connections).flatMap {
            NineRouterMapping.ordered(connections, provider: $0)
        }

        // One quota call per account per usageTTL, shared across engines
        // holding the same email — the Anthropic 429 budget is per
        // account (same rules as CLIProxyEngine).
        func fresh(_ at: Date) -> Bool { now.timeIntervalSince(at) < usageTTL }
        var usage: [String: Usage] = [:]
        var wanted: [NineRouterConnection] = []
        var leaderByEmail: [String: String] = [:]
        var followers: [String: [String]] = [:]
        for c in known where c.isActive != false {
            let email = c.email?.lowercased()
            if let email, let shared = sharedUsage[email], fresh(shared.at) {
                usage[c.id] = shared.usage
                continue
            }
            if let cached = usageCache[c.id], fresh(cached.at) {
                usage[c.id] = cached.usage
                continue
            }
            guard usageBackoff[c.id].map({ $0 <= now }) ?? true else { continue }
            if let email, !expiredIDs.contains(c.id) {
                if let leader = leaderByEmail[email] {
                    followers[leader, default: []].append(c.id)
                    continue
                }
                leaderByEmail[email] = c.id
            }
            wanted.append(c)
        }

        var statuses: [String: String] = [:]
        await withTaskGroup(of: (String, NineRouterUsage.Outcome).self) { group in
            var pending = wanted.makeIterator()
            var inFlight = 0
            func launch(_ c: NineRouterConnection) {
                group.addTask { [self] in
                    guard let (_, body) = try? await self.request("GET", "usage/\(c.id)") else {
                        return (c.id, .unavailable("request failed"))
                    }
                    return (c.id, NineRouterUsage.parse(body, now: now))
                }
                inFlight += 1
            }
            while inFlight < usageConcurrency, let next = pending.next() { launch(next) }
            for await (id, outcome) in group {
                inFlight -= 1
                switch outcome {
                case .ok(let u, let plan):
                    expiredIDs.remove(id)
                    if let plan { planCache[id] = plan }
                    if let u {
                        for n in [id] + (followers[id] ?? []) {
                            usage[n] = u
                            usageCache[n] = (u, now)
                        }
                    } else {
                        // No quotas for this provider (Gemini today): don't
                        // ask again before the TTL, same cadence as a hit.
                        usageBackoff[id] = now.addingTimeInterval(usageTTL)
                    }
                case .expired:
                    expiredIDs.insert(id)
                    statuses[id] = "relogin_required"
                    followers[id]?.forEach { statuses[$0] = "usage_unavailable" }
                case .unavailable:
                    usageBackoff[id] = now.addingTimeInterval(60)
                    if usage[id] == nil { statuses[id] = "usage_unavailable" }
                    followers[id]?.forEach { statuses[$0] = "usage_unavailable" }
                }
                if let next = pending.next() { launch(next) }
            }
        }
        for id in expiredIDs where statuses[id] == nil { statuses[id] = "relogin_required" }

        let mapped = NineRouterMapping.fleets(engineID: Self.engineID, connections: connections,
                                              usage: usage, plans: planCache, statuses: statuses, now: now)
        ordinals = mapped.ordinals
        return mapped.fleets
    }

    // MARK: actions

    func connectionID(_ provider: Provider, _ number: Int) throws -> String {
        guard let ids = ordinals[provider], number >= 1, number <= ids.count else {
            throw EngineError.remote(status: 0, body: "no \(provider.displayName) account #\(number) in the last snapshot")
        }
        return ids[number - 1]
    }

    /// Priority 0 sorts ahead of every renumbered 1..n row; 9Router
    /// renumbers the provider's connections on the write.
    public func switchTo(fleet: Provider, number: Int) async throws {
        let id = try connectionID(fleet, number)
        _ = try await request("PUT", "providers/\(id)", json: ["priority": 0])
    }

    public func setHold(fleet: Provider, number: Int, held: Bool) async throws {
        let id = try connectionID(fleet, number)
        _ = try await request("PUT", "providers/\(id)", json: ["isActive": !held])
    }

    public func remove(fleet: Provider, number: Int) async throws {
        let id = try connectionID(fleet, number)
        _ = try await request("DELETE", "providers/\(id)")
    }
}
