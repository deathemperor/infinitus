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
        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return files(claudeDir: claudeDir).prefix(max(limit, 0)).compactMap { file in
            guard let session = session(of: file, liveIds: liveIds) else { return nil }
            guard needle.isEmpty || [session.repo, session.cwd, session.firstMessage]
                .contains(where: { $0.lowercased().contains(needle) }) else { return nil }
            return session
        }
    }

    /// The session with that id, however old — found by file name in the
    /// listing, so only its own head is read. What `resume-session`
    /// resolves the folder from.
    public static func find(sessionId: String, claudeDir: URL, liveIds: Set<String> = []) -> PastSession? {
        files(claudeDir: claudeDir).first { $0.url.lastPathComponent == sessionId + ".jsonl" }
            .flatMap { session(of: $0, liveIds: liveIds) }
    }

    struct File { let url: URL; let mtime: Date; let bytes: Int }

    /// Every top-level transcript under projects/, newest first, from
    /// directory listings alone. Sub-agent transcripts live in
    /// `<sessionId>/subagents/`, a directory, so they fall out.
    static func files(claudeDir: URL) -> [File] {
        let fm = FileManager.default
        let projects = claudeDir.appendingPathComponent("projects")
        guard let slugs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var files: [File] = []
        for slug in slugs {
            guard let items = try? fm.contentsOfDirectory(at: slug, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let mtime = values.contentModificationDate else { continue }
                files.append(File(url: url, mtime: mtime, bytes: values.fileSize ?? 0))
            }
        }
        return files.sorted { $0.mtime > $1.mtime }
    }

    /// One transcript's head → its session, or nil when no user prompt
    /// has landed yet.
    private static func session(of file: File, liveIds: Set<String>) -> PastSession? {
        guard let head = head(of: file.url) else { return nil }
        let lines = head.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
        let entries = SessionProgress.jsonEntries(lines)
        guard let cwd = entries.lazy.compactMap({ $0["cwd"] as? String }).first(where: { !$0.isEmpty }),
              let first = SessionProgress.goal(lines: lines) else { return nil }
        let id = file.url.deletingPathExtension().lastPathComponent
        return PastSession(sessionId: id, cwd: cwd, repo: (cwd as NSString).lastPathComponent,
                           firstMessage: first, lastActivityAt: file.mtime, bytes: file.bytes,
                           live: liveIds.contains(id))
    }

    private static func head(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: headBytes)
    }
}
