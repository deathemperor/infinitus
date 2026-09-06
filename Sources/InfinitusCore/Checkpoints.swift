import Foundation

/// A per-turn workspace checkpoint (#167): the repository's working tree
/// as it was when a prompt went in, kept as a hidden git ref
/// `refs/infinitus/checkpoints/<sessionId>/<n>`. Hidden refs never show
/// as branches or tags, `git status` is untouched (the snapshot uses its
/// own index file), ignored files stay out, and every checkpoint is an
/// ordinary commit — `git diff`, `git show` and `git read-tree` all work
/// on it, so a restore is one read-tree away and nothing is lost even if
/// Infinitus is gone.
public struct Checkpoint: Codable, Sendable, Equatable {
    public let n: Int
    public let sha: String
    public let at: Date
    /// The prompt's first line, or what triggered the snapshot.
    public let subject: String
    /// The working tree the snapshot was taken in — recorded in the
    /// commit body, because a session's record keeps its STARTING folder
    /// while the hook reports where it is now (a worktree of the same
    /// clone, typically): diff and restore act on this folder, never on
    /// the folder the refs happened to be looked up from.
    public let root: String
}

public enum Checkpoints {
    public static let refRoot = "refs/infinitus/checkpoints"
    /// The patch a `diff` reply carries at most; the stat is always whole.
    public static let patchCap = 200 * 1024

    public static func refPrefix(sessionId: String) -> String { "\(refRoot)/\(sessionId)/" }

    /// The repository root the folder belongs to, or nil outside git.
    public static func toplevel(cwd: String, git: GitRunner = GitRunner()) -> String? {
        guard let out = try? git.run(["rev-parse", "--show-toplevel"], cwd: cwd) else { return nil }
        let root = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// Records the working tree now. Returns the existing last checkpoint
    /// when nothing changed since it (two prompts in a row with no edits
    /// between make one checkpoint), nil when `cwd` is not in a repository.
    @discardableResult
    public static func snapshot(cwd: String, sessionId: String, subject: String,
                                git: GitRunner = GitRunner(), now: Date = Date()) throws -> Checkpoint? {
        guard let root = toplevel(cwd: cwd, git: git) else { return nil }
        let existing = try list(cwd: root, sessionId: sessionId, git: git)
        let tree = try worktreeTree(root: root, git: git)
        if let last = existing.last,
           try git.run(["rev-parse", "\(last.sha)^{tree}"], cwd: root).trimmingCharacters(in: .whitespacesAndNewlines) == tree {
            return last
        }
        let n = (existing.last?.n ?? 0) + 1
        var args = ["commit-tree", tree, "-m", subjectLine(subject, n: n), "-m", "root: \(root)"]
        if let parent = existing.last?.sha ?? head(root: root, git: git) { args += ["-p", parent] }
        let stamp = "\(Int(now.timeIntervalSince1970)) +0000"
        let sha = try git.run(args, cwd: root, env: [
            "GIT_AUTHOR_NAME": "Infinitus", "GIT_AUTHOR_EMAIL": "checkpoint@infinitus.run",
            "GIT_COMMITTER_NAME": "Infinitus", "GIT_COMMITTER_EMAIL": "checkpoint@infinitus.run",
            "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["update-ref", refPrefix(sessionId: sessionId) + String(n), sha], cwd: root)
        return Checkpoint(n: n, sha: sha, at: Date(timeIntervalSince1970: TimeInterval(Int(now.timeIntervalSince1970))),
                          subject: subjectLine(subject, n: n), root: root)
    }

    /// `GET /sessions/<pid>/checkpoints` (#167 phase 2): the timeline the
    /// phone shows.
    public struct Reply: Codable, Sendable, Equatable {
        public let sessionId: String
        public let cwd: String
        public let checkpoints: [Checkpoint]
        public init(sessionId: String, cwd: String, checkpoints: [Checkpoint]) {
            self.sessionId = sessionId; self.cwd = cwd; self.checkpoints = checkpoints
        }
    }
    /// `POST …/checkpoints/<n>/restore`: `outcome` is "restored" or
    /// "failed" (`detail` carries git's words). Date-free on purpose — the
    /// phone decodes POST replies without a date strategy.
    public struct RestoreReply: Codable, Sendable, Equatable {
        public let outcome: String
        public let detail: String?
        /// The checkpoint that holds the state from just before the restore.
        public let backup: Int?
        public init(outcome: String, detail: String? = nil, backup: Int? = nil) {
            self.outcome = outcome; self.detail = detail; self.backup = backup
        }
    }

    /// The session's checkpoints, oldest first.
    public static func list(cwd: String, sessionId: String, git: GitRunner = GitRunner()) throws -> [Checkpoint] {
        guard let root = toplevel(cwd: cwd, git: git) else { return [] }
        let prefix = refPrefix(sessionId: sessionId)
        // One record per line: the body is a single "root: …" line, so a
        // newline-separated listing stays parseable.
        let out = try git.run(["for-each-ref",
                               "--format=%(refname)%09%(objectname)%09%(creatordate:unix)%09%(subject)%09%(contents:body)",
                               prefix], cwd: root)
        return out.split(separator: "\n").compactMap { line -> Checkpoint? in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[0].hasPrefix(prefix),
                  let n = Int(parts[0].dropFirst(prefix.count)), let epoch = TimeInterval(parts[2]) else { return nil }
            let body = parts.count > 4 ? String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let recorded = body.hasPrefix("root: ") ? String(body.dropFirst("root: ".count)) : root
            return Checkpoint(n: n, sha: String(parts[1]), at: Date(timeIntervalSince1970: epoch),
                              subject: String(parts[3]), root: recorded)
        }.sorted { $0.n < $1.n }
    }

    public struct Diff: Codable, Sendable, Equatable {
        public let from: Int
        /// nil = the working tree as it is now.
        public let to: Int?
        public let stat: String
        public let patch: String
        public let truncated: Bool
    }

    /// Checkpoint `from` against checkpoint `to`, or against the working
    /// tree now (untracked files included — it is diffed as a snapshot,
    /// not with `git diff <sha>`, which cannot see them).
    public static func diff(cwd: String, sessionId: String, from: Int, to: Int?,
                            git: GitRunner = GitRunner()) throws -> Diff {
        guard let root = toplevel(cwd: cwd, git: git) else { throw GitRunner.Failure(status: 128, stderr: "not a git repository") }
        let all = try list(cwd: root, sessionId: sessionId, git: git)
        guard let a = all.first(where: { $0.n == from }) else { throw GitRunner.Failure(status: 1, stderr: "no checkpoint #\(from)") }
        let b: String
        if let to {
            guard let c = all.first(where: { $0.n == to }) else { throw GitRunner.Failure(status: 1, stderr: "no checkpoint #\(to)") }
            b = c.sha
        } else {
            b = try worktreeTree(root: liveRoot(a.root, fallback: root), git: git)
        }
        let stat = try git.run(["diff", "--stat", a.sha, b], cwd: root)
        let patch = try git.run(["diff", a.sha, b], cwd: root)
        let truncated = patch.utf8.count > patchCap
        return Diff(from: from, to: to, stat: stat.trimmingCharacters(in: .newlines),
                    patch: truncated ? String(decoding: Data(patch.utf8.prefix(patchCap)), as: UTF8.self) : patch,
                    truncated: truncated)
    }

    /// Puts the working tree back to checkpoint `n` — every tracked or
    /// untracked (not ignored) file as it was then; files born since are
    /// removed. The state being replaced is checkpointed first, so a
    /// restore is itself undoable. The index ends up at the checkpoint's
    /// tree too (the price of `read-tree -u`; staging is not preserved).
    public static func restore(cwd: String, sessionId: String, n: Int,
                               git: GitRunner = GitRunner()) throws -> (restored: Checkpoint, backup: Checkpoint?) {
        guard let root = toplevel(cwd: cwd, git: git) else { throw GitRunner.Failure(status: 128, stderr: "not a git repository") }
        guard let target = try list(cwd: root, sessionId: sessionId, git: git).first(where: { $0.n == n }) else {
            throw GitRunner.Failure(status: 1, stderr: "no checkpoint #\(n)")
        }
        let live = liveRoot(target.root, fallback: root)
        let backup = try snapshot(cwd: live, sessionId: sessionId, subject: "before restoring #\(n)", git: git)
        // Two steps: the index first learns what the working tree holds
        // NOW (the backup's tree, untracked files included), then moves
        // to the target — read-tree only removes files it knows about,
        // so a one-step reset left everything born since in place.
        if let backup { try git.run(["read-tree", "--reset", "-u", backup.sha], cwd: live) }
        try git.run(["read-tree", "--reset", "-u", target.sha], cwd: live)
        return (target, backup)
    }

    /// The folder a checkpoint was taken in, when it still exists (a
    /// removed worktree falls back to where the refs were found).
    private static func liveRoot(_ recorded: String, fallback: String) -> String {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: recorded, isDirectory: &isDir) && isDir.boolValue ? recorded : fallback
    }

    /// The working tree as a tree object, through a throwaway index so
    /// the repository's own index and `git status` never change.
    static func worktreeTree(root: String, git: GitRunner) throws -> String {
        let index = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-ckpt-\(UUID().uuidString).index").path
        defer { try? FileManager.default.removeItem(atPath: index) }
        let env = ["GIT_INDEX_FILE": index]
        if head(root: root, git: git) != nil {
            try git.run(["read-tree", "HEAD"], cwd: root, env: env)
        }
        try git.run(["add", "-A", "--", "."], cwd: root, env: env)
        return try git.run(["write-tree"], cwd: root, env: env).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func head(root: String, git: GitRunner) -> String? {
        guard let out = try? git.run(["rev-parse", "--verify", "-q", "HEAD"], cwd: root) else { return nil }
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    static func subjectLine(_ subject: String, n: Int) -> String {
        let first = subject.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let body = trimmed.isEmpty ? "checkpoint" : String(trimmed.prefix(72))
        return "#\(n) \(body)"
    }
}

/// `git` as a child process, synchronous — callers run it off the main
/// thread. Output is stdout; a non-zero exit throws with stderr.
public struct GitRunner: Sendable {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 60) { self.timeout = timeout }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let status: Int32
        public let stderr: String
        public var description: String { stderr.isEmpty ? "git exited \(status)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @discardableResult
    public func run(_ args: [String], cwd: String, env extra: [String: String] = [:]) throws -> String {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // No child processes here (the phone reads checkpoints over the
        // mirror); Windows needs a PATH lookup this does not do yet.
        throw Failure(status: 127, stderr: "git checkpoints run on the Mac (and Linux) only")
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain both pipes before waiting: a large diff fills stdout's
        // buffer and the child blocks on write otherwise.
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            throw Failure(status: p.terminationStatus, stderr: String(decoding: stderrData, as: UTF8.self))
        }
        return String(decoding: stdoutData, as: UTF8.self)
        #endif
    }
}
