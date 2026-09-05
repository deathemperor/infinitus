import Foundation
import Combine
import InfinitusCore

/// The enabled engines and the fleets they last reported (#8). One
/// FleetState per (engine, provider), created on first sight and kept
/// for the app's life so its animation ticks survive across snapshots.
/// Order: Claude fleets first (cswap before anything else), then the
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

    /// The engine whose endpoint Claude Code is actually pointed at —
    /// set from `env.ANTHROPIC_BASE_URL` (AppModel). nil: nobody routed.
    var routedEngineID: String?

    /// The Claude fleet the popup chrome, title, resume nudge and push
    /// triggers reason about — the routed engine's when Claude Code's
    /// settings name it (2026-09-04), else cswap's when cswap is on.
    var primary: FleetState? {
        if let routed = routedEngineID,
           let fleet = fleets.first(where: { $0.provider == .claude && $0.engineID == routed }) {
            return fleet
        }
        return fleets.first { $0.provider == .claude }
    }

    /// Find or create the state for a reported fleet.
    func state(for fleet: EngineFleet) -> FleetState {
        if let existing = fleets.first(where: { $0.id == fleet.key }) { return existing }
        guard let engine = engine(id: fleet.engineID) else {
            preconditionFailure("fleet from unregistered engine \(fleet.engineID)")
        }
        let state = FleetState(fleet: fleet, engine: engine, host: host)
        if fleet.engineID == CswapEngine.engineID, let usage = host.usageModel {
            state.follow(usage)
        }
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

    private static func rank(_ f: FleetState) -> Int {
        f.provider == .claude ? 0 : 1
    }

    private func engineIndex(_ id: String) -> Int {
        engines.firstIndex { $0.id == id } ?? .max
    }
}
