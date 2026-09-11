import Foundation

/// A few seconds of `/commands` replies per cwd (#223, moved here #486
/// slice 2 so the Mac and the Linux tray share one cache instead of two):
/// a popover reopening (or two phones) doesn't rescan the trees. Core's
/// `SlashCommands` keeps no cache of its own by design (B-5 adds one for
/// the Mac composer).
public final class MirrorCommandsCache: @unchecked Sendable {
    static let ttl: TimeInterval = 5
    private let lock = NSLock()
    private var entries: [String: (at: Date, data: Data)] = [:]
    public init() {}
    public func data(cwd: String, now: Date = Date(), make: () -> Data?) -> Data? {
        lock.lock(); let hit = entries[cwd]; lock.unlock()
        if let hit, now.timeIntervalSince(hit.at) < Self.ttl { return hit.data }
        guard let fresh = make() else { return nil }
        lock.lock(); entries[cwd] = (now, fresh); lock.unlock()
        return fresh
    }
}
