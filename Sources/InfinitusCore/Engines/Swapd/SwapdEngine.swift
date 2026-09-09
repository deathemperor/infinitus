import Foundation

#if !os(iOS)
/// The swapd engine behind the `AccountEngine` seam (#8): one `list --json`
/// yields one fleet per provider it holds, and every action is one
/// `swapd … --json` subprocess. Nothing here reads `~/.swapd`.
///
/// Beside cswap, not instead of it: both may be enabled during the
/// transition, and the app assumes neither exists.
public struct SwapdEngine: AccountEngine {
    public static let engineID = "swapd"
    public let cli: SwapdCLI

    public init(cli: SwapdCLI) { self.cli = cli }

    public var id: String { Self.engineID }
    public var displayName: String { "swapd" }
    public var capabilities: EngineCapabilities { Self.engineCapabilities }

    /// Everything cswap does except the three swapd has no verb for:
    /// `usage` (no cost report), OAuth sign-in (`add-token` and `add`
    /// only), and away-push channels (`notify` reports status, and never
    /// sets one). Plus `.refreshAccount`, which is its own: `refresh
    /// --slot n` forces one fetch past the serve floor.
    public static let engineCapabilities: EngineCapabilities = [
        .switch, .rotate, .reorder, .hold, .rename, .remove, .addCurrent,
        .addToken, .autoSwitch, .history, .settings, .prefer, .ignite,
        .backup, .refreshAccount,
    ]

    public func snapshot() async throws -> [EngineFleet] {
        SwapdMapping.fleets(from: try await cli.list(), engineID: Self.engineID)
    }

    /// One forced fetch for account n, then the fleet as it reads AFTER it
    /// — the caller publishes that instead of waiting for the next poll.
    public func refresh(fleet: Provider, number: Int) async throws -> EngineFleet {
        try Self.fleet(from: try await cli.refresh(provider: fleet, slot: number), provider: fleet)
    }

    /// The provider's view out of a list reply. swapd answers a
    /// single-provider verb with that provider alone, but the reply is
    /// still a full list payload, so this never assumes the index.
    static func fleet(from list: SwapdList, provider: Provider) throws -> EngineFleet {
        guard let view = list.providers.first(where: { SwapdMapping.provider(for: $0.provider) == provider })
        else {
            throw EngineError.remote(status: 0, body: "swapd answered without a \(provider.rawValue) fleet")
        }
        return SwapdMapping.fleet(from: view, provider: provider, engineID: engineID)
    }

    public func switchTo(fleet: Provider, number: Int) async throws {
        try await cli.switchTo(provider: fleet, slot: number)
    }
    public func rotate(fleet: Provider) async throws { try await cli.rotate(provider: fleet) }
    public func reorder(fleet: Provider, _ numbers: [Int]) async throws {
        _ = try await cli.reorder(provider: fleet, numbers)
    }
    public func setHold(fleet: Provider, number: Int, held: Bool) async throws {
        _ = try await cli.setHold(provider: fleet, slot: number, held: held)
    }
    public func setPreferred(fleet: Provider, number: Int, _ on: Bool) async throws {
        _ = try await cli.setPreferred(provider: fleet, slot: number, on)
    }
    /// `swapd ignite <slot>`: the driver's cheapest request under that
    /// slot's own login, then a forced fetch. The fleet stays put.
    public func ignite(fleet: Provider, number: Int) async throws {
        _ = try await cli.ignite(provider: fleet, slot: number)
    }
    public func rename(fleet: Provider, number: Int, _ name: String) async throws {
        _ = try await cli.setAlias(provider: fleet, slot: number, name)
    }
    public func remove(fleet: Provider, number: Int) async throws {
        try await cli.removeAccount(provider: fleet, slot: number)
    }
    /// No fleet argument on the protocol's add verbs: swapd's default
    /// provider is claude, which is the fleet this can be reached from.
    public func addCurrent() async throws { try await cli.addCurrent(provider: .claude) }
    public func addToken(_ token: String) async throws { try await cli.addToken(provider: .claude, token) }
    public func exportAccounts(to path: URL, account: Int?, full: Bool) async throws {
        try await cli.exportAccounts(provider: .claude, to: path, slot: account, full: full)
    }
    public func importAccounts(from path: URL, force: Bool) async throws {
        try await cli.importAccounts(provider: .claude, from: path, force: force)
    }
}
#endif
