import Foundation
import InfinitusCore

/// The phone's `/timeline` follower (T3 clone C-1, #223 phase 4): one
/// long-poll loop per open thread, mirroring T3's `subscribeThread`.
/// Each reply is folded by `apply` — upserts by id, tombstones drop,
/// a snapshot replaces everything — so the screen only ever renders
/// `state`. Stops with the screen: no loop runs for a thread nobody
/// is looking at.
@MainActor final class TimelineFollower: ObservableObject {
    struct State: Equatable {
        var timeline = SessionTimeline()
        var facts: SessionFacts?
        var epoch: String?
        var sequence = -1
        var synchronized = false
    }

    @Published private(set) var state = State()
    /// The last poll failed; the loop keeps trying.
    @Published private(set) var unreachable = false

    private let pid: Int32
    private let mirror: NetworkFleetMirror
    private var loop: Task<Void, Never>?

    init(pid: Int32, mirror: NetworkFleetMirror) {
        self.pid = pid
        self.mirror = mirror
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                let cursor = state
                do {
                    let sync = try await mirror.timeline(pid: pid, after: cursor.epoch == nil ? nil : cursor.sequence,
                                                         epoch: cursor.epoch, wait: 25)
                    let next = Self.apply(sync, to: cursor)
                    unreachable = false
                    let changed = next != cursor
                    state = next
                    // The web client's floors: a change settles half a
                    // second before the next ask, a quiet long-poll re-asks
                    // at once (the Mac already held it for `wait`).
                    if changed { try? await Task.sleep(for: .milliseconds(500)) }
                } catch {
                    unreachable = true
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One reply folded into the client's copy. A snapshot replaces the
    /// timeline and facts wholesale; events upsert or tombstone by id
    /// within their entity, in wire order; `facts` events replace the
    /// facts. The cursor always moves to the reply's epoch/sequence.
    nonisolated static func apply(_ sync: TimelineSync, to state: State) -> State {
        var out = state
        if let snapshot = sync.snapshot {
            out.timeline = snapshot.timeline
            out.facts = snapshot.facts
        }
        for event in sync.events ?? [] {
            switch (event.entity, event.op) {
            case (.facts, .upsert):
                if let facts: SessionFacts = decode(event.body) { out.facts = facts }
            case (.facts, .tombstone):
                out.facts = nil
            case (.turn, .upsert):
                if let turn: SessionTimeline.Turn = decode(event.body) { upsert(turn, into: &out.timeline.turns, id: \.id) }
            case (.turn, .tombstone):
                out.timeline.turns.removeAll { $0.id == event.id }
            case (.message, .upsert):
                if let message: SessionTimeline.Message = decode(event.body) { upsert(message, into: &out.timeline.messages, id: \.id) }
            case (.message, .tombstone):
                out.timeline.messages.removeAll { $0.id == event.id }
            case (.activity, .upsert):
                if let activity: SessionTimeline.Activity = decode(event.body) { upsert(activity, into: &out.timeline.activities, id: \.id) }
            case (.activity, .tombstone):
                out.timeline.activities.removeAll { $0.id == event.id }
            }
        }
        out.epoch = sync.epoch
        out.sequence = sync.sequence
        out.synchronized = sync.synchronized
        return out
    }

    nonisolated private static func upsert<T>(_ value: T, into list: inout [T], id: KeyPath<T, String>) {
        if let i = list.firstIndex(where: { $0[keyPath: id] == value[keyPath: id] }) {
            list[i] = value
        } else {
            list.append(value)
        }
    }

    /// Event bodies are the entity's wire JSON (`SequenceLog.json`, ISO
    /// 8601 dates), so they decode the way a snapshot does.
    nonisolated private static func decode<T: Decodable>(_ body: JSONValue?) -> T? {
        guard let body, let data = try? JSONEncoder().encode(body) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}
