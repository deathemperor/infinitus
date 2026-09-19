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
    /// Last known active slot per provider, so a switch mid-flight
    /// (`activeUnreadable`) carries it forward instead of flashing "no
    /// active account" (#476). A struct engine can't hold state itself —
    /// this is the reference-typed sliver that does.
    let memory: SwapdActiveMemory

    public init(cli: SwapdCLI) {
        self.cli = cli
        self.memory = SwapdActiveMemory()
    }

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
        .refreshAccount, .autoIgnite,
    ]

    public func snapshot() async throws -> [EngineFleet] {
        let list = try await cli.list()
        memory.keep(list)
        return fleets(of: list)
    }

    private func fleets(of list: SwapdList) -> [EngineFleet] {
        let fleets = SwapdMapping.fleets(from: list, engineID: Self.engineID,
                                         carriedActive: { [memory] provider in memory.last(provider) })
        for view in list.providers {
            let provider = SwapdMapping.provider(for: view.provider)
            guard let fleet = fleets.first(where: { $0.provider == provider }) else { continue }
            memory.remember(fleet, unreadable: view.activeUnreadable != nil)
        }
        return fleets
    }

    /// One forced fetch for account n, then the fleet as it reads AFTER it
    /// — the caller publishes that instead of waiting for the next poll.
    public func refresh(fleet: Provider, number: Int) async throws -> EngineFleet {
        let list = try await cli.refresh(provider: fleet, slot: number)
        let result = try Self.fleet(from: list, provider: fleet, carriedActive: memory.last(fleet))
        if let view = list.providers.first(where: { SwapdMapping.provider(for: $0.provider) == fleet }) {
            memory.remember(result, unreadable: view.activeUnreadable != nil)
        }
        return result
    }

    /// The provider's view out of a list reply. swapd answers a
    /// single-provider verb with that provider alone, but the reply is
    /// still a full list payload, so this never assumes the index.
    static func fleet(from list: SwapdList, provider: Provider, carriedActive: Int? = nil) throws -> EngineFleet {
        guard let view = list.providers.first(where: { SwapdMapping.provider(for: $0.provider) == provider })
        else {
            throw EngineError.remote(status: 0, body: "swapd answered without a \(provider.rawValue) fleet")
        }
        return SwapdMapping.fleet(from: view, provider: provider, engineID: engineID, carriedActive: carriedActive)
    }

    public func switchTo(fleet: Provider, number: Int) async throws {
        try await cli.switchTo(provider: fleet, slot: number)
    }
    public func rotate(fleet: Provider) async throws { try await cli.rotate(provider: fleet) }
    /// Every flag edit answers with its provider's board as it reads after
    /// the write. Laid over the last full list that is the engine's next
    /// snapshot, so the refresh pass takes it instead of running `list`
    /// again (#1481). Nil before the first `list`: there is nothing to
    /// lay it over, and the pass asks as usual.
    public func reorder(fleet: Provider, _ numbers: [Int]) async throws -> [EngineFleet]? {
        edited(try await cli.reorder(provider: fleet, numbers))
    }
    public func setHold(fleet: Provider, number: Int, held: Bool) async throws -> [EngineFleet]? {
        edited(try await cli.setHold(provider: fleet, slot: number, held: held))
    }
    public func setPreferred(fleet: Provider, number: Int, _ on: Bool) async throws -> [EngineFleet]? {
        edited(try await cli.setPreferred(provider: fleet, slot: number, on))
    }
    public func setAutoIgnite(fleet: Provider, number: Int, _ on: Bool) async throws -> [EngineFleet]? {
        edited(try await cli.setAutoIgnite(provider: fleet, slot: number, on))
    }
    private func edited(_ reply: SwapdList) -> [EngineFleet]? {
        memory.merged(with: reply).map(fleets(of:))
    }
    /// `swapd ignite <slot>`: the driver's cheapest request under that
    /// slot's own login, then a forced fetch. The fleet stays put.
    public func ignite(fleet: Provider, number: Int) async throws {
        _ = try await cli.ignite(provider: fleet, slot: number)
    }
    public func rename(fleet: Provider, number: Int, _ name: String) async throws -> [EngineFleet]? {
        edited(try await cli.setAlias(provider: fleet, slot: number, name))
    }
    public func remove(fleet: Provider, number: Int) async throws {
        try await cli.removeAccount(provider: fleet, slot: number)
    }
    /// No fleet argument on the protocol's add verbs: swapd's default
    /// provider is claude, which is the fleet this can be reached from.
    public func addCurrent() async throws { try await cli.addCurrent(provider: .claude) }
    public func addToken(_ token: String) async throws { try await cli.addToken(provider: .claude, token) }
}

/// The one bit of state `SwapdEngine` (a struct) can't hold itself: the
/// last known active slot per provider, so a switch mid-flight
/// (`activeUnreadable`) carries it forward across polls instead of
/// flashing "no active account" (#476).
final class SwapdActiveMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActive: [Provider: Int] = [:]
    private var lastList: SwapdList?

    func keep(_ list: SwapdList) {
        lock.lock(); defer { lock.unlock() }
        lastList = list
    }

    /// The last full list with `reply`'s providers laid over it — a
    /// single-provider verb answers with that provider alone — kept as the
    /// new last list. Nil when no full list has been read yet.
    func merged(with reply: SwapdList) -> SwapdList? {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastList else { return nil }
        let fresh = Dictionary(reply.providers.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(last.providers.map(\.provider))
        let list = SwapdList(
            schemaVersion: reply.schemaVersion,
            providers: last.providers.map { fresh[$0.provider] ?? $0 }
                + reply.providers.filter { !known.contains($0.provider) })
        lastList = list
        return list
    }

    /// `activeSlot` present ⇒ remember it (this also re-remembers a
    /// carried slot, harmlessly). Absent with `unreadable` ⇒ swapd knows
    /// but couldn't say — keep whatever's remembered. Absent with neither
    /// ⇒ genuinely no active account: forget this provider.
    func remember(_ fleet: EngineFleet, unreadable: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let active = fleet.activeNumber {
            lastActive[fleet.provider] = active
        } else if !unreadable {
            lastActive[fleet.provider] = nil
        }
    }

    func last(_ provider: Provider) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return lastActive[provider]
    }
}
#endif
