import Foundation

/// Per-session `SessionTimeline`, rebuilt only when the transcript's
/// `SessionFeedReader.stamp` (size, mtime, record status) moves — the
/// snapshot's facts and phase 4's sequence log both read from here, so
/// an unchanged transcript costs one `stat` per pass (#223 phase 3).
/// Keyed by session id: a pid can change sessions under a resume.
public final class TimelineCache: @unchecked Sendable {
    private struct Slot { let stamp: String; let timeline: SessionTimeline }
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    private let limit: Int
    /// Perf probe: transcript parses so far.
    public private(set) var parses = 0

    public init(limit: Int = 30) { self.limit = limit }

    public func timeline(record: ClaudeSessionRecord, claudeDir: URL) -> SessionTimeline? {
        let stamp = SessionFeedReader.stamp(record: record, claudeDir: claudeDir)
        lock.lock()
        if let slot = slots[record.sessionId], slot.stamp == stamp {
            lock.unlock()
            return slot.timeline
        }
        lock.unlock()
        guard let feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: limit),
              let timeline = feed.timeline else { return nil }
        // The feed's own stamp, taken after the read: a write that lands
        // between the stat above and the read is re-parsed next pass.
        lock.lock()
        parses += 1
        slots[record.sessionId] = Slot(stamp: feed.stamp ?? "", timeline: timeline)
        lock.unlock()
        return timeline
    }

    /// Facts for every record, owned sessions' parked prompts appended
    /// per call (never cached: they arrive over stdin, not the
    /// transcript). Sessions absent from `records` are evicted.
    public func facts(records: [ClaudeSessionRecord], claudeDir: URL, attention: AttentionStore,
                      pending: (Int32) -> [PendingRequest]) -> [Int: SessionFacts] {
        var out: [Int: SessionFacts] = [:]
        for record in records where !record.sessionId.isEmpty {
            guard let timeline = timeline(record: record, claudeDir: claudeDir) else { continue }
            out[Int(record.pid)] = SessionFacts.derive(timeline: timeline.appending(pending: pending(record.pid)),
                                                       status: record.status,
                                                       attention: attention.entry(sessionId: record.sessionId))
        }
        let keep = Set(records.map(\.sessionId))
        lock.lock(); slots = slots.filter { keep.contains($0.key) }; lock.unlock()
        return out
    }
}
