import Foundation

/// Another machine's engine as one `AccountEngine` here. It reads
/// nothing itself: `snapshot()` answers the fleets the desktop pushed
/// last, and every action queues one control command for that machine,
/// then waits for the desktop to run it there and report back. So a
/// peer fleet renders and acts through the same `FleetState` as a local
/// one, and nothing in the popup has to know which is which.
public actor PeerEngine: AccountEngine {
    public nonisolated let id: String
    public nonisolated let machine: String
    public nonisolated let machineLabel: String
    public nonisolated let remoteEngine: String
    public nonisolated let capabilities: EngineCapabilities
    private let queue: PeerCommandQueue
    private var fleets: [EngineFleet]
    private var connected: Bool

    /// Named after the machine, so a fleet header reads "Claude · HyperNovae swapd".
    public nonisolated var displayName: String { "\(machineLabel) \(remoteEngine)" }

    public init(machine: String, machineLabel: String, remoteEngine: String,
                capabilities: EngineCapabilities, fleets: [EngineFleet], connected: Bool,
                queue: PeerCommandQueue) {
        self.id = PeerFleets.engineID(machine: machine, remoteEngine: remoteEngine)
        self.machine = machine
        self.machineLabel = machineLabel
        self.remoteEngine = remoteEngine
        self.capabilities = capabilities
        self.fleets = fleets
        self.connected = connected
        self.queue = queue
    }

    /// The desktop pushed again: what the popup's next refresh will show.
    public func update(fleets: [EngineFleet], connected: Bool) {
        self.fleets = fleets
        self.connected = connected
    }

    public func snapshot() async throws -> [EngineFleet] {
        guard connected else { throw EngineError.unreachable("\(machineLabel) is not connected") }
        return fleets
    }

    private func send(_ command: String, fleet: Provider, _ rest: [String],
                      options: [String: String] = [:]) async throws {
        let key = fleets.first { $0.provider == fleet }?.remoteKey ?? ""
        try await queue.run(PeerFleets.Command(machine: machine, command: command,
                                               args: [key] + rest, options: options))
    }

    public func switchTo(fleet: Provider, number: Int) async throws {
        try await send("switch", fleet: fleet, [String(number)])
    }

    public func rotate(fleet: Provider) async throws {
        try await send("rotate", fleet: fleet, [])
    }

    public func setHold(fleet: Provider, number: Int, held: Bool) async throws -> [EngineFleet]? {
        try await send(held ? "hold" : "unhold", fleet: fleet, [String(number)])
        return nil
    }

    public func setPreferred(fleet: Provider, number: Int, _ on: Bool) async throws -> [EngineFleet]? {
        try await send("prefer", fleet: fleet, [String(number), on ? "on" : "off"])
        return nil
    }

    public func setAutoIgnite(fleet: Provider, number: Int, _ on: Bool) async throws -> [EngineFleet]? {
        try await send("auto-ignite", fleet: fleet, [String(number), on ? "on" : "off"])
        return nil
    }

    public func rename(fleet: Provider, number: Int, _ name: String) async throws -> [EngineFleet]? {
        try await send("rename", fleet: fleet, [String(number), name])
        return nil
    }

    public func remove(fleet: Provider, number: Int) async throws {
        try await send("remove", fleet: fleet, [String(number)], options: ["yes": "true"])
    }
}

extension EngineFleet {
    /// The fleet's key on the machine that owns it (`swapd/claude`), which
    /// a command for that machine names. A peer engine's id carries the
    /// remote engine's id after its last colon.
    var remoteKey: String {
        let remoteEngine = engineID.split(separator: ":").last.map(String.init) ?? engineID
        return "\(remoteEngine)/\(provider.rawValue)"
    }
}
