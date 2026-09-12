import Foundation

/// What a hook said about a session before Claude Code's own record
/// caught up (#79): `Stop` ⇒ idle, `SessionEnd` ⇒ gone. A hint yields
/// to the record — a `statusUpdatedAt` after the hint wins — and to
/// time (`ttl`), so a hint can never pin a row.
public struct SessionStatusHints: Equatable, Sendable {
    public struct Hint: Equatable, Sendable {
        /// nil = the session ended (the row goes).
        public var status: String?
        public var at: Date
        public init(status: String?, at: Date) { self.status = status; self.at = at }
    }
    public static let ttl: TimeInterval = 300
    public private(set) var hints: [String: Hint] = [:]   // by session id
    public init() {}

    public mutating func note(sessionId: String, _ hint: Hint) { hints[sessionId] = hint }

    /// The records with the hints applied: a record whose `statusUpdatedAt`
    /// is later than its hint drops the hint (Claude Code moved on); an
    /// expired hint is dropped; a `gone` hint removes the record; an
    /// idle hint sets `status`. Mutating so the dropped hints go.
    public mutating func apply(_ records: [ClaudeSessionRecord], now: Date = Date()) -> [ClaudeSessionRecord] {
        hints = hints.filter { now.timeIntervalSince($0.value.at) < Self.ttl }
        var result: [ClaudeSessionRecord] = []
        for record in records {
            guard let hint = hints[record.sessionId] else { result.append(record); continue }
            if let recordAt = record.statusUpdatedAt, recordAt > hint.at {
                hints.removeValue(forKey: record.sessionId)
                result.append(record)
            } else if let status = hint.status {
                result.append(record.with(status: status))
            }
            // else: a `gone` hint is still in force — drop the record.
        }
        return result
    }
}
