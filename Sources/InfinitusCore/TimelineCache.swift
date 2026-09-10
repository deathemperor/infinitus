import Foundation

/// Per-session `SessionTimeline`, rebuilt only when the transcript's
/// `SessionFeedReader.stamp` (size, mtime, record status) moves — the
/// snapshot's facts and phase 4's sequence log both read from here, so
/// an unchanged transcript costs one `stat` per pass (#223 phase 3).
/// Keyed by session id: a pid can change sessions under a resume. Every
/// rebuild and facts change is numbered into the `SequenceLog` when one
/// is attached (#223 phase 4).
public final class TimelineCache: @unchecked Sendable {
    /// `tail`: the reader's held window, kept for wide (watched) slots
    /// only so a streaming thread's rebuild decodes just the new lines
    /// (#346); a narrow slot re-reads its 256 KB, which is cheap, and
    /// holding a decoded window per idle session is not.
    private struct Slot {
        let stamp: String; let pid: Int32; let timeline: SessionTimeline; let maxBytes: Int
        let tail: SessionTail?
    }
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    private var sessionByPid: [Int32: String] = [:]
    private let limit: Int
    private let log: SequenceLog?
    /// Perf probe: transcript parses so far.
    public private(set) var parses = 0

    public init(limit: Int = 30, log: SequenceLog? = nil) { self.limit = limit; self.log = log }

    /// `maxBytes`: how far the transcript's tail window may grow for this
    /// build (#346). A slot built with a wider window answers a narrower
    /// ask unchanged; a narrower slot is rebuilt for a wider one.
    public func timeline(record: ClaudeSessionRecord, claudeDir: URL,
                         maxBytes: Int = SessionFeedReader.tailBytesMax) -> SessionTimeline? {
        let stamp = SessionFeedReader.stamp(record: record, claudeDir: claudeDir)
        lock.lock()
        if let slot = slots[record.sessionId], slot.stamp == stamp, slot.maxBytes >= maxBytes {
            lock.unlock()
            return slot.timeline
        }
        // A resumed pid (new session id) starts over: the old ring is a gap.
        if let previousSession = sessionByPid[record.pid], previousSession != record.sessionId {
            slots[previousSession] = nil
            log?.drop(pid: record.pid)
        }
        let previous = slots[record.sessionId]?.timeline
        var tail = slots[record.sessionId]?.tail
        lock.unlock()
        guard let feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: limit,
                                                maxBytes: maxBytes, tail: &tail),
              let timeline = feed.timeline else { return nil }
        // The feed's own stamp, taken after the read: a write that lands
        // between the stat above and the read is re-parsed next pass.
        lock.lock()
        parses += 1
        slots[record.sessionId] = Slot(stamp: feed.stamp ?? "", pid: record.pid, timeline: timeline, maxBytes: maxBytes,
                                       tail: maxBytes > SessionFeedReader.tailBytes ? tail : nil)
        sessionByPid[record.pid] = record.sessionId
        lock.unlock()
        _ = log?.record(pid: record.pid, old: previous, new: timeline)
        return timeline
    }

    /// Facts for every record, owned sessions' parked prompts appended
    /// per call (never cached: they arrive over stdin, not the
    /// transcript). Sessions absent from `roster` (default: `records`)
    /// have left and are evicted; a leased subset (#223 phase 5) passes
    /// the full roster so the others keep their slots and rings.
    /// `watched`: the pids someone has open (a `session` lease); their
    /// timelines build with the full window, everyone else's with the
    /// first 256 KB of tail — a row's status, plan step and parked
    /// prompt live there, and a busy session's transcript moves every
    /// pass, so the wide re-parse was most of the app's idle CPU (#346).
    /// nil keeps every record on the full window.
    public func facts(records: [ClaudeSessionRecord], claudeDir: URL, attention: AttentionStore,
                      roster: [ClaudeSessionRecord]? = nil, watched: Set<Int32>? = nil,
                      pending: (Int32) -> [PendingRequest]) -> [Int: SessionFacts] {
        var out: [Int: SessionFacts] = [:]
        for record in records where !record.sessionId.isEmpty {
            let wide = watched?.contains(record.pid) ?? true
            let cap = wide ? SessionFeedReader.tailBytesMax : SessionFeedReader.tailBytes
            guard let timeline = timeline(record: record, claudeDir: claudeDir, maxBytes: cap) else { continue }
            let facts = SessionFacts.derive(timeline: timeline.appending(pending: pending(record.pid)),
                                            status: record.status,
                                            attention: attention.entry(sessionId: record.sessionId))
            out[Int(record.pid)] = facts
            _ = log?.record(pid: record.pid, facts: facts)
        }
        evict(keeping: roster ?? records)
        return out
    }

    /// Drops the slots of sessions absent from `roster` — they have
    /// left — and their rings from the log. `facts` does this on every
    /// pass; the Linux tray, which serves timelines without `facts`,
    /// calls it from its export tick (#486).
    public func evict(keeping roster: [ClaudeSessionRecord]) {
        let keep = Set(roster.map(\.sessionId))
        lock.lock()
        let gone = slots.filter { !keep.contains($0.key) }
        slots = slots.filter { keep.contains($0.key) }
        for (_, slot) in gone { sessionByPid[slot.pid] = nil }
        lock.unlock()
        for (_, slot) in gone { log?.drop(pid: slot.pid) }
    }
}
