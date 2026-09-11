import Foundation

/// #168: what the phone keeps on disk so a Mac that is asleep, off Wi-Fi
/// or rebooting still leaves the fleet and the transcripts readable —
/// the last snapshot that answered and the last tail fetched per
/// session. Writes are atomic and skipped when nothing changed, so a
/// 10-second poll that returns the same snapshot never touches disk.
public final class ParkedCache: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var lastSavedCapturedAt: Date?
    private var lastSavedStamp: [Int32: String?] = [:]

    public init(root: URL) {
        self.root = root
    }

    private var snapshotURL: URL { root.appendingPathComponent("snapshot.json") }
    private func tailURL(_ pid: Int32) -> URL {
        root.appendingPathComponent("tails").appendingPathComponent("\(pid).json")
    }

    /// Same date strategy `MirrorWriter`/the `/sessions/<pid>/tail` route
    /// use on the wire, so a cached `capturedAt` matches what a fresh
    /// snapshot would decode to.
    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    public func saveSnapshot(_ snapshot: MirrorSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if lastSavedCapturedAt == snapshot.capturedAt { return }
        try write(Self.encoder().encode(snapshot), to: snapshotURL)
        lastSavedCapturedAt = snapshot.capturedAt
    }

    public func loadSnapshot() -> MirrorSnapshot? {
        // Read under the lock too: a `clear()` between the read and the
        // marker update would leave the marker claiming a file that is
        // gone, and the next save of that same snapshot would be skipped.
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? Self.decoder().decode(MirrorSnapshot.self, from: data) else { return nil }
        lastSavedCapturedAt = snapshot.capturedAt
        return snapshot
    }

    public func saveTail(_ feed: SessionFeed, pid: Int32) throws {
        lock.lock(); defer { lock.unlock() }
        if let known = lastSavedStamp[pid], known == feed.stamp, feed.stamp != nil { return }
        try write(Self.encoder().encode(feed), to: tailURL(pid))
        lastSavedStamp[pid] = feed.stamp
    }

    public func loadTail(pid: Int32) -> SessionFeed? {
        guard let data = try? Data(contentsOf: tailURL(pid)) else { return nil }
        return try? Self.decoder().decode(SessionFeed.self, from: data)
    }

    /// The primary Mac changed: nothing here belongs to the new one.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root)
        lastSavedCapturedAt = nil
        lastSavedStamp = [:]
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
