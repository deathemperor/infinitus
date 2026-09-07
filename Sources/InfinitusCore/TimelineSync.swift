import Foundation

/// `GET /sessions/<pid>/timeline?afterSequence=&epoch=&wait=` (#223 phase
/// 4) — T3's `subscribeThread` in one reply (`ws.ts:1601-1762`): the
/// events after the client's cursor when the ring still has them and the
/// epoch matches, else a snapshot; `synchronized` closes every reply.
/// Clients apply upserts by id, drop tombstones, and accept a snapshot at
/// any time.
public struct TimelineSync: Codable, Sendable, Equatable {
    public struct Snapshot: Codable, Sendable, Equatable {
        public let timeline: SessionTimeline
        public let facts: SessionFacts
        public init(timeline: SessionTimeline, facts: SessionFacts) { self.timeline = timeline; self.facts = facts }
    }
    public let epoch: String
    public let sequence: Int
    public let synchronized: Bool
    public let snapshot: Snapshot?
    public let events: [TimelineEvent]?

    public static func reply(log: SequenceLog, pid: Int32, afterSequence: Int?, epoch: String?,
                             timeline: SessionTimeline, facts: SessionFacts) -> TimelineSync {
        let current = log.current
        if epoch == log.epoch, let after = afterSequence, let events = log.events(pid: pid, after: after) {
            return TimelineSync(epoch: log.epoch, sequence: current, synchronized: true, snapshot: nil, events: events)
        }
        return TimelineSync(epoch: log.epoch, sequence: current, synchronized: true,
                            snapshot: Snapshot(timeline: timeline, facts: facts), events: nil)
    }

    public init(epoch: String, sequence: Int, synchronized: Bool, snapshot: Snapshot?, events: [TimelineEvent]?) {
        self.epoch = epoch; self.sequence = sequence; self.synchronized = synchronized
        self.snapshot = snapshot; self.events = events
    }
}
