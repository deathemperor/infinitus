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
    /// The mirror route (#164 phase 2): `GET /sessions/past?limit=&q=`
    /// answers a `Reply`; the phone's Resume then posts `SessionStart`
    /// with the session's cwd and `resume` id.
    public static let path = "/sessions/past"
    public static let limitQueryName = "limit"
    public static let searchQueryName = "q"

    public struct Reply: Codable, Sendable, Equatable {
        public let sessions: [PastSession]
        public init(sessions: [PastSession]) { self.sessions = sessions }
    }

    /// `scan` with the live set filled in from Claude Code's own session
    /// records — what the control socket and the mirror both answer.
    public static func list(claudeDir: URL, limit: Int = 50, search: String? = nil,
                            alive: (Int32) -> Bool = ClaudeSessions.isAlive) -> [PastSession] {
        let live = Set(ClaudeSessions.list(claudeDir: claudeDir, alive: alive).map(\.sessionId))
        return scan(claudeDir: claudeDir, liveIds: live, limit: limit, search: search)
    }

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
        let files = files(claudeDir: claudeDir)
        heads.keep(paths: Set(files.map(\.url.path)))
        return files.prefix(max(limit, 0)).compactMap { file in
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
    /// A cheap stamp of what `files` would find: every project dir's
    /// name and mtime. A directory's mtime moves when a transcript is
    /// created, removed or renamed in it; a transcript that only grows
    /// belongs to a live session, which `projectSummaries` keys on
    /// separately. About a hundred stats against the walk's ten
    /// thousand (#346: the per-minute walk was ~1 s of CPU at idle).
    public static func fingerprint(claudeDir: URL) -> String {
        let fm = FileManager.default
        let projects = claudeDir.appendingPathComponent("projects")
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let slugs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: Array(key),
                                                      options: [.skipsHiddenFiles]) else { return "" }
        return slugs.map { url in
            let mtime = (try? url.resourceValues(forKeys: key))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(url.lastPathComponent)@\(Int(mtime * 1000))"
        }.sorted().joined(separator: ",")
    }

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
    /// has landed yet. The head-derived pair is remembered per file:
    /// `projectSummaries` rescans every minute and re-reading 200 heads
    /// (13 MB, ~0.2 s of CPU) answered the same cwd and prompt each time
    /// (#346). A transcript is append-only, so once it has grown past
    /// `headBytes` its head is fixed; a shorter one re-reads on mtime.
    private static func session(of file: File, liveIds: Set<String>) -> PastSession? {
        let key = Head.Key(path: file.url.path, mtime: file.bytes < headBytes ? file.mtime : nil)
        let head = heads.value(key) { read(file.url) }
        guard let head else { return nil }
        let id = file.url.deletingPathExtension().lastPathComponent
        return PastSession(sessionId: id, cwd: head.cwd, repo: (head.cwd as NSString).lastPathComponent,
                           firstMessage: head.first, lastActivityAt: file.mtime, bytes: file.bytes,
                           live: liveIds.contains(id))
    }

    private static func read(_ url: URL) -> Head? {
        guard let head = head(of: url) else { return nil }
        let lines = head.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
        let entries = SessionProgress.jsonEntries(lines)
        guard let cwd = entries.lazy.compactMap({ $0["cwd"] as? String }).first(where: { !$0.isEmpty }),
              let first = SessionProgress.goal(entries: entries),
              // Infinitus's own headless runs (the session namer's
              // `claude -p`) open with its preface — not the user's work.
              !first.hasPrefix("[Infinitus]") else { return nil }
        return Head(cwd: cwd, first: first)
    }

    struct Head {
        let cwd: String, first: String
        struct Key: Hashable { let path: String; let mtime: Date? }
    }

    /// The remembered heads, one per transcript on disk — `scan` drops the
    /// entries whose file is gone. Read from whichever thread asks
    /// (the control socket, the mirror, the exporter's tick).
    static let heads = HeadCache()

    final class HeadCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: (key: Head.Key, head: Head?)] = [:]

        func value(_ key: Head.Key, read: () -> Head?) -> Head? {
            lock.lock()
            if let hit = stored[key.path], hit.key == key { lock.unlock(); return hit.head }
            lock.unlock()
            let head = read()
            lock.lock(); stored[key.path] = (key, head); lock.unlock()
            return head
        }

        func keep(paths: Set<String>) {
            lock.lock(); stored = stored.filter { paths.contains($0.key) }; lock.unlock()
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
    }

    private static func head(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: headBytes)
    }
}
