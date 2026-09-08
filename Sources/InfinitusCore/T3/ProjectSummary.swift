import Foundation

/// T3's project (`sidebarProjectGrouping.ts`, `projects.ts`): one row per
/// working directory the Mac has seen, so both clients can group threads
/// the way T3's sidebar and Home do.
public struct ProjectSummary: Codable, Sendable, Equatable, Identifiable {
    // FNV-1a 64 hex (16 chars) of the standardized cwd
    public let id: String
    public let name: String
    public let cwd: String
    public let branch: String?
    public let liveCount: Int
    public let lastActivityAt: Date?

    public init(id: String, name: String, cwd: String, branch: String?, liveCount: Int, lastActivityAt: Date?) {
        self.id = id; self.name = name; self.cwd = cwd; self.branch = branch
        self.liveCount = liveCount; self.lastActivityAt = lastActivityAt
    }

    /// Stable across restarts and Macs that share a checkout path: FNV-1a
    /// 64 over the standardized path, hex (Swift's `Hasher` is seeded per
    /// process, and the package does not depend on swift-crypto).
    public static func projectId(cwd: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in standardize(cwd).utf8 { h ^= UInt64(b); h &*= 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    static func standardize(_ cwd: String) -> String {
        var s = URL(fileURLWithPath: cwd).standardizedFileURL.path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `live`'s date is `ClaudeSessionRecord.statusUpdatedAt` — the record
    /// carries no session-start timestamp, so the most recent status
    /// change is the closest available "last touched" for a live cwd.
    public static func derive(live: [ClaudeSessionRecord], past: [PastSession],
                              profiles: [SessionProfile], recentCwds: [String],
                              branch: (String) -> String? = { _ in nil }) -> [ProjectSummary] {
        struct Acc { var live = 0; var last: Date? }
        var byCwd: [String: Acc] = [:]
        func touch(_ cwd: String, _ at: Date?, live: Bool) {
            let key = standardize(cwd)
            guard key != "/" , !key.isEmpty else { return }
            var a = byCwd[key] ?? Acc()
            if live { a.live += 1 }
            if let at, a.last.map({ at > $0 }) ?? true { a.last = at }
            byCwd[key] = a
        }
        for r in live { touch(r.cwd, r.statusUpdatedAt, live: true) }
        for p in past { touch(p.cwd, p.lastActivityAt, live: false) }
        for p in profiles { if let c = p.cwd { touch(c, nil, live: false) } }
        for c in recentCwds { touch(c, nil, live: false) }
        return byCwd.map { cwd, a in
            ProjectSummary(id: projectId(cwd: cwd), name: URL(fileURLWithPath: cwd).lastPathComponent,
                           cwd: cwd, branch: branch(cwd), liveCount: a.live, lastActivityAt: a.last)
        }.sorted {
            switch ($0.lastActivityAt, $1.lastActivityAt) {
            case let (a?, b?) where a != b: return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            default: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }
}
