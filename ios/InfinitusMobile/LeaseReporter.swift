import Foundation
import InfinitusCore

/// The phone's client-activity lease (#223 phase 5): while a screen that
/// reads per-session work is up, the Mac hears every 25 s which scopes
/// this phone watches — `sessions` from the list (every paired Mac),
/// `session(pid)` from an open feed (that session's Mac), `stats` from
/// the stats tab (the primary). Screens acquire on appear and release
/// on disappear; going to the background releases everything at once
/// (`ttlMs: 0`), coming back re-reports. Best effort: a Mac that doesn't
/// answer simply keeps no lease, and its facts fall back to today's rows.
@MainActor final class LeaseReporter {
    static let shared = LeaseReporter()
    static let ttlMs = 45_000
    static let interval: TimeInterval = 25

    enum Target: Hashable {
        /// One Mac; `nil` is the primary, as everywhere on the phone.
        case mac(String?)
        /// Every paired Mac — the sessions list shows them all.
        case everyMac
    }
    private struct Hold: Hashable { let target: Target; let scope: ClientActivity.Scope }

    weak var model: MirrorModel?
    private var holds: [Hold: Int] = [:]
    /// Macs told about a lease since the last release — each gets a
    /// `ttlMs: 0` when it stops mattering, not just a silence.
    private var reported = Set<String?>()
    private var background = false
    private var loop: Task<Void, Never>?

    func acquire(_ scope: ClientActivity.Scope, on target: Target = .mac(nil)) {
        holds[Hold(target: target, scope: scope), default: 0] += 1
        changed()
    }

    func release(_ scope: ClientActivity.Scope, on target: Target = .mac(nil)) {
        let key = Hold(target: target, scope: scope)
        guard let n = holds[key] else { return }
        if n <= 1 { holds.removeValue(forKey: key) } else { holds[key] = n - 1 }
        changed()
    }

    func scenePhase(active: Bool) {
        guard background == !active else { return }
        background = !active
        changed()
    }

    /// What this phone watches on one Mac right now.
    func scopes(for macId: String?) -> [ClientActivity.Scope] {
        var out = Set<ClientActivity.Scope>()
        for (hold, _) in holds {
            switch hold.target {
            case .everyMac: out.insert(hold.scope)
            case .mac(let id): if id == macId { out.insert(hold.scope) }
            }
        }
        return out.sorted { "\($0.type.rawValue)\($0.pid ?? 0)" < "\($1.type.rawValue)\($1.pid ?? 0)" }
    }

    private func changed() {
        loop?.cancel()
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.send()
                if self.background || self.holds.isEmpty { return }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    private func send() async {
        guard let model else { return }
        let macs: [String?] = [nil] + model.others.map { $0.id }
        var next = Set<String?>()
        for macId in Set(macs).union(reported) {
            let scopes = scopes(for: macId)
            let live = !background && !scopes.isEmpty
            if !live && !reported.contains(macId) { continue }
            let report = ClientActivity.Report(clientId: NetworkFleetMirror.deviceId, visible: !background,
                                               focused: !background, recentlyInteracted: !background,
                                               scopes: scopes, ttlMs: live ? Self.ttlMs : 0)
            if live { next.insert(macId) }
            try? await model.mirror(for: macId).reportClientActivity(report)
        }
        reported = next
    }
}
