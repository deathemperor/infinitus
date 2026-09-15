import Foundation

/// Spec §4 / §7: what a member publishes about its threads, read off
/// Infinitus desktop (`DesktopAPI.shell()` for the index and the live
/// rows, `thread(_:turnLimit:)` for a transcript) instead of the Claude
/// Code transcript tree the first publisher walked (#1313).
public enum TeamThreadSources {
    /// One transcript line as it travels in a `t/<kid>` chunk: one JSON
    /// object per line, redacted like every chunk was.
    public struct Row: Codable, Equatable, Sendable {
        public var role: String
        public var text: String
        public var at: Int?
        public init(role: String, text: String, at: Int? = nil) { self.role = role; self.text = text; self.at = at }
    }

    public struct Transcript: Equatable, Sendable {
        public var threadId: String
        /// Project directory basename, never the path.
        public var project: String
        public var rows: [Row]
        public init(threadId: String, project: String, rows: [Row]) { self.threadId = threadId; self.project = project; self.rows = rows }

        /// The cursor key and the chunk directory (spec §4.3, `TeamKinds`).
        public var key: String { threadId }
        public func chunkPath(seq: Int) -> String { "transcripts/\(threadId)/\(seq).jsonl" }
    }

    /// The shell's threads as index rows, newest change first, and the
    /// ones with a turn in flight as `now.json`'s live rows. The project
    /// is the workspace root's basename; an unknown project id stands
    /// as itself, so the row still names something.
    public static func threads(_ shell: DesktopAPI.Shell, now: Int) -> (rows: [TeamDocs.ThreadRow], live: [TeamDocs.LiveThread]) {
        let projects = Dictionary(shell.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [TeamDocs.ThreadRow] = []
        var live: [TeamDocs.LiveThread] = []
        for t in shell.threads {
            let project = projects[t.projectId].map { basename($0.workspaceRoot) } ?? t.projectId
            let updated = unix(t.updatedAt) ?? now
            let status = status(t)
            var row = TeamDocs.ThreadRow(id: t.id, title: t.title, project: project, status: status,
                                         createdAt: unix(t.createdAt) ?? updated, updatedAt: updated, turns: t.usage?.turns ?? 0)
            if let u = t.usage {
                row.usage = .init(inputTokens: u.inputTokens ?? 0, outputTokens: u.outputTokens ?? 0, costUsd: u.costUsd, models: u.models ?? [])
            }
            rows.append(row)
            if ["starting", "running", "waiting"].contains(status) {
                let line = status == "waiting"
                    ? (t.hasPendingApprovals == true ? "Waiting for approval" : "Waiting for input")
                    : nil
                live.append(TeamDocs.LiveThread(id: t.id, title: t.title, project: project,
                                                startedAt: unix(t.latestTurn?.startedAt), activityLine: line))
            }
        }
        rows.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        return (rows, live)
    }

    /// archived | failed | starting | waiting | running | idle — the
    /// desktop verbs' word (`DesktopRows.status`) with the two states a
    /// teammate wants to see that the CLI's row does not carry.
    static func status(_ t: DesktopAPI.ThreadShell) -> String {
        if t.archivedAt != nil { return "archived" }
        if t.latestTurn?.state == "failed" { return "failed" }
        if t.session?.status == "starting" { return "starting" }
        return DesktopRows.status(t, hold: nil)
    }

    /// One thread's messages as transcript rows, in the order the desktop
    /// gave them (oldest first).
    public static func transcript(_ thread: DesktopAPI.Thread, project: String) -> Transcript {
        Transcript(threadId: thread.id, project: project,
                   rows: thread.messages.map { Row(role: $0.role, text: $0.text, at: unix($0.createdAt)) })
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// The desktop's ISO instants as unix seconds; nil for none or one it
    /// cannot read.
    public static func unix(_ text: String?) -> Int? {
        guard let text else { return nil }
        let date = isoFractional.date(from: text) ?? iso.date(from: text)
        return date.map { Int($0.timeIntervalSince1970) }
    }

    static func basename(_ path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
    }
}
