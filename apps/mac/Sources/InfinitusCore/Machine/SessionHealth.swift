import Foundation

/// A live session as the guardian sees it (#115 item 4): how old, how
/// big, where, and how long since it did anything.
public struct SessionHealth: Equatable, Sendable, Codable, Identifiable {
    public let pid: Int
    public let name: String
    public let cwd: String
    public let rssMB: Int
    public let ageSeconds: Int
    public let lastActivityAt: Date?
    public var id: Int { pid }

    public init(pid: Int, name: String, cwd: String, rssMB: Int, ageSeconds: Int, lastActivityAt: Date?) {
        self.pid = pid; self.name = name; self.cwd = cwd; self.rssMB = rssMB
        self.ageSeconds = ageSeconds; self.lastActivityAt = lastActivityAt
    }

    public func idleHours(now: Date = Date()) -> Double {
        guard let last = lastActivityAt else { return Double(ageSeconds) / 3600 }
        return max(0, now.timeIntervalSince(last) / 3600)
    }

    /// Builds the rows from the process table and the session records;
    /// `name` and `lastActivityAt` come from the caller's progress model.
    public static func build(rows: [ProcessRow], records: [ClaudeSessionRecord],
                             name: (ClaudeSessionRecord) -> String,
                             lastActivity: (Int) -> Date?) -> [SessionHealth] {
        let byPid = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        return records.map { record in
            let pid = Int(record.pid)
            let row = byPid[pid]
            return SessionHealth(pid: pid, name: name(record), cwd: record.cwd,
                                 rssMB: row?.rssMB ?? 0, ageSeconds: row?.elapsedSeconds ?? 0,
                                 lastActivityAt: lastActivity(pid))
        }.sorted { $0.rssMB > $1.rssMB }
    }

    /// The sessions idle past the threshold that were not nudged yet. A
    /// session without a known last activity is unknown, not idle — the
    /// age fallback is for display only, never for a nudge.
    public static func idle(_ sessions: [SessionHealth], hours: Double, announced: Set<Int>, now: Date = Date()) -> [SessionHealth] {
        sessions.filter { $0.lastActivityAt != nil && $0.idleHours(now: now) >= hours && !announced.contains($0.pid) }
    }
}
