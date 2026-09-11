import Foundation
import InfinitusCore

/// Lazily-made `OwnedSessions` (#151), shared by the start handlers
/// and the input route. `existing` never creates one: a request into a
/// session nobody owns must not pay for locating `claude`.
final class OwnedSessionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instance: OwnedSessions?
    private var tried = false

    var existing: OwnedSessions? {
        lock.lock(); defer { lock.unlock() }
        return instance
    }

    func get(make: () -> OwnedSessions?) -> OwnedSessions? {
        lock.lock(); defer { lock.unlock() }
        if !tried {
            tried = true
            instance = make()
        }
        return instance
    }
}
