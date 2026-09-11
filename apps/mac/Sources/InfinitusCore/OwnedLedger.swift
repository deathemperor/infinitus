import Foundation

#if !os(iOS)
/// A record of every headless `claude` child this app has spawned, on
/// disk so a launch AFTER a crash (no PDEATHSIG on Darwin) can find and
/// stop what the last run left running (#151 follow-up). Best effort:
/// a missing or unreadable file just means an empty ledger, never a throw.
public struct OwnedLedger: Sendable {
    public struct Entry: Sendable, Codable, Equatable {
        public let pid: Int32
        public let sessionId: String
        public let startedAt: Date
        public init(pid: Int32, sessionId: String, startedAt: Date) {
            self.pid = pid; self.sessionId = sessionId; self.startedAt = startedAt
        }
    }

    private let url: URL
    /// Static: `record`/`forget` reach the file from the actor, the
    /// pipe-reader thread and the termination handler — a shared lock
    /// (not per-instance) keeps their read-modify-write whole even across
    /// separate `OwnedLedger` values pointed at the same URL.
    private static let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// New spawn: sessionId is empty until `init` arrives on the pipe.
    public func record(pid: Int32, sessionId: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var all = entries().filter { $0.pid != pid }
        all.append(Entry(pid: pid, sessionId: sessionId, startedAt: Date()))
        write(all)
    }

    public func forget(pid: Int32) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        write(entries().filter { $0.pid != pid })
    }

    private func write(_ all: [Entry]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
#endif
