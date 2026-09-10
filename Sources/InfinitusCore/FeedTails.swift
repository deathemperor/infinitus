import Foundation

/// The feed route's held tails (#380): one `SessionTail` per pid, so a
/// phone's poll of `/sessions/<pid>/tail` — every 5 s, or on each
/// long-poll wake while a session streams — decodes only what the
/// transcript gained since its last one instead of a fresh 256 KB–4 MB
/// window (`SessionFeedReader.read(…tail:)`). Bounded to the newest
/// `cap` pids: a phone watches one thread at a time, and a held window
/// is a few MB of decoded lines.
public final class FeedTails: @unchecked Sendable {
    private let lock = NSLock()
    private var tails: [Int32: SessionTail] = [:]
    private var order: [Int32] = []
    private let cap: Int

    public init(cap: Int = 4) { self.cap = cap }

    /// The pid's feed through its held tail, which is kept for the next
    /// read. A resumed pid (new session id, new transcript) starts a
    /// fresh tail on its own — the reader checks the URL. Two readers of
    /// one pid at once each get a correct feed; the later one's tail
    /// is the one kept.
    public func read(record: ClaudeSessionRecord, claudeDir: URL, limit: Int) -> SessionFeed? {
        lock.lock()
        var tail = tails.removeValue(forKey: record.pid)
        lock.unlock()
        let feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: limit, tail: &tail)
        lock.lock()
        defer { lock.unlock() }
        tails[record.pid] = tail
        order.removeAll { $0 == record.pid }
        order.append(record.pid)
        while order.count > cap {
            tails[order.removeFirst()] = nil
        }
        return feed
    }

    /// Pids with a held tail, oldest first.
    public var held: [Int32] { lock.lock(); defer { lock.unlock() }; return order }
}
