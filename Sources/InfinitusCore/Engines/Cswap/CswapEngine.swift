import Foundation

#if !os(iOS)
/// The claude-swap engine behind the `AccountEngine` seam (#8): one
/// Claude fleet, every capability, `list --json` bytes kept verbatim
/// for the mirror. The supervised `cswap auto` child stays
/// CswapSupervisor's job — this is the one-shot command side only.
public struct CswapEngine: AccountEngine {
    public static let engineID = "cswap"
    public let cli: CswapCLI

    public init(cli: CswapCLI) { self.cli = cli }

    public var id: String { Self.engineID }
    public var displayName: String { "cswap" }
    public var capabilities: EngineCapabilities { .all }

    public func snapshot() async throws -> [EngineFleet] {
        // Pick-first lives in the engine's settings (autoswitch.preferred,
        // claude-swap PR #312); read alongside the list so the refresh
        // takes no longer. An engine without the key leaves every row's
        // `preferred` nil, which is what hides the star.
        async let config: ConfigList? = try? cli.configList()
        let (list, raw) = try await cli.accountListRaw()
        let preferred = await config.flatMap(Self.preferredTokens)
        return [Self.fleet(from: list, raw: raw, preferred: preferred)]
    }

    public static let preferredKey = "autoswitch.preferred"

    /// The lowercased tokens (emails and/or slot numbers) of
    /// `autoswitch.preferred`; nil when this cswap has no such key.
    public static func preferredTokens(_ config: ConfigList) -> Set<String>? {
        guard let entry = config.settings.first(where: { $0.key == preferredKey }) else { return nil }
        guard entry.isSet, case .string(let text) = entry.value else { return [] }
        return Set(text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    /// Pure: the same mapping the launch cache used to apply by hand.
    public static func fleet(from list: AccountList, raw: Data?,
                             preferred: Set<String>? = nil) -> EngineFleet {
        let accounts = preferred.map { tokens in
            list.accounts.map {
                $0.preferring(tokens.contains($0.email.lowercased()) || tokens.contains(String($0.number)))
            }
        } ?? list.accounts
        return EngineFleet(engineID: engineID, provider: .claude,
                    accounts: accounts,
                    activeNumber: list.activeAccountNumber,
                    nextCandidate: list.nextCandidate,
                    nextRecovery: list.nextRecovery,
                    liveSessions: list.liveSessions,
                    raw: raw)
    }

    public func switchTo(fleet: Provider, number: Int) async throws {
        try await cli.switchTo(number)
    }
    public func rotate(fleet: Provider) async throws { try await cli.rotate() }
    public func reorder(fleet: Provider, _ numbers: [Int]) async throws {
        try await cli.reorder(numbers)
    }
    public func setHold(fleet: Provider, number: Int, held: Bool) async throws {
        try await cli.setRotation(number, enabled: !held)
    }
    /// Star = add the account's email to autoswitch.preferred (emails, not
    /// slots: reorder moves slots). Off also drops a slot-number token
    /// someone set by hand for it.
    public func setPreferred(fleet: Provider, number: Int, _ on: Bool) async throws {
        guard var tokens = Self.preferredTokens(try await cli.configList()) else {
            throw EngineError.unsupported("prefer: this cswap has no \(Self.preferredKey) setting (claude-swap PR #312)")
        }
        guard let account = try await cli.accountList().accounts.first(where: { $0.number == number }) else {
            throw EngineError.remote(status: 0, body: "no account #\(number)")
        }
        let email = account.email.lowercased()
        if on { tokens.insert(email) } else { tokens.remove(email); tokens.remove(String(number)) }
        try await cli.setConfig(Self.preferredKey, tokens.isEmpty ? nil : tokens.sorted().joined(separator: ","))
    }
    /// `cswap run <n> -- -p . --max-turns 1`: one ~1K-token request under
    /// the account's own CLAUDE_CONFIG_DIR. PATH is widened to where
    /// `claude` lives — `cswap run` resolves it with `which`, and a GUI
    /// app's inherited PATH doesn't reach it.
    public func ignite(fleet: Provider, number: Int) async throws {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(home)/.claude/local", "\(home)/.local/bin",
                     "/opt/homebrew/bin", "/usr/local/bin",
                     (cli.binaryPath as NSString).deletingLastPathComponent]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        _ = try await cli.run(WindowPlanner.igniterArguments(number: number), environment: env)
    }
    public func rename(fleet: Provider, number: Int, _ name: String) async throws {
        try await cli.setAlias(number, name)
    }
    public func remove(fleet: Provider, number: Int) async throws {
        try await cli.removeAccount(number)
    }
    public func addCurrent() async throws { try await cli.addCurrent() }
    public func addToken(_ token: String) async throws { try await cli.addToken(token) }
    public func usageReport(days: Int) async throws -> UsageReport {
        try await cli.usageReport(days: days)
    }
    public func exportAccounts(to path: URL, account: Int?, full: Bool) async throws {
        try await cli.exportAccounts(to: path, account: account, full: full)
    }
    public func importAccounts(from path: URL, force: Bool) async throws {
        try await cli.importAccounts(from: path, force: force)
    }
}
#endif
