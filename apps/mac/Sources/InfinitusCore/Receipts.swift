import Foundation

/// Command receipts (#223 phase 4), T3's `orchestration_command_receipts`:
/// a client mints a `commandId`, retries freely, and gets the same reply
/// once — never a second delivery. Same id + another target is a conflict;
/// a duplicate while the first still runs is `inFlight`; an interrupt
/// tombstones the pid's receipts so a retry cannot resurrect the stopped
/// input (T3 outbox doctrine). In memory only; the cap and TTL bound it.
public final class Receipts: @unchecked Sendable {
    public enum Lookup: Equatable, Sendable { case miss, inFlight, hit(Data), conflict, tombstoned }
    private enum State { case inFlight, done(Data), tombstoned }
    private struct Entry { let target: String; let pid: Int32?; var state: State; var at: Date }
    private let cap: Int
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init(cap: Int = 1000, ttl: TimeInterval = 3600) { self.cap = cap; self.ttl = ttl }

    /// A miss marks the id in flight; the caller then `finish`es or `abandon`s it.
    public func begin(commandId: String, target: String, pid: Int32?, now: Date = Date()) -> Lookup {
        lock.lock(); defer { lock.unlock() }
        if let e = entries[commandId] {
            if case .done = e.state, now.timeIntervalSince(e.at) > ttl {
                remove(commandId)
            } else {
                switch e.state {
                case .tombstoned: return .tombstoned
                case .inFlight: return e.target == target ? .inFlight : .conflict
                case .done(let data): return e.target == target ? .hit(data) : .conflict
                }
            }
        }
        entries[commandId] = Entry(target: target, pid: pid, state: .inFlight, at: now)
        order.append(commandId)
        while order.count > cap, let oldest = order.first(where: { id in
            if case .done = entries[id]?.state { return true }
            return false
        }) {
            remove(oldest)
        }
        return .miss
    }

    /// The 200 reply's bytes, replayed to every retry until the TTL.
    public func finish(commandId: String, reply: Data, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[commandId], case .inFlight = e.state else { return }
        e.state = .done(reply); e.at = now
        entries[commandId] = e
    }

    /// The command failed or never ran: a retry starts over.
    public func abandon(commandId: String) {
        lock.lock(); defer { lock.unlock() }
        if let e = entries[commandId], case .inFlight = e.state { remove(commandId) }
    }

    /// The user stopped the turn: nothing sent to this pid may come back.
    public func tombstone(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        for (id, e) in entries where e.pid == pid { entries[id]?.state = .tombstoned }
    }

    /// Wraps one POST handler in the receipt protocol (#223 phase 4): a
    /// known `commandId` replays its 200, conflicts (409), reports in-flight
    /// (409) or is gone (410); a fresh one runs `run` and caches a 200
    /// reply. `run` returning nil is the route's 404. The Mac's mirror and
    /// the Linux tray (#486) share it, so a phone outbox retry delivers
    /// once to either.
    public func serve(commandId: String?, target: String, pid: Int32?, run: () -> Data?) -> Data {
        guard let commandId else { return run() ?? MirrorTransport.notFoundResponse() }
        switch begin(commandId: commandId, target: target, pid: pid) {
        case .hit(let data): return data
        case .conflict: return MirrorTransport.conflictResponse(Data(#"{"error":"commandId reused for another target"}"#.utf8))
        case .inFlight: return MirrorTransport.conflictResponse(Data(#"{"error":"in-flight"}"#.utf8))
        case .tombstoned:
            return MirrorTransport.response(status: 410, reason: "Gone", contentType: "application/json",
                                            body: Data(#"{"error":"tombstoned"}"#.utf8))
        case .miss:
            guard let data = run() else { abandon(commandId: commandId); return MirrorTransport.notFoundResponse() }
            if data.starts(with: Data("HTTP/1.1 200".utf8)) { finish(commandId: commandId, reply: data) }
            else { abandon(commandId: commandId) }
            return data
        }
    }

    /// The session left the roster.
    public func drop(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        for (id, e) in entries where e.pid == pid { remove(id) }
    }

    private func remove(_ id: String) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }
}
