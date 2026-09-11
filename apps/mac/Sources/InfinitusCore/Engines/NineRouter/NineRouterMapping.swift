import Foundation

// MARK: - 9Router wire shapes → InfinitusCore models
//
// Pure mapping for 9Router's dashboard API (decolua/9router, 0.5.x):
// no networking here. `GET /api/providers` lists every connection with
// its secrets already stripped server-side; `GET /api/usage/{id}` returns
// the provider's quota report normalized by 9Router itself (for Claude:
// `session (5h)`, `weekly (7d)`, `weekly <model> (7d)`, each `used` %
// with an ISO `resetAt`; for Kiro: one `credit` pool with `used`/`total`
// and a monthly `resetAt`). Unknown keys are ignored by Decodable's
// default, so newer 9Router fields never break decoding — the Kiro
// row's `providerSpecificData` (which carries client secrets) is never
// decoded at all.

/// One `providerConnections` row as the API shows it. Only `id` and
/// `provider` are required.
public struct NineRouterConnection: Decodable, Sendable {
    public let id: String
    public let provider: String
    public let authType: String?
    public let name: String?
    public let email: String?
    /// 1 = first pick under 9Router's fallback order (renumbered on
    /// every priority write).
    public let priority: Int?
    public let isActive: Bool?
    /// Cooldown after a rate-limit / quota error; ISO instant.
    public let rateLimitedUntil: String?
    public let lastError: LastError?
    public let updatedAt: String?

    public struct LastError: Decodable, Sendable {
        public let status: Int?
        public let message: String?
        public init(status: Int?, message: String?) {
            self.status = status
            self.message = message
        }
    }

    public init(id: String, provider: String, authType: String? = "oauth", name: String? = nil,
                email: String? = nil, priority: Int? = nil, isActive: Bool? = true,
                rateLimitedUntil: String? = nil, lastError: LastError? = nil,
                updatedAt: String? = nil) {
        self.id = id
        self.provider = provider
        self.authType = authType
        self.name = name
        self.email = email
        self.priority = priority
        self.isActive = isActive
        self.rateLimitedUntil = rateLimitedUntil
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public struct NineRouterConnectionList: Decodable, Sendable {
    public let connections: [NineRouterConnection]
}

/// `GET /api/usage/{id}` for any connection.
public enum NineRouterUsage {
    public enum Outcome: Sendable {
        /// The quotas, plus the plan name 9Router reports ("Claude Code",
        /// "KIRO POWER") for the row's subscription tip.
        case ok(Usage?, plan: String?)
        /// 9Router answered with a message instead of quotas and the
        /// message reads as an expired/rejected token.
        case expired
        case unavailable(String)
    }

    struct Wire: Decodable {
        struct Quota: Decodable {
            let used: Double?
            let total: Double?
            let resetAt: String?
            let unlimited: Bool?
        }
        let plan: String?
        let message: String?
        let error: String?
        let quotas: [String: Quota]?
        /// Anthropic's `extra_usage` block, passed through by 9Router
        /// verbatim — same shape the proxy engine already parses.
        let extraUsage: OAuthUsage.Wire.ExtraUsage?
    }

    static let authExpiredMarkers = ["expired", "authentication", "unauthorized", "401", "re-authorize"]

    public static func parse(_ data: Data, now: Date = Date()) -> Outcome {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return .unavailable("unreadable usage reply")
        }
        if let message = wire.message ?? wire.error, wire.quotas == nil || wire.quotas?.isEmpty == true {
            let lower = message.lowercased()
            if authExpiredMarkers.contains(where: { lower.contains($0) }) { return .expired }
            return .unavailable(message)
        }
        guard let quotas = wire.quotas else { return .ok(nil, plan: wire.plan) }

        func window(_ q: Wire.Quota, name: String? = nil) -> UsageWindow? {
            guard let used = q.used, q.unlimited != true else { return nil }
            var countdown: String?, clock: String?
            if let resetAt = q.resetAt, let date = WeeklyRoll.parse(resetAt) {
                countdown = ResetFormat.countdown(until: date, now: now)
                clock = ResetFormat.clock(date, now: now)
            }
            return UsageWindow(pct: used, resetsAt: q.resetAt, countdown: countdown,
                               clock: clock, name: name)
        }

        var fiveHour: UsageWindow?, sevenDay: UsageWindow?
        var scoped: [UsageWindow] = []
        var spend: Spend?
        for (key, quota) in quotas.sorted(by: { $0.key < $1.key }) {
            let lower = key.lowercased()
            if lower == "credit" {
                // Kiro: a monthly credit pool, the account's only quota —
                // shown on the row's credit gauge, in credits not dollars.
                guard quota.unlimited != true, let used = quota.used,
                      let total = quota.total, total > 0 else { continue }
                var countdown: String?, clock: String?
                if let resetAt = quota.resetAt, let date = WeeklyRoll.parse(resetAt) {
                    countdown = ResetFormat.countdown(until: date, now: now)
                    clock = ResetFormat.clock(date, now: now)
                }
                spend = Spend(used: used, limit: total, pct: used / total * 100,
                              currency: "credits", resetsAt: quota.resetAt,
                              countdown: countdown, clock: clock)
            } else if lower.hasPrefix("session") {
                fiveHour = window(quota)
            } else if lower == "weekly (7d)" || lower == "weekly" {
                sevenDay = window(quota)
            } else if lower.hasPrefix("weekly ") {
                // "weekly opus (7d)" → "Opus"
                let model = key.dropFirst("weekly ".count)
                    .replacingOccurrences(of: "(7d)", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty, let w = window(quota, name: model.capitalized) else { continue }
                scoped.append(w)
            }
        }
        if let eu = wire.extraUsage, eu.isEnabled == true,
           let used = eu.usedCredits, let limit = eu.monthlyLimit, let pct = eu.utilization {
            var countdown: String?, clock: String?
            if let resetsAt = eu.resetsAt, let date = WeeklyRoll.parse(resetsAt) {
                countdown = ResetFormat.countdown(until: date, now: now)
                clock = ResetFormat.clock(date, now: now)
            }
            spend = Spend(used: used / 100, limit: limit / 100, pct: pct,
                          currency: eu.currency ?? "USD", resetsAt: eu.resetsAt,
                          countdown: countdown, clock: clock)
        }
        if fiveHour == nil, sevenDay == nil, scoped.isEmpty, spend == nil { return .ok(nil, plan: wire.plan) }
        return .ok(Usage(fiveHour: fiveHour, sevenDay: sevenDay,
                         scoped: scoped.isEmpty ? nil : scoped, spend: spend), plan: wire.plan)
    }
}

/// Groups connections into one fleet per provider (Claude first, then
/// Kiro/Codex/Gemini — 2026-09-03: "my 9router has Kiro too, display
/// it") over the shared `AutoOrder` / `RecoveryMath` / `AccountVitals`
/// math, exactly like ProxyMapping. Providers the app has no name for
/// (`.other`) stay out.
public enum NineRouterMapping {
    public static func isClaude(_ c: NineRouterConnection) -> Bool {
        ProxyMapping.provider(for: c.provider) == .claude
    }

    /// Providers present, Claude first, the rest by display name.
    public static func providers(_ connections: [NineRouterConnection]) -> [Provider] {
        let present = Set(connections.map { ProxyMapping.provider(for: $0.provider) }).subtracting([.other])
        return present.sorted { a, b in
            if (a == .claude) != (b == .claude) { return a == .claude }
            return a.displayName < b.displayName
        }
    }

    /// 9Router's own pick order within one provider: priority ascending
    /// (1 first), newer update first on ties, id last so the order is total.
    public static func ordered(_ connections: [NineRouterConnection],
                               provider: Provider = .claude) -> [NineRouterConnection] {
        connections.filter { ProxyMapping.provider(for: $0.provider) == provider }.sorted { a, b in
            let pa = a.priority ?? Int.max, pb = b.priority ?? Int.max
            if pa != pb { return pa < pb }
            let ua = a.updatedAt ?? "", ub = b.updatedAt ?? ""
            if ua != ub { return ua > ub }
            return a.id < b.id
        }
    }

    /// `usage` / `plans` / `statuses` keyed by connection id; `ordinals`
    /// lists each provider's ids in ordinal order — index 0 is
    /// `Account.number == 1` of that fleet.
    public static func fleets(engineID: String, connections: [NineRouterConnection],
                              usage: [String: Usage], plans: [String: String] = [:],
                              statuses: [String: String],
                              now: Date = Date()) -> (fleets: [EngineFleet], ordinals: [Provider: [String]]) {
        var fleets: [EngineFleet] = []
        var ordinals: [Provider: [String]] = [:]
        for provider in providers(connections) {
            let (fleet, ids) = fleet(engineID: engineID, provider: provider,
                                     connections: ordered(connections, provider: provider),
                                     usage: usage, plans: plans, statuses: statuses, now: now)
            fleets.append(fleet)
            ordinals[provider] = ids
        }
        return (fleets, ordinals)
    }

    /// "KIRO POWER" → "Kiro Power"; already-cased names ("Claude Code")
    /// pass through.
    static func planName(_ raw: String) -> String {
        raw == raw.uppercased() ? raw.capitalized : raw
    }

    static func fleet(engineID: String, provider: Provider, connections sorted: [NineRouterConnection],
                      usage: [String: Usage], plans: [String: String], statuses: [String: String],
                      now: Date) -> (fleet: EngineFleet, ordinals: [String]) {
        // Active = the first connection 9Router's fallback order would try:
        // enabled and not cooling down.
        let activeID = sorted.first { c in
            c.isActive != false && !inCooldown(c, now: now)
        }?.id

        var accounts: [Account] = []
        for (index, c) in sorted.enumerated() {
            let email = c.email ?? c.name ?? c.id
            let alias = (c.name?.isEmpty == false && c.name != email) ? c.name : nil
            let fileUsage = usage[c.id]
            accounts.append(Account(
                number: index + 1, email: email,
                active: c.id == activeID,
                usageStatus: statuses[c.id] ?? usageStatus(for: c, now: now),
                usage: fileUsage, alias: alias, plan: plans[c.id].map(planName),
                disabled: c.isActive == false ? true : nil,
                usageFetchedAt: fileUsage != nil ? ProxyMapping.isoString(now) : nil))
        }
        let activeNumber = accounts.first(where: \.active)?.number
        let candidate = AutoOrder.order(accounts).first { number in
            guard number != activeNumber,
                  let account = accounts.first(where: { $0.number == number }) else { return false }
            return account.disabled != true && !AccountVitals.isDead(account.usage)
        }
        let recovery = candidate == nil ? RecoveryMath.nextRecovery(accounts: accounts) : nil
        let fleet = EngineFleet(engineID: engineID, provider: provider, accounts: accounts,
                                activeNumber: activeNumber, nextCandidate: candidate,
                                nextRecovery: recovery, liveSessions: nil, raw: nil)
        return (fleet, sorted.map(\.id))
    }

    static func inCooldown(_ c: NineRouterConnection, now: Date) -> Bool {
        guard let until = c.rateLimitedUntil, let date = WeeklyRoll.parse(until) else { return false }
        return date > now
    }

    /// disabled → relogin_required (a 401/403 last error) → error
    /// (cooling down) → ok.
    static func usageStatus(for c: NineRouterConnection, now: Date) -> String {
        if c.isActive == false { return "disabled" }
        if let status = c.lastError?.status, status == 401 || status == 403 { return "relogin_required" }
        if inCooldown(c, now: now) { return "error" }
        return "ok"
    }
}
