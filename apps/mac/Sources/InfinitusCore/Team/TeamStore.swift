import Foundation

/// One object in the store.
public struct StoreEntry: Equatable, Sendable {
    public var path: String
    public var size: Int
    /// Opaque per-object version (the git blob sha).
    public var version: String
    /// Whether the bytes are in the local mirror: a transcript chunk is
    /// listed from its first fetch on but comes down only when its
    /// session is opened (#414). `size` is 0 until then, and `get` nil.
    public var present: Bool
    public init(path: String, size: Int, version: String, present: Bool = true) {
        self.path = path; self.size = size; self.version = version; self.present = present
    }
}

/// Where a `changes(since:)` walk left off.
public struct StoreCursor: Codable, Equatable, Sendable {
    /// branch → commit sha
    public var heads: [String: String]
    public init(heads: [String: String] = [:]) { self.heads = heads }
}

/// The team store (spec §4.1): a key/value space of whole objects, with a
/// change feed. Adapters: git (this plan), synced folder and S3 later.
/// Paths are `roster/…`, `requests/…`, `m/<kid>/…`.
public protocol TeamStore {
    /// Pull everything new from the remote.
    func sync() throws
    func put(_ path: String, _ data: Data) throws
    /// Several writes as one change per branch; nil deletes.
    func putAll(_ writes: [String: Data?]) throws
    func get(_ path: String) throws -> Data?
    /// Objects whose path starts with `prefix` ("" = all).
    func list(_ prefix: String) throws -> [StoreEntry]
    func delete(_ path: String) throws
    /// Objects added or changed since `since` (nil = everything), plus the
    /// cursor to pass next time. Deletions are not reported; `list` is
    /// the truth for presence.
    func changes(since: StoreCursor?) throws -> ([StoreEntry], StoreCursor)
}

/// Store paths name their branch: `roster/x` → `roster`, `requests/x` →
/// `requests`, `m/<kid>/x` → `m/<kid>`. Anything else is refused, as is
/// any `.`/`..`/`.git` segment.
public enum StorePath {
    public static func branch(of path: String) -> (branch: String, rest: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }) else { return nil }
        switch parts.first {
        case "roster", "requests":
            guard parts.count >= 2 else { return nil }
            return (parts[0], parts.dropFirst().joined(separator: "/"))
        case "m", "t":
            guard parts.count >= 3 else { return nil }
            return (parts[0] + "/" + parts[1], parts.dropFirst(2).joined(separator: "/"))
        default:
            return nil
        }
    }
}
