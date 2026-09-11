import Foundation

/// #168: the phone's outbox may deliver a request twice (it died between
/// the send and the reply, or the reply was lost); the Mac answers the
/// repeat with the SAME reply the first send got, without touching the
/// session again. A short ring per pid is enough — a phone never has
/// more than one queued request per session, and a hand-retried send
/// reuses its id for a few seconds, not days.
public struct InputDedup: Sendable {
    private let capacity: Int
    private var seen: [Int32: [(requestId: String, reply: SessionInput.Reply)]] = [:]

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// The reply this `(pid, requestId)` got, if it's been seen before —
    /// nil the first time.
    public func replay(pid: Int32, requestId: String) -> SessionInput.Reply? {
        seen[pid]?.first { $0.requestId == requestId }?.reply
    }

    /// Remembers the reply `(pid, requestId)` got, evicting the oldest
    /// entry once the ring is full.
    public mutating func remember(pid: Int32, requestId: String, reply: SessionInput.Reply) {
        var ring = seen[pid] ?? []
        ring.append((requestId, reply))
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        seen[pid] = ring
    }
}
