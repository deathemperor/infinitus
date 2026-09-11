import Foundation

/// T3's per-thread attention flags (`thread.settle|unsettle|snooze|unsnooze|
/// pin|unpin`, contracts `orchestration.ts` ThreadShell) for Infinitus
/// sessions — keyed by session id, not pid, so they survive restarts and
/// `--resume`. #199's "park" is `settle`. Transition rules are T3's decider
/// and projector (t3code acc0a219e); the client derives "settled" and
/// "snoozed" from these the way T3's `threadSettled.ts` does. JSON in App
/// Support; degrade-never-throw: a missing or corrupt file reads as empty.
public final class AttentionStore: @unchecked Sendable {
    public enum SettledOverride: String, Codable, Sendable { case settled, active }

    public struct Entry: Codable, Sendable, Equatable {
        public var settledOverride: SettledOverride?
        public var settledAt: Date?
        /// When the session last re-entered the active list; anchors the
        /// active-list sort so an unsettled session surfaces at the top.
        public var unsettledAt: Date?
        public var snoozedUntil: Date?
        public var snoozedAt: Date?
        public var pinnedAt: Date?
        public init(settledOverride: SettledOverride? = nil, settledAt: Date? = nil, unsettledAt: Date? = nil,
                    snoozedUntil: Date? = nil, snoozedAt: Date? = nil, pinnedAt: Date? = nil) {
            self.settledOverride = settledOverride; self.settledAt = settledAt; self.unsettledAt = unsettledAt
            self.snoozedUntil = snoozedUntil; self.snoozedAt = snoozedAt; self.pinnedAt = pinnedAt
        }
        public var isEmpty: Bool { self == Entry() }
    }

    public enum Action: String, Codable, Sendable { case settle, unsettle, snooze, unsnooze, pin, unpin }

    public static var defaultURL: URL {
        #if canImport(Glibc)
        return MirrorWriter.linuxStateDir(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
            .appendingPathComponent("attention.json")
        #else
        return AppSupport.root().appendingPathComponent("attention.json")
        #endif
    }

    private let url: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    public init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: Entry].self, from: $0) } ?? [:]
    }

    public func entry(sessionId: String) -> Entry {
        lock.lock(); defer { lock.unlock() }
        return entries[sessionId] ?? Entry()
    }

    /// Applies one action; the caller validates (`SessionAttention`:
    /// snooze needs a future `until` and no pending prompt).
    @discardableResult
    public func apply(_ action: Action, sessionId: String, until: Date?, now: Date = Date()) -> Entry {
        lock.lock(); defer { lock.unlock() }
        var e = entries[sessionId] ?? Entry()
        switch action {
        case .settle:
            // decider.ts 493-515 (re-settle keeps settledAt), 544-575 (settle unpins and unsnoozes).
            e.settledAt = e.settledOverride == .settled ? (e.settledAt ?? now) : now
            e.settledOverride = .settled
            e.unsettledAt = nil
            e.pinnedAt = nil
            e.snoozedUntil = nil; e.snoozedAt = nil
        case .unsettle:
            unsettle(&e, now: now)
        case .snooze:
            // decider.ts 650-669: re-snooze keeps snoozedAt.
            e.snoozedAt = e.snoozedUntil == nil ? now : (e.snoozedAt ?? now)
            e.snoozedUntil = until
        case .unsnooze:
            e.snoozedUntil = nil; e.snoozedAt = nil
        case .pin:
            // decider.ts 713 (first pinnedAt wins), 738-770 (pin un-settles and unsnoozes).
            e.pinnedAt = e.pinnedAt ?? now
            if e.settledOverride == .settled { unsettle(&e, now: now) }
            e.snoozedUntil = nil; e.snoozedAt = nil
        case .unpin:
            e.pinnedAt = nil
        }
        entries[sessionId] = e.isEmpty ? nil : e
        save()
        return e
    }

    /// projector.ts 416-436: "active", settledAt cleared, the re-entry
    /// stamp set once.
    private func unsettle(_ e: inout Entry, now: Date) {
        e.unsettledAt = e.settledOverride == .active ? (e.unsettledAt ?? now) : now
        e.settledOverride = .active
        e.settledAt = nil
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
