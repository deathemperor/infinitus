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

    /// 9Router 0.6.x grew a plain-string shape for `lastError`
    /// ("[403]: model requires a subscription" — the ollama/grok-cli
    /// rows on the user's router, 2026-09-04) alongside the older
    /// `{status, message}` object. Decode either; a string carries no
    /// status, so `lastError.status` stays nil and the row just shows
    /// as errored rather than relogin_required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        authType = try c.decodeIfPresent(String.self, forKey: .authType)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        rateLimitedUntil = try c.decodeIfPresent(String.self, forKey: .rateLimitedUntil)
        if let object = try? c.decodeIfPresent(LastError.self, forKey: .lastError) {
            lastError = object
        } else {
            lastError = (try? c.decodeIfPresent(String.self, forKey: .lastError))
                .flatMap { $0 }.map { LastError(status: nil, message: $0) }
        }
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, authType, name, email, priority, isActive
        case rateLimitedUntil, lastError, updatedAt
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
            let remainingPercentage: Double?
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

    public static func parse(_ data: Data, hidden: Set<String> = [], now: Date = Date()) -> Outcome {
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
            guard q.unlimited != true else { return nil }
            let pct: Double
            if let rp = q.remainingPercentage {
                pct = max(0, min(100, 100.0 - rp))
            } else if let used = q.used, let total = q.total, total > 0 {
                pct = max(0, min(100, (used / total) * 100.0))
            } else if let used = q.used {
                pct = used
            } else {
                return nil
            }
            var countdown: String?, clock: String?
            if let resetAt = q.resetAt, let date = WeeklyRoll.parse(resetAt) {
                countdown = ResetFormat.countdown(until: date, now: now)
                clock = ResetFormat.clock(date, now: now)
            }
            return UsageWindow(pct: pct, resetsAt: q.resetAt, countdown: countdown,
                               clock: clock, name: name)
        }

        var fiveHour: UsageWindow?, sevenDay: UsageWindow?
        var modelQuotas: [(key: String, quota: Wire.Quota)] = []
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
                guard !model.isEmpty else { continue }
                modelQuotas.append((key: key, quota: quota))
            } else {
                // Per-model quota row (e.g. "gemini-3.8-flash-high").
                // Honor 9Router's hide feature: hidden quotas are excluded.
                guard !hidden.contains(key) else { continue }
                modelQuotas.append((key: key, quota: quota))
            }
        }

        // When there is no explicit session (5h) window, promote the newest/biggest
        // Gemini model to fiveHour so it displays in the first row.
        if fiveHour == nil {
            let geminiCandidates = modelQuotas.filter { $0.key.lowercased().contains("gemini") }
            if let best = geminiCandidates.max(by: { isOlderGemini($0.key, than: $1.key) }) {
                fiveHour = window(best.quota)
                modelQuotas.removeAll { $0.key == best.key }
            }
        }

        var scoped: [UsageWindow] = []
        for item in modelQuotas {
            let displayName: String
            if item.key.lowercased().hasPrefix("weekly ") {
                displayName = item.key.dropFirst("weekly ".count)
                    .replacingOccurrences(of: "(7d)", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .capitalized
            } else {
                displayName = Self.modelName(item.key)
            }
            guard let w = window(item.quota, name: displayName) else { continue }
            scoped.append(w)
        }
        // Most-burned first — the order the binding-window logic and
        // the eye expect. Hidden rows were honored above; the cap is
        // only the layout backstop for a connection with everything
        // visible (the popup grid grows a row per scoped window). Ties
        // stay alphabetical so the order is deterministic across polls
        // (the grid re-renders on change).
        if scoped.count > 1 {
            scoped.sort { $0.pct != $1.pct ? $0.pct > $1.pct : ($0.name ?? "") < ($1.name ?? "") }
        }
        if scoped.count > Self.scopedCap {
            scoped = Array(scoped.prefix(Self.scopedCap))
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

    /// The most-burned per-model rows a row shows — the grid grows a
    /// scoped gauge per entry, so a nine-model Antigravity connection
    /// can't have them all (the 9Router dashboard hides the rest
    /// behind a "Hidden:" row; same idea).
    static let scopedCap = 4

    /// "gemini-3.8-flash-high" → "Gemini 3.8 Flash (High)" — the
    /// dashboard's row label. Version and size tokens ("3.8", "120b")
    /// ride along; known acronyms uppercase; an effort-level word
    /// becomes the parenthetical the dashboard puts on the end.
    static func modelName(_ slug: String) -> String {
        let acronyms = ["gpt", "glm", "oss", "ai", "llm", "tts"]
        let efforts = ["high", "medium", "low", "thinking", "max"]
        var words: [String] = [], effort: String?
        for token in slug.split(separator: "-") {
            let t = token.lowercased()
            if efforts.contains(t) { effort = t.capitalized; continue }
            if t.first?.isNumber == true || acronyms.contains(t) { words.append(token.uppercased()) }
            else { words.append(token.capitalized) }
        }
        if let effort { words.append("(\(effort))") }
        return words.joined(separator: " ")
    }

    struct GeminiRank: Comparable {
        let major: Int
        let minor: Int
        let tier: Int
        let isPro: Bool

        static func < (lhs: GeminiRank, rhs: GeminiRank) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.isPro != rhs.isPro { return !lhs.isPro && rhs.isPro }
            return false
        }
    }

    static func geminiRank(_ slug: String) -> GeminiRank {
        let lower = slug.lowercased()
        var major = 0
        var minor = 0
        let pattern = #"(?:^|[-_/])v?(\d{1,2})(?:\.(\d+))?(?:[-_/]|$)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = lower as NSString
            let matches = regex.matches(in: lower, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let matchedStr = ns.substring(with: m.range)
                if matchedStr.contains("b") || matchedStr.contains("k") || matchedStr.contains("m") { continue }
                let majStr = ns.substring(with: m.range(at: 1))
                let minStr = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : "0"
                if let maj = Int(majStr), let min = Int(minStr) {
                    if maj < 50 {
                        major = maj
                        minor = min
                        break
                    }
                }
            }
        }
        let isPro = lower.contains("pro")
        let tier: Int
        if lower.contains("max") { tier = 5 }
        else if lower.contains("high") { tier = 4 }
        else if lower.contains("medium") { tier = 3 }
        else if lower.contains("low") { tier = 2 }
        else if lower.contains("image") { tier = 1 }
        else { tier = 0 }
        return GeminiRank(major: major, minor: minor, tier: tier, isPro: isPro)
    }

    static func isOlderGemini(_ a: String, than b: String) -> Bool {
        let ra = geminiRank(a), rb = geminiRank(b)
        if ra != rb { return ra < rb }
        return a > b
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
