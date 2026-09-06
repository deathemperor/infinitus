import Foundation

/// Every Claude Code session this Mac has ever run, live or not (#164):
/// the transcripts under `~/.claude/projects/<slug>/<sessionId>.jsonl`,
/// newest first, each with its folder and opening prompt so any of them
/// can be resumed (`claude --resume <id>`, from the folder it ran in).
public struct PastSession: Codable, Sendable, Equatable {
    public let sessionId: String
    /// The folder the session ran in — the FIRST cwd its transcript
    /// records: a session that later moved into a worktree keeps writing
    /// under the slug of where it started, and `--resume` looks it up
    /// by that folder.
    public let cwd: String
    public let repo: String
    public let firstMessage: String
    public let lastActivityAt: Date
    public let bytes: Int
    /// A live session (in the roster) — resume it from there instead.
    public let live: Bool
}

public enum PastSessions {
    /// Only the head of each transcript is read — the cwd and the opening
    /// prompt live there — and only for the `limit` newest files: a
    /// projects dir with thousands of transcripts over many gigabytes is
    /// walked by directory listing alone.
    public static let headBytes = 64 * 1024

    /// Newest `limit` sessions, by transcript mtime. `search` filters
    /// that set (repo, folder or first message, case-insensitive) —
    /// it never reaches past the newest `limit` transcripts. Sessions
    /// whose head has no user prompt yet (opened and closed) are dropped.
    public static func scan(claudeDir: URL, liveIds: Set<String> = [], limit: Int = 50,
                            search: String? = nil) -> [PastSession] {
        let fm = FileManager.default
        let projects = claudeDir.appendingPathComponent("projects")
        guard let slugs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var files: [(url: URL, mtime: Date, bytes: Int)] = []
        for slug in slugs {
            guard let items = try? fm.contentsOfDirectory(at: slug, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles]) else { continue }
            // Sub-agent transcripts live in `<sessionId>/subagents/`, a
            // directory — top-level `.jsonl` files are the sessions.
            for url in items where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let mtime = values.contentModificationDate else { continue }
                files.append((url, mtime, values.fileSize ?? 0))
            }
        }
        files.sort { $0.mtime > $1.mtime }

        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var out: [PastSession] = []
        for file in files.prefix(max(limit, 0)) {
            guard let head = head(of: file.url) else { continue }
            let lines = head.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
            let entries = SessionProgress.jsonEntries(lines)
            guard let cwd = entries.lazy.compactMap({ $0["cwd"] as? String }).first(where: { !$0.isEmpty }),
                  let first = SessionProgress.goal(lines: lines) else { continue }
            let id = file.url.deletingPathExtension().lastPathComponent
            let session = PastSession(sessionId: id, cwd: cwd, repo: (cwd as NSString).lastPathComponent,
                                      firstMessage: first, lastActivityAt: file.mtime, bytes: file.bytes,
                                      live: liveIds.contains(id))
            if needle.isEmpty || [session.repo, session.cwd, session.firstMessage]
                .contains(where: { $0.lowercased().contains(needle) }) {
                out.append(session)
            }
        }
        return out
    }

    /// The one session with that id among the newest `limit` transcripts,
    /// or nil — what `resume-session` resolves the folder from.
    public static func find(sessionId: String, claudeDir: URL, limit: Int = 500) -> PastSession? {
        scan(claudeDir: claudeDir, limit: limit).first { $0.sessionId == sessionId }
    }

    private static func head(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: headBytes)
    }
}
