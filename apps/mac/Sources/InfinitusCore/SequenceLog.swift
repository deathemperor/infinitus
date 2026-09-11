import Foundation

/// Every change one session's timeline goes through, numbered (#223 phase
/// 4). Mirrors T3's per-thread event stream that `subscribeThread` replays
/// (`ws.ts:1601-1762`): a client that presents the sequence it last saw
/// gets the events after it; one that fell behind the ring, or comes from
/// another launch (`epoch`), gets a snapshot. Nothing persists — a
/// relaunch is a new epoch, the T3 "recreated thread forces a snapshot".
public struct TimelineEvent: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable { case upsert, tombstone }
    public enum Entity: String, Codable, Sendable { case turn, message, activity, facts }
    public let sequence: Int
    public let pid: Int32
    public let op: Op
    public let entity: Entity
    public let id: String
    /// The entity's wire JSON; nil for a tombstone.
    public let body: JSONValue?
    public init(sequence: Int, pid: Int32, op: Op, entity: Entity, id: String, body: JSONValue?) {
        self.sequence = sequence; self.pid = pid; self.op = op; self.entity = entity; self.id = id; self.body = body
    }
}

public final class SequenceLog: @unchecked Sendable {
    public let epoch: String
    private let maxEvents: Int
    private let maxBytes: Int
    private let lock = NSLock()
    private var next = 1
    /// One ring per pid: the buffered events, their encoded sizes, and the
    /// last sequence evicted from it — a cursor below that is a gap.
    private struct Ring {
        var events: [TimelineEvent] = []
        var bytes: [Int] = []
        var total = 0
        var evictedThrough = 0
    }
    private var rings: [Int32: Ring] = [:]
    private var lastFacts: [Int32: SessionFacts] = [:]
    /// Where a dropped pid's ring ended: a cursor from before a resume or
    /// a roster exit is a gap, never a partial replay.
    private var droppedAt: [Int32: Int] = [:]

    public init(epoch: String = UUID().uuidString, maxEvents: Int = 1000, maxBytes: Int = 8 * 1024 * 1024) {
        self.epoch = epoch; self.maxEvents = maxEvents; self.maxBytes = maxBytes
    }

    /// The last sequence handed out; 0 at launch.
    public var current: Int { lock.lock(); defer { lock.unlock() }; return next - 1 }

    /// Diff by id — an upsert for every turn, message and activity that is
    /// new or changed, a tombstone for every id that left — and the count
    /// appended.
    public func record(pid: Int32, old: SessionTimeline?, new: SessionTimeline) -> Int {
        var pending: [(TimelineEvent.Entity, String, JSONValue?, TimelineEvent.Op)] = []
        func diff<T: Codable & Equatable>(_ entity: TimelineEvent.Entity, _ olds: [T], _ news: [T], id: (T) -> String) {
            let oldById = Dictionary(olds.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
            for n in news where oldById[id(n)] != n { pending.append((entity, id(n), Self.json(n), .upsert)) }
            let newIds = Set(news.map(id))
            for o in olds where !newIds.contains(id(o)) { pending.append((entity, id(o), nil, .tombstone)) }
        }
        diff(.turn, old?.turns ?? [], new.turns, id: \.id)
        diff(.message, old?.messages ?? [], new.messages, id: \.id)
        diff(.activity, old?.activities ?? [], new.activities, id: \.id)
        lock.lock(); defer { lock.unlock() }
        for (entity, id, body, op) in pending { append(pid: pid, op: op, entity: entity, id: id, body: body) }
        return pending.count
    }

    /// The facts row (id "facts"); true when it differed from the last one.
    public func record(pid: Int32, facts: SessionFacts) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard lastFacts[pid] != facts else { return false }
        lastFacts[pid] = facts
        append(pid: pid, op: .upsert, entity: .facts, id: "facts", body: Self.json(facts))
        return true
    }

    /// The pid's events after `after`; `[]` when the client is current,
    /// nil when the ring no longer reaches back that far (snapshot time).
    public func events(pid: Int32, after: Int) -> [TimelineEvent]? {
        lock.lock(); defer { lock.unlock() }
        if after >= next - 1 { return [] }
        guard let ring = rings[pid], after >= ring.evictedThrough else { return nil }
        return ring.events.filter { $0.sequence > after }
    }

    /// The session left the roster: its ring and facts go with it.
    public func drop(pid: Int32) {
        lock.lock(); rings[pid] = nil; lastFacts[pid] = nil; droppedAt[pid] = next - 1; lock.unlock()
    }

    private func append(pid: Int32, op: TimelineEvent.Op, entity: TimelineEvent.Entity, id: String, body: JSONValue?) {
        let event = TimelineEvent(sequence: next, pid: pid, op: op, entity: entity, id: id, body: body)
        next += 1
        var ring = rings[pid] ?? Ring(evictedThrough: droppedAt[pid] ?? 0)
        let size = (try? JSONEncoder().encode(event))?.count ?? 0
        ring.events.append(event); ring.bytes.append(size); ring.total += size
        while ring.events.count > maxEvents || (ring.total > maxBytes && ring.events.count > 1) {
            ring.evictedThrough = ring.events.removeFirst().sequence
            ring.total -= ring.bytes.removeFirst()
        }
        rings[pid] = ring
    }

    static func json<T: Encodable>(_ value: T) -> JSONValue? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}
