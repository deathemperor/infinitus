import Foundation
import InfinitusCore

/// The other machines' fleets in the popup (#1545). The desktop pushes
/// every paired environment's fleets over `peer-sync`; this registers one
/// `PeerEngine` per (machine, remote engine), applies each push to its
/// `FleetState`s at once, and hands the desktop the row actions those
/// fleets queued. A machine the desktop stops pushing goes stale after
/// `silence`, and is dropped after twice that: a closed desktop leaves
/// no dead rows behind.
@MainActor
final class PeerFleetsModel {
    static let silence: TimeInterval = 90

    unowned let host: AppModel
    let queue = PeerCommandQueue()
    private var engines: [String: PeerEngine] = [:]
    private(set) var lastPush: Date?

    init(host: AppModel) { self.host = host }

    /// Commands queued for the desktop and not yet answered — `status`
    /// reports it so the desktop pushes at once instead of on its clock.
    func pendingCount() async -> Int { await queue.pendingCount }

    /// One push: results first (a row waiting on one stops), then the
    /// fleets, then the queue for the desktop to run.
    func sync(_ body: PeerFleets.Body, now: Date = Date()) async -> PeerFleets.Reply {
        for result in body.results { await queue.resolve(result) }
        var seen = Set<String>()
        for machine in body.machines {
            let byEngine = Dictionary(grouping: machine.fleets ?? [], by: \.engineID)
            for (remoteEngine, docs) in byEngine {
                let engineID = PeerFleets.engineID(machine: machine.id, remoteEngine: remoteEngine)
                seen.insert(engineID)
                let fleets = docs.map { PeerFleets.engineFleet($0, engineID: engineID) }
                let caps = PeerFleets.capabilities(named: docs.first?.capabilities ?? [])
                if let engine = engines[engineID], engine.capabilities == caps, engine.machineLabel == machine.label {
                    await engine.update(fleets: fleets, connected: machine.connected)
                } else {
                    if engines[engineID] != nil { host.registry.remove(engineID: engineID) }
                    let engine = PeerEngine(machine: machine.id, machineLabel: machine.label,
                                            remoteEngine: remoteEngine, capabilities: caps,
                                            fleets: fleets, connected: machine.connected, queue: queue)
                    engines[engineID] = engine
                    host.registry.register(engine)
                }
                for fleet in fleets {
                    let state = host.registry.state(for: fleet)
                    if machine.connected {
                        _ = state.apply(fleet)
                    } else {
                        state.markStale(reason: "\(machine.label) is not connected", lastGood: lastPush, now: now)
                    }
                }
            }
        }
        for engineID in engines.keys where !seen.contains(engineID) {
            engines[engineID] = nil
            host.registry.remove(engineID: engineID)
        }
        lastPush = now
        host.forwardFleetChange()
        return PeerFleets.Reply(commands: await queue.drain())
    }

    /// Rides the refresh tick: a desktop gone quiet marks its peers
    /// unreachable (their `snapshot()` throws, so the pass ages the rows),
    /// then drops them.
    func expireSilent(now: Date = Date()) async {
        guard let lastPush, !engines.isEmpty else { return }
        let quiet = now.timeIntervalSince(lastPush)
        if quiet > Self.silence * 2 {
            for engineID in engines.keys { host.registry.remove(engineID: engineID) }
            engines = [:]
            self.lastPush = nil
        } else if quiet > Self.silence {
            for engine in engines.values { await engine.update(fleets: [], connected: false) }
        }
    }
}
