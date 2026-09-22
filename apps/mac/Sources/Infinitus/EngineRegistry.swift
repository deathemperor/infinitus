import Foundation
import Combine
import InfinitusCore

/// The enabled engines and the fleets they last reported (#8). One
/// FleetState per (engine, provider), created on first sight and kept
/// for the app's life so its animation ticks survive across snapshots.
/// Order: Claude fleets first (swapd before anything else), then the
/// rest in registration order.
@MainActor
final class EngineRegistry: ObservableObject {
    private(set) var engines: [any AccountEngine] = []
    @Published private(set) var fleets: [FleetState] = []
    private var sinks: [String: AnyCancellable] = [:]
    unowned let host: AppModel

    init(host: AppModel) { self.host = host }

    func register(_ engine: any AccountEngine) {
        guard !engines.contains(where: { $0.id == engine.id }) else { return }
        engines.append(engine)
    }

    func engine(id: String) -> (any AccountEngine)? {
        engines.first { $0.id == id }
    }

    /// Drop an engine and the fleet states it reported — a peer machine
    /// the desktop stopped pushing (`PeerFleetsModel`). Local engines
    /// live for the app's life and never come through here.
    func remove(engineID: String) {
        engines.removeAll { $0.id == engineID }
        let gone = fleets.filter { $0.engineID == engineID }
        guard !gone.isEmpty else { return }
        for state in gone { sinks[state.id] = nil }
        fleets.removeAll { $0.engineID == engineID }
        host.forwardFleetChange()
    }

    /// This Mac's own fleets: what the `fleets` verb, the launch cache
    /// and the team publish every reason about. Never a peer's (#1545):
    /// the desktop reads this list as this machine's accounts and pushes
    /// the other machines' back, so a peer here would echo forever.
    var localFleets: [FleetState] { fleets.filter { !PeerFleets.isPeer(engineID: $0.engineID) } }
    /// Other machines' fleets, as the desktop last pushed them.
    var peerFleets: [FleetState] { fleets.filter { PeerFleets.isPeer(engineID: $0.engineID) } }

    /// The Claude fleet the popup chrome, title, resume nudge and push
    /// triggers reason about — swapd's when swapd is on. Never a peer's:
    /// another machine's accounts must not drive this one's title,
    /// notifications or switch alert.
    var primary: FleetState? { localFleets.first { $0.provider == .claude } }

    /// Find or create the state for a reported fleet.
    func state(for fleet: EngineFleet) -> FleetState {
        if let existing = fleets.first(where: { $0.id == fleet.key }) { return existing }
        guard let engine = engine(id: fleet.engineID) else {
            preconditionFailure("fleet from unregistered engine \(fleet.engineID)")
        }
        let state = FleetState(fleet: fleet, engine: engine, host: host)
        // Row changes must re-render whoever observes the host (the
        // popup chrome, the title); the host guards the return trip.
        sinks[state.id] = state.objectWillChange.sink { [weak self] _ in
            self?.host.forwardFleetChange()
        }
        fleets.append(state)
        fleets.sort { a, b in
            let ra = Self.rank(a), rb = Self.rank(b)
            if ra != rb { return ra < rb }
            return engineIndex(a.engineID) < engineIndex(b.engineID)
        }
        return state
    }

    /// Local fleets before peers, Claude first within each.
    private static func rank(_ f: FleetState) -> Int {
        (PeerFleets.isPeer(engineID: f.engineID) ? 2 : 0) + (f.provider == .claude ? 0 : 1)
    }

    private func engineIndex(_ id: String) -> Int {
        engines.firstIndex { $0.id == id } ?? .max
    }
}
