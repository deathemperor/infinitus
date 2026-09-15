import Foundation

extension TeamDocs {
    /// `fleet.json` — every account of every engine fleet as the popup
    /// sees them, for a teammate's read-only view (#221). Purpose-built
    /// rather than an `Account` encoding: a field added to `Account`
    /// later can never leak into the store by accident, and the email
    /// never travels — an account is its alias, else `#n`.
    public struct FleetDoc: Codable, Equatable, Sendable {
        public struct AccountRow: Codable, Equatable, Sendable {
            public var label: String
            /// Subscription tier ("Max 20x", "Pro"); nil when the engine has none.
            public var tier: String?
            /// `ok` | `limited` (a window in the 90s) | `dead` (a window
            /// maxed) | `expiredLogin` (the credential needs a human) |
            /// `held` (taken out of rotation).
            public var status: String
            public var active: Bool
            /// The session and weekly windows, labelled `5h` / `7d`.
            public var windows: [Window]
            /// The per-model windows, labelled by model name.
            public var models: [Window]
            public init(label: String, tier: String?, status: String, active: Bool,
                        windows: [Window], models: [Window]) {
                self.label = label; self.tier = tier; self.status = status; self.active = active
                self.windows = windows; self.models = models
            }
        }

        public struct FleetRow: Codable, Equatable, Sendable {
            public var engine: String
            /// Labels, as in `accounts`.
            public var active: String?
            public var next: String?
            public var tokensPerMinute: Double?
            public var lastSwitchAt: Int?
            public var lastSwitchReason: String?
            public var accounts: [AccountRow]
            public init(engine: String, active: String?, next: String?, tokensPerMinute: Double? = nil,
                        lastSwitchAt: Int? = nil, lastSwitchReason: String? = nil, accounts: [AccountRow]) {
                self.engine = engine; self.active = active; self.next = next
                self.tokensPerMinute = tokensPerMinute; self.lastSwitchAt = lastSwitchAt
                self.lastSwitchReason = lastSwitchReason; self.accounts = accounts
            }
        }

        public var schema = 1
        public var at: Int
        public var fleets: [FleetRow]
        public init(at: Int, fleets: [FleetRow]) { self.at = at; self.fleets = fleets }

        public static let ok = "ok", limited = "limited", dead = "dead", expiredLogin = "expiredLogin", held = "held"
        /// A window at or past this is "limited": the account is about to
        /// die, which is what a teammate wants to know.
        public static let limitedPct = 90.0
        /// `usageStatus` values that mean the credential needs a human;
        /// the rest (`api_key`, a locked keychain) leave the row `ok`.
        static let expiredStatuses: Set<String> = ["relogin_required", "token_expired", "no_credentials"]

        public static func label(_ account: Account) -> String {
            if let alias = account.alias, !alias.isEmpty { return alias }
            return "#\(account.number)"
        }

        public static func status(_ account: Account) -> String {
            if account.disabled == true { return held }
            if expiredStatuses.contains(account.usageStatus) { return expiredLogin }
            if AccountVitals.isDead(account.usage) { return dead }
            let pcts = [account.usage?.fiveHour?.pct, account.usage?.sevenDay?.pct].compactMap { $0 }
                + (account.usage?.scoped ?? []).map(\.pct)
            return pcts.contains { $0 >= limitedPct } ? limited : ok
        }

        static func window(_ label: String, _ w: UsageWindow) -> Window {
            Window(label: label, pct: Int(w.pct.rounded()),
                   resetsAt: WeeklyRoll.parse(w.resetsAt).map { Int($0.timeIntervalSince1970) })
        }

        /// Pure: one row per fleet from what the popup already holds.
        /// `EngineFleet.raw` is never read — only the decoded accounts.
        public static func row(_ fleet: EngineFleet, tokensPerMinute: Double? = nil,
                               lastSwitchAt: Int? = nil, lastSwitchReason: String? = nil) -> FleetRow {
            let accounts = fleet.accounts.map { a in
                AccountRow(label: label(a), tier: a.plan, status: status(a), active: a.number == fleet.activeNumber,
                           windows: [a.usage?.fiveHour.map { window("5h", $0) },
                                     a.usage?.sevenDay.map { window("7d", $0) }].compactMap { $0 },
                           models: (a.usage?.scoped ?? []).map { window($0.name ?? "?", $0) })
            }
            func name(_ number: Int?) -> String? {
                fleet.accounts.first { $0.number == number }.map(label)
            }
            return FleetRow(engine: fleet.engineID, active: name(fleet.activeNumber), next: name(fleet.nextCandidate),
                            tokensPerMinute: tokensPerMinute, lastSwitchAt: lastSwitchAt,
                            lastSwitchReason: lastSwitchReason, accounts: accounts)
        }
    }
}
