import Foundation

// MARK: - CLIProxyAPI wire shapes → InfinitusCore models
//
// Pure mapping layer for the CLIProxyAPI Management API (upstream
// router-for-me/CLIProxyAPI @ 81e1b53) — no networking, no Process. The
// engine (CLIProxyEngine, elsewhere) does the HTTP; this file only turns
// bytes it already fetched into `EngineFleet`/`Account`/`Usage`. Field
// names mirror the wire's snake_case verbatim via CodingKeys so decoding
// needs no key-conversion strategy, and unknown keys are ignored for free
// (Decodable's default behaviour).

/// `GET /v0/management/auth-files` roster entry. Only `name` is required —
/// every other field is additive on the wire and optional here; `id` is
/// absent on some proxy versions, so callers fall back to `name`.
public struct ProxyAuthFile: Decodable, Sendable {
    public let id: String?
    public let authIndex: String?
    public let name: String
    public let provider: String?
    public let label: String?
    public let status: String?
    public let statusMessage: String?
    public let disabled: Bool?
    public let unavailable: Bool?
    public let email: String?
    public let accountType: String?
    public let account: String?
    public let priority: Int?
    public let note: String?
    public let weight: Int?
    public let success: Int?
    public let failed: Int?
    public let nextRetryAfter: String?
    public let quota: Quota?

    public struct Quota: Decodable, Sendable {
        public let observedAt: String?
        public let signals: [String: String]?

        enum CodingKeys: String, CodingKey {
            case observedAt = "observed_at"
            case signals
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, label, status, disabled, unavailable, email,
             account, priority, note, weight, success, failed, quota
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case accountType = "account_type"
        case nextRetryAfter = "next_retry_after"
    }

    /// Decodable's synthesized `init(from:)` suppresses the implicit
    /// memberwise init — restated for tests that hand-build entries.
    public init(id: String?, authIndex: String?, name: String, provider: String?,
                label: String?, status: String?, statusMessage: String?, disabled: Bool?,
                unavailable: Bool?, email: String?, accountType: String?, account: String?,
                priority: Int?, note: String?, weight: Int?, success: Int?, failed: Int?,
                nextRetryAfter: String?, quota: Quota?) {
        self.id = id
        self.authIndex = authIndex
        self.name = name
        self.provider = provider
        self.label = label
        self.status = status
        self.statusMessage = statusMessage
        self.disabled = disabled
        self.unavailable = unavailable
        self.email = email
        self.accountType = accountType
        self.account = account
        self.priority = priority
        self.note = note
        self.weight = weight
        self.success = success
        self.failed = failed
        self.nextRetryAfter = nextRetryAfter
        self.quota = quota
    }
}

public struct ProxyAuthFileList: Decodable, Sendable {
    public let files: [ProxyAuthFile]
}

/// `POST /api-call` → `https://api.anthropic.com/api/oauth/profile`.
///
/// Shape verified against `~/CLIProxyAPI/static/management.html`'s own
/// profile handling (the frontend that talks to this exact endpoint) —
/// `oauth.py`'s `fetch_oauth_profile` only extracts `account.uuid`/`email`
/// and `organization.uuid` for its own narrower identity-resolution need,
/// so it does not attest the `plan` fields; CPAMC's `nw()` function does:
/// `account.has_claude_max` / `account.has_claude_pro` /
/// `organization.organization_type` / `organization.subscription_status`.
/// `organization.name` itself is unverified (CPAMC never reads it) but is
/// the natural sibling of the already-verified `organization.uuid`.
public struct ProxyProfile: Sendable, Equatable {
    public let organizationName: String?
    public let organizationUuid: String?
    public let plan: String?

    struct Wire: Decodable {
        struct Account: Decodable {
            let uuid: String?
            let hasClaudeMax: Bool?
            let hasClaudePro: Bool?
            enum CodingKeys: String, CodingKey {
                case uuid
                case hasClaudeMax = "has_claude_max"
                case hasClaudePro = "has_claude_pro"
            }
        }
        struct Organization: Decodable {
            let uuid: String?
            let name: String?
            let organizationType: String?
            let subscriptionStatus: String?
            let rateLimitTier: String?
            enum CodingKeys: String, CodingKey {
                case uuid, name
                case organizationType = "organization_type"
                case subscriptionStatus = "subscription_status"
                case rateLimitTier = "rate_limit_tier"
            }
        }
        let account: Account?
        let organization: Organization?
    }

    /// nil unless `account.uuid` is a non-empty string — same fail-open
    /// boundary as `oauth.fetch_oauth_profile`.
    public static func parse(_ data: Data) -> ProxyProfile? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let uuid = wire.account?.uuid, !uuid.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return ProxyProfile(
            organizationName: wire.organization?.name,
            organizationUuid: wire.organization?.uuid,
            plan: planLabel(hasMax: wire.account?.hasClaudeMax, hasPro: wire.account?.hasClaudePro,
                            orgType: wire.organization?.organizationType,
                            subscriptionStatus: wire.organization?.subscriptionStatus,
                            rateLimitTier: wire.organization?.rateLimitTier)
        )
    }

    /// Port of CPAMC's `nw()`: has_claude_max wins outright, then
    /// has_claude_pro, then an active Claude Team org, then both max/pro
    /// false reads as Free; anything else is unknown.
    /// `rateLimitTier` ("default_claude_max_20x", live 2026-09-02) adds
    /// the multiplier so the chip reads "Max 20x" like cswap's.
    static func planLabel(hasMax: Bool?, hasPro: Bool?, orgType: String?,
                          subscriptionStatus: String?, rateLimitTier: String? = nil) -> String? {
        if hasMax == true {
            if let tier = rateLimitTier,
               let r = tier.range(of: #"[0-9]+x$"#, options: .regularExpression) {
                return "Max \(tier[r])"
            }
            return "Max"
        }
        if hasPro == true { return "Pro" }
        if orgType?.lowercased() == "claude_team", subscriptionStatus?.lowercased() == "active" {
            return "Team"
        }
        if hasMax == false, hasPro == false { return "Free" }
        return nil
    }
}

/// `POST /api-call` → `https://api.anthropic.com/api/oauth/usage` — the raw
/// body normalizer, port of `claude_swap.oauth.build_usage_result`.
public enum OAuthUsage {
    struct Wire: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        struct ExtraUsage: Decodable {
            let isEnabled: Bool?
            let usedCredits: Double?
            let monthlyLimit: Double?
            let utilization: Double?
            let currency: String?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case isEnabled = "is_enabled"
                case usedCredits = "used_credits"
                case monthlyLimit = "monthly_limit"
                case utilization, currency
                case resetsAt = "resets_at"
            }
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let displayName: String?
                    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
                }
                let model: Model?
            }
            let scope: Scope?
            let percent: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case scope, percent
                case resetsAt = "resets_at"
            }
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let extraUsage: ExtraUsage?
        let limits: [Limit]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case extraUsage = "extra_usage"
            case limits
        }
    }

    /// nil when nothing usable came back — mirrors `build_usage_result`
    /// returning `None` when every section was absent/unusable.
    public static func parse(_ data: Data, now: Date = Date()) -> Usage? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }

        func resetFields(_ resetsAt: String?) -> (countdown: String?, clock: String?) {
            guard let resetsAt, let date = WeeklyRoll.parse(resetsAt) else { return (nil, nil) }
            return (ResetFormat.countdown(until: date, now: now), ResetFormat.clock(date, now: now))
        }

        var fiveHour: UsageWindow?
        if let w = wire.fiveHour {
            let (countdown, clock) = resetFields(w.resetsAt)
            fiveHour = UsageWindow(pct: w.utilization, resetsAt: w.resetsAt,
                                   countdown: countdown, clock: clock)
        }

        var sevenDay: UsageWindow?
        if let w = wire.sevenDay {
            let (countdown, clock) = resetFields(w.resetsAt)
            sevenDay = UsageWindow(pct: w.utilization, resetsAt: w.resetsAt,
                                   countdown: countdown, clock: clock)
        }

        var spend: Spend?
        if let eu = wire.extraUsage, eu.isEnabled == true,
           let used = eu.usedCredits, let limit = eu.monthlyLimit, let pct = eu.utilization {
            let (countdown, clock) = resetFields(eu.resetsAt)
            spend = Spend(used: used / 100, limit: limit / 100, pct: pct,
                         currency: eu.currency ?? "USD", resetsAt: eu.resetsAt,
                         countdown: countdown, clock: clock)
        }

        var scoped: [UsageWindow] = []
        for lim in wire.limits ?? [] {
            guard let name = lim.scope?.model?.displayName, !name.isEmpty,
                  let pct = lim.percent else { continue }
            let (countdown, clock) = resetFields(lim.resetsAt)
            scoped.append(UsageWindow(pct: pct, resetsAt: lim.resetsAt,
                                      countdown: countdown, clock: clock, name: name))
        }

        if fiveHour == nil, sevenDay == nil, spend == nil, scoped.isEmpty { return nil }
        return Usage(fiveHour: fiveHour, sevenDay: sevenDay,
                    scoped: scoped.isEmpty ? nil : scoped, spend: spend)
    }
}

/// Port of `oauth.format_reset` / `reset_clock_string` — countdown and wall
/// clock strings, local time.
public enum ResetFormat {
    /// "3d 5h" / "2h 23m" / "17m" — exact port of `format_reset`'s
    /// countdown half.
    public static func countdown(until: Date, now: Date) -> String {
        let total = max(0, Int(until.timeIntervalSince(now)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// "20:39" same local day, else "Jul 5 08:59" — delegates to
    /// `ResetLabel.clockString` (DisplayLogic.swift), an identical port of
    /// `reset_clock_string` already living in this module.
    public static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        ResetLabel.clockString(date, now: now, calendar: calendar)
    }
}

/// Groups `/auth-files` entries into per-provider fleets and computes the
/// same advisories the cswap engine emits, over the shared `AutoOrder` /
/// `RecoveryMath` / `AccountVitals` math — never reimplemented here.
public enum ProxyMapping {
    public static func provider(for raw: String) -> Provider {
        let lower = raw.lowercased()
        switch lower {
        case "claude", "anthropic": return .claude
        case "codex", "openai": return .codex
        case "kiro": return .kiro
        default:
            if lower.hasPrefix("gemini") || lower.hasPrefix("antigravity") { return .gemini }
            return .other
        }
    }

    /// `usage`/`profiles` are keyed by auth-file `name`. `ordinals[provider]`
    /// lists names in ordinal order — index 0 is `Account.number == 1`.
    public static func fleets(engineID: String, files: [ProxyAuthFile],
                              usage: [String: Usage], profiles: [String: ProxyProfile],
                              now: Date = Date()) -> (fleets: [EngineFleet], ordinals: [Provider: [String]]) {
        var grouped: [Provider: [ProxyAuthFile]] = [:]
        for file in files {
            grouped[provider(for: file.provider ?? ""), default: []].append(file)
        }

        var ordinals: [Provider: [String]] = [:]
        var fleets: [EngineFleet] = []
        let order: [Provider] = [.claude, .codex, .gemini, .other]

        for provider in order {
            guard let group = grouped[provider], !group.isEmpty else { continue }
            // Ordinal order: authIndex numeric when it parses, else last;
            // ties broken by name. Stable across snapshots regardless of
            // the wire's own array order.
            let sorted = group.sorted { a, b in
                let ai = a.authIndex.flatMap(Int.init) ?? Int.max
                let bi = b.authIndex.flatMap(Int.init) ?? Int.max
                if ai != bi { return ai < bi }
                return a.name < b.name
            }
            ordinals[provider] = sorted.map(\.name)

            // Active: highest priority among enabled, available files
            // (missing priority = 0); ties favor the lower ordinal, which
            // falls out for free since we scan in ascending ordinal order
            // and only replace on a STRICTLY higher priority.
            var activeName: String?
            var bestPriority = Int.min
            // Starred = above the fleet's priority floor (see
            // CLIProxyEngine.setPreferred); the active one always is.
            let floor = sorted.map { $0.priority ?? 0 }.min() ?? 0
            for file in sorted where file.disabled != true && file.unavailable != true {
                let priority = file.priority ?? 0
                if activeName == nil || priority > bestPriority {
                    bestPriority = priority
                    activeName = file.name
                }
            }

            var accounts: [Account] = []
            for (index, file) in sorted.enumerated() {
                let profile = profiles[file.name]
                let fileUsage = usage[file.name]
                accounts.append(Account(
                    number: index + 1,
                    email: file.email ?? file.account ?? file.label ?? file.name,
                    organizationName: profile?.organizationName ?? "",
                    organizationUuid: profile?.organizationUuid ?? "",
                    isOrganization: false,
                    active: file.name == activeName,
                    usageStatus: usageStatus(for: file),
                    usage: fileUsage,
                    alias: (file.note?.isEmpty == false) ? file.note : nil,
                    plan: profile?.plan,
                    disabled: file.disabled == true ? true : nil,
                    preferred: (file.priority ?? 0) > floor,
                    usageFetchedAt: fileUsage != nil ? isoString(now) : nil
                ))
            }

            let activeNumber = accounts.first(where: \.active)?.number
            let candidate = AutoOrder.order(accounts).first { number in
                guard number != activeNumber,
                      let account = accounts.first(where: { $0.number == number })
                else { return false }
                return account.disabled != true && !AccountVitals.isDead(account.usage)
            }
            let recovery = candidate == nil ? RecoveryMath.nextRecovery(accounts: accounts) : nil

            fleets.append(EngineFleet(engineID: engineID, provider: provider, accounts: accounts,
                                      activeNumber: activeNumber, nextCandidate: candidate,
                                      nextRecovery: recovery, liveSessions: nil, raw: nil))
        }

        return (fleets, ordinals)
    }

    /// disabled → relogin_required (a specific, actionable diagnosis beats
    /// the generic error branch — the popup's re-login row keys on this
    /// exact string) → error (unavailable, or a status the proxy itself
    /// flagged as non-"active"/"ok") → ok.
    static func usageStatus(for file: ProxyAuthFile) -> String {
        if file.disabled == true { return "disabled" }
        if let message = file.statusMessage?.lowercased(),
           message.contains("refresh") || message.contains("token") {
            return "relogin_required"
        }
        if file.unavailable == true { return "error" }
        if let status = file.status?.lowercased(), !status.isEmpty,
           status != "active", status != "ok" {
            return "error"
        }
        return "ok"
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
