import Foundation

/// `POST /client-activity` (#223 phase 5), T3's `server.reportClientActivity`
/// (`packages/contracts/src/background.ts`): a client says what it is
/// looking at, every 25 s and on foreground/background, with a TTL; the
/// Mac only does per-session work while some client holds a lease on it.
public enum ClientActivity {
    public static let path = "/client-activity"
    /// The Mac's own popup / pop-out / chat window.
    public static let localClientId = "local"
    /// A client can't lease more than this at a time (ms): a crashed UI
    /// never pins work for longer.
    public static let ttlCapMs = 300_000

    public struct Scope: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case sessions, session, fleets, stats }
        public let type: Kind
        public let pid: Int32?
        public init(type: Kind, pid: Int32? = nil) { self.type = type; self.pid = pid }
        public static let sessions = Scope(type: .sessions)
        public static let fleets = Scope(type: .fleets)
        public static let stats = Scope(type: .stats)
        public static func session(_ pid: Int32) -> Scope { Scope(type: .session, pid: pid) }
    }

    public struct Report: Codable, Sendable, Equatable {
        public let clientId: String
        public let visible: Bool
        public let focused: Bool
        public let recentlyInteracted: Bool
        public let scopes: [Scope]
        public let ttlMs: Int
        public init(clientId: String, visible: Bool, focused: Bool, recentlyInteracted: Bool,
                    scopes: [Scope], ttlMs: Int) {
            self.clientId = clientId; self.visible = visible; self.focused = focused
            self.recentlyInteracted = recentlyInteracted; self.scopes = scopes; self.ttlMs = ttlMs
        }
    }
}

/// `clientId → (scopes, expiresAt)`, swept on every read. A `sessions`
/// lease covers every pid; `session(pid)` one of them.
public final class LeaseTable: @unchecked Sendable {
    private struct Lease { let scopes: Set<ClientActivity.Scope>; let expiresAt: Date }
    private let lock = NSLock()
    private var leases: [String: Lease] = [:]

    public init() {}

    /// Replaces the client's scopes; a zero (or negative) TTL releases.
    public func report(_ r: ClientActivity.Report, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let ttl = min(r.ttlMs, ClientActivity.ttlCapMs)
        guard ttl > 0 else { leases[r.clientId] = nil; return }
        leases[r.clientId] = Lease(scopes: Set(r.scopes), expiresAt: now.addingTimeInterval(Double(ttl) / 1000))
    }

    public func release(clientId: String) {
        lock.lock(); leases[clientId] = nil; lock.unlock()
    }

    public func holds(_ scope: ClientActivity.Scope, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sweep(now)
        return leases.values.contains { lease in
            lease.scopes.contains(scope) || (scope.type == .session && lease.scopes.contains(.sessions))
        }
    }

    /// The pids some client watches; nil when a `sessions` lease covers them all.
    public func leasedPids(now: Date = Date()) -> Set<Int32>? {
        lock.lock(); defer { lock.unlock() }
        sweep(now)
        if leases.values.contains(where: { $0.scopes.contains(.sessions) }) { return nil }
        return Set(leases.values.flatMap { $0.scopes.compactMap { $0.type == .session ? $0.pid : nil } })
    }

    /// The pids with a `session(pid)` lease of their own — a thread someone
    /// is looking at — whatever `sessions` leases also exist (#346).
    public func watchedPids(now: Date = Date()) -> Set<Int32> {
        lock.lock(); defer { lock.unlock() }
        sweep(now)
        return Set(leases.values.flatMap { $0.scopes.compactMap { $0.type == .session ? $0.pid : nil } })
    }

    public func clientCount(now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        sweep(now)
        return leases.count
    }

    private func sweep(_ now: Date) {
        leases = leases.filter { $0.value.expiresAt > now }
    }
}
