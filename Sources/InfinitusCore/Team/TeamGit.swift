import Foundation
#if canImport(Glibc)
import Glibc   // signal / SIGPIPE for `feed`
#endif

/// `TeamStore` over git plumbing (spec §4.2). The local side is a bare
/// mirror — no working tree, no checkouts: writes build a tree on top of
/// the branch's remote-tracking commit with a private index file and
/// push the new commit; reads use `ls-tree` / `cat-file`. A write that
/// loses a push race fetches and retries once on the new tip; a caller
/// that computed its bytes from what it read (the roster) passes
/// `retryOnRace: false` and gets `raceLost` instead.
///
/// The credential never touches argv: it rides in the child's
/// environment as `INFINITUS_TEAM_TOKEN` and an inline credential helper
/// hands it to git.
public final class TeamGit: TeamStore {
    public static let tokenEnv = "INFINITUS_TEAM_TOKEN"

    public enum GitError: Error {
        case failed(command: String, status: Int32, stderr: String)
        case notOpen
        case badPath(String)
        /// The push was rejected and the caller asked not to retry.
        case raceLost
        /// No subprocesses on this platform (iOS): the phone talks to its
        /// Mac, which holds the mirror.
        case unavailable
        /// Spec §6.1: a team is created on an EMPTY repository, and this
        /// one already has refs.
        case notEmpty
    }

    /// A blob's bytes: in memory, or a file git reads itself — a sealed
    /// spool chunk (see `TeamPublisher`), so a batch never passes
    /// through our heap.
    public enum Blob {
        case data(Data)
        case file(URL)
    }

    public let dir: URL
    public let remote: String
    private let token: String?
    private let author: String
    private var gitDir: URL { dir.appendingPathComponent("store.git") }
    private var opened = false
    /// `rev-parse` per branch, remembered until the next fetch or push:
    /// a header scan calls `get` once per stored file, and each `get`
    /// asked git for the branch tip again (1708 files → 1708 extra
    /// subprocesses on the 2026-09-06 first publish).
    private var heads: [String: String?] = [:]
    /// What the last `open()` cleared, for the log line and the tests.
    public private(set) var sweptLocks: [String] = []

    public init(dir: URL, remote: String, token: String?, author: String) {
        self.dir = dir; self.remote = remote; self.token = token; self.author = author
    }

    /// Creates the bare mirror on first use and fetches only then: an
    /// existing mirror opens offline and callers `sync()` when they want
    /// the network (so `team status` never waits on a remote).
    public func open() throws {
        let fresh = !FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path)
        if fresh {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try run(["init", "--bare", "-q", gitDir.path], useGitDir: false)
            _ = try run(["remote", "add", "origin", remote])
        }
        opened = true
        sweptLocks = Self.sweepLocks(in: gitDir)
        if !sweptLocks.isEmpty {
            // stderr, not `os.Logger`: InfinitusCore builds on Linux too.
            FileHandle.standardError.write(Data("infinitus: cleared stale git locks: \(sweptLocks.joined(separator: ", "))\n".utf8))
        }
        if fresh { try sync() }
    }

    // MARK: TeamStore

    public func sync() throws {
        heads = [:]
        _ = try run(["fetch", "-q", "--prune", "origin", "+refs/heads/*:refs/remotes/origin/*"])
    }

    /// Spec §6.1's "empty private repo", asked of the REMOTE. Not
    /// `branches()` — that filters to the store's own branches (Task 4),
    /// so a repo holding only `main` or a README would read as empty —
    /// and not the local refs, which a fresh mirror has none of either
    /// way.
    public func requireEmptyRemote() throws {
        guard opened else { throw GitError.notOpen }
        let text = String(decoding: try run(["ls-remote", "origin"]), as: UTF8.self)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitError.notEmpty }
    }

    public func put(_ path: String, _ data: Data) throws { try putAll([path: data]) }

    public func delete(_ path: String) throws { try putAll([path: nil]) }

    public func putAll(_ writes: [String: Data?]) throws { try putAll(writes, retryOnRace: true) }

    /// `retryOnRace: false` refuses to rebuild the same bytes on the
    /// winner's tip — for an object computed from what was read (the
    /// roster) that would silently discard the other writer's change.
    public func putAll(_ writes: [String: Data?], retryOnRace: Bool) throws {
        // `mapValues` keeps nil-valued keys (a staged delete); a
        // subscript-assign of nil would drop them (see `TeamClient.leave`).
        try putAll(blobs: writes.mapValues { $0.map(Blob.data) }, retryOnRace: retryOnRace)
    }

    /// The same, for blobs already on disk. `nil` deletes — build the
    /// dictionary with `updateValue(nil, forKey:)`, never `d[k] = nil`.
    public func putAll(blobs writes: [String: Blob?], retryOnRace: Bool = true) throws {
        guard opened else { throw GitError.notOpen }
        var byBranch: [String: [(String, Blob?)]] = [:]
        for (path, blob) in writes {
            guard let (branch, rest) = StorePath.branch(of: path) else { throw GitError.badPath(path) }
            byBranch[branch, default: []].append((rest, blob))
        }
        heads = [:]
        defer { heads = [:] }
        for (branch, items) in byBranch {
            do {
                try commitAndPush(branch: branch, items: items)
            } catch GitError.failed(let command, let status, let stderr) where command.hasPrefix("push") {
                // Not every failed push is a lost race: no network, DNS,
                // a 403, a remote that no longer exists all failed here
                // too, and retrying them three times reported the wrong
                // thing to the user (#55).
                guard Self.isRaceRejection(stderr) else {
                    throw GitError.failed(command: command, status: status, stderr: stderr)
                }
                // Someone else (another device of ours) pushed first: rebuild on the new tip.
                guard retryOnRace else { throw GitError.raceLost }
                try sync()
                try commitAndPush(branch: branch, items: items)
            }
        }
    }

    public func get(_ path: String) throws -> Data? {
        guard opened else { throw GitError.notOpen }
        guard let (branch, rest) = StorePath.branch(of: path) else { throw GitError.badPath(path) }
        guard let head = try head(of: branch) else { return nil }
        do {
            return try run(["cat-file", "blob", "\(head):\(rest)"])
        } catch GitError.failed { return nil }
    }

    public func list(_ prefix: String) throws -> [StoreEntry] {
        guard opened else { throw GitError.notOpen }
        var out: [StoreEntry] = []
        for branch in try branches() {
            guard let head = try head(of: branch) else { continue }
            for entry in try tree(commit: head, branch: branch) where entry.path.hasPrefix(prefix) {
                out.append(entry)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    public func changes(since: StoreCursor?) throws -> ([StoreEntry], StoreCursor) {
        guard opened else { throw GitError.notOpen }
        var out: [StoreEntry] = []
        var cursor = StoreCursor()
        for branch in try branches() {
            guard let head = try head(of: branch) else { continue }
            cursor.heads[branch] = head
            if let old = since?.heads[branch] {
                if old == head { continue }
                // The cursor's commit can be unreachable: the remote was
                // rewritten, the mirror rebuilt, the object gc'd. Listing
                // the whole branch is always correct — it is exactly what
                // a nil cursor does — so fall back instead of throwing.
                if let raw = try? run(["diff-tree", "-r", "--name-only", "--diff-filter=AM", old, head]) {
                    let changed = Set(String(decoding: raw, as: UTF8.self).split(separator: "\n").map(String.init))
                    out += try tree(commit: head, branch: branch).filter { changed.contains(String($0.path.dropFirst(branch.count + 1))) }
                } else {
                    out += try tree(commit: head, branch: branch)
                }
            } else {
                out += try tree(commit: head, branch: branch)
            }
        }
        return (out.sorted { $0.path < $1.path }, cursor)
    }

    // MARK: plumbing

    /// Only the branches the layout defines (spec §4.2): `roster`,
    /// `requests`, `m/<kid>`. A remote may carry anything else — a host's
    /// "initialise with a README" `main`, someone's feature branch,
    /// `origin/HEAD` — and listing those would hand `list`/`changes`
    /// blobs the store never promised. `requireEmptyRemote` deliberately
    /// does NOT go through here: for "is this repo empty?" every ref counts.
    private func branches() throws -> [String] {
        let text = String(decoding: try run(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/"]), as: UTF8.self)
        return text.split(separator: "\n").map { String($0.dropFirst("origin/".count)) }
            .filter { $0 == "roster" || $0 == "requests" || $0.hasPrefix("m/") }
    }

    private func head(of branch: String) throws -> String? {
        if let known = heads[branch] { return known }
        let sha: String?
        do {
            sha = String(decoding: try run(["rev-parse", "--verify", "-q", "refs/remotes/origin/\(branch)"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.failed { sha = nil }
        heads[branch] = sha
        return sha
    }

    /// `ls-tree -r -l` lines: `<mode> blob <sha> <size>\t<path>`.
    private func tree(commit: String, branch: String) throws -> [StoreEntry] {
        let text = String(decoding: try run(["ls-tree", "-r", "-l", commit]), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let meta = line[line.startIndex..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard meta.count == 4, meta[1] == "blob", let size = Int(meta[3]) else { return nil }
            return StoreEntry(path: branch + "/" + line[line.index(after: tab)...], size: size, version: String(meta[2]))
        }
    }

    private func commitAndPush(branch: String, items: [(String, Blob?)]) throws {
        let parent = try head(of: branch)
        let index = dir.appendingPathComponent("index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = [ "GIT_INDEX_FILE": index.path ]
        if let parent { _ = try run(["read-tree", parent], env: env) }
        for (rest, blob) in items {
            if let blob {
                let sha: String
                switch blob {
                case .data(let data):
                    sha = try hashObject(stdin: data)
                case .file(let url):
                    sha = try hashObject(file: url)
                }
                _ = try run(["update-index", "--add", "--cacheinfo", "100644,\(sha),\(rest)"], env: env)
            } else {
                // Removal without a work tree: a zero-mode, null-sha entry
                // through --index-info drops the path from the private index.
                let line = Data("0 0000000000000000000000000000000000000000\t\(rest)\n".utf8)
                _ = try run(["update-index", "--index-info"], stdin: line, env: env)
            }
        }
        let treeSha = String(decoding: try run(["write-tree"], env: env), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var commitArgs = ["commit-tree", treeSha, "-m", items.map(\.0).sorted().joined(separator: "\n")]
        if let parent { commitArgs += ["-p", parent] }
        let commit = String(decoding: try run(commitArgs, env: [
            "GIT_AUTHOR_NAME": "Infinitus", "GIT_AUTHOR_EMAIL": "\(author)@infinitus.run",
            "GIT_COMMITTER_NAME": "Infinitus", "GIT_COMMITTER_EMAIL": "\(author)@infinitus.run",
        ]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["push", "-q", "origin", "\(commit):refs/heads/\(branch)"])
        _ = try run(["update-ref", "refs/remotes/origin/\(branch)", commit])
    }

    private func hashObject(stdin data: Data) throws -> String {
        String(decoding: try run(["hash-object", "-w", "--stdin"], stdin: data), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `--no-filters`: a path (unlike `--stdin`) is subject to the
    /// attributes and EOL machinery, and ciphertext must reach the object
    /// database byte for byte.
    private func hashObject(file url: URL) throws -> String {
        String(decoding: try run(["hash-object", "-w", "--no-filters", "--", url.path]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git synchronously. Callers are the CLI (blocking is fine) and
    /// the app's background publish task (never the main thread).
    @discardableResult
    private func run(_ args: [String], stdin: Data? = nil, env extra: [String: String] = [:],
                     useGitDir: Bool = true) throws -> Data {
        // NSTask/NSPipe objects and their blob buffers are autoreleased;
        // see DrainingPool.swift.
        try drainingPool { try runOnce(args, stdin: stdin, env: extra, useGitDir: useGitDir) }
    }

    /// git's own words for "you are not on the tip". A server-side hook
    /// refusal ("[remote rejected]") matches too and costs one wasted
    /// retry — better than treating a real race as a hard failure.
    static func isRaceRejection(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("non-fast-forward") || text.contains("fetch first") || text.contains("rejected")
    }

    /// Variables that would point git at ANOTHER repository. `init
    /// --bare <path>` runs without `--git-dir`, so an inherited GIT_DIR
    /// (a git hook, a CI step, an exported shell variable) silently
    /// redirects it (#55).
    static let scrubbedEnv = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                              "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"]

    /// The child's environment: the parent's, minus anything that
    /// redirects git, plus ours. `GIT_TERMINAL_PROMPT=0` keeps a
    /// credential prompt from hanging a background publish.
    /// `GIT_CONFIG_NOSYSTEM` is deliberately NOT set — it would drop
    /// Apple git's osxkeychain credential helper for token-less https
    /// remotes. `extra` (the private `GIT_INDEX_FILE`) is applied last,
    /// so it survives.
    static func childEnvironment(base: [String: String], extra: [String: String], token: String?) -> [String: String] {
        var env = base
        for key in scrubbedEnv { env.removeValue(forKey: key) }
        env["GIT_TERMINAL_PROMPT"] = "0"
        if let token { env[Self.tokenEnv] = token }
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Stale `*.lock` files a killed git left behind (`packed-refs.lock`,
    /// a ref's `.lock` under `refs/` — this adapter's own index lives
    /// outside gitDir, fresh per push, so never `index.lock`): git
    /// refuses to write while one exists, so a crash or a hard quit
    /// mid-push would wedge every later publish. Only files older than
    /// `age` go — a lock a live child holds is younger. Top level plus
    /// `refs/` only: `objects/` is thousands of files on a real store
    /// and its locks are not ours to clear.
    static func sweepLocks(in gitDir: URL, olderThan age: TimeInterval = 600, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        var found: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: gitDir.path)) ?? [] where name.hasSuffix(".lock") {
            found.append(gitDir.appendingPathComponent(name))
        }
        let refs = gitDir.appendingPathComponent("refs")
        for sub in (try? fm.subpathsOfDirectory(atPath: refs.path)) ?? [] where sub.hasSuffix(".lock") {
            found.append(refs.appendingPathComponent(sub))
        }
        var swept: [String] = []
        for url in found {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > age else { continue }
            guard (try? fm.removeItem(at: url)) != nil else { continue }
            swept.append(url.path)
        }
        return swept
    }

    /// `https://user:token@host/repo.git` → `https://•••@host/repo.git`.
    /// The userinfo itself may contain "/" (a base64-ish token), so only
    /// "@", whitespace and quotes end the match — erring toward masking
    /// too much rather than leaking a credential that has one.
    public static func masked(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([a-zA-Z][a-zA-Z0-9+.-]*://)[^@\\s'\"]+@") else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "$1•••@")
    }

    /// The stderr reader's landing pad; `drain` joins the group before
    /// anyone reads it, so there is nothing to synchronise past that.
    private final class Buffer: @unchecked Sendable { var data = Data() }

    /// stdout and stderr read at the SAME time. Sequentially, a child
    /// that fills the other pipe's 64 KB buffer first never exits: `git
    /// push` writes progress to stderr while we block on stdout, and the
    /// publish hangs (2026-09-06). Same bytes, same order, no timeout.
    static func drain(out: FileHandle, err: FileHandle) -> (out: Data, err: Data) {
        let buffer = Buffer()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) { buffer.data = err.readDataToEndOfFile() }
        let stdout = out.readDataToEndOfFile()
        group.wait()
        return (stdout, buffer.data)
    }

    /// Writes the child's stdin and closes it, off the draining thread:
    /// written first and in full, a blob larger than the pipe would block
    /// against a child that is itself blocked writing stdout (#55). A
    /// child that exited without reading (bad `--git-dir`, a refused
    /// command) makes the write fail with EPIPE instead of raising
    /// SIGPIPE at the process; its exit status carries the story.
    static func feed(_ handle: FileHandle, _ data: Data) {
        #if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        _ = ignoreSigpipe   // Linux has no per-descriptor switch
        #endif
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
    #if !canImport(Darwin)
    private static let ignoreSigpipe: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    #endif

    private func runOnce(_ args: [String], stdin: Data?, env extra: [String: String], useGitDir: Bool) throws -> Data {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // Foundation has no Process here; InfinitusCore is linked into the
        // phone app, which never drives git itself (spec §6.2: the phone
        // hands team work to its Mac over the mirror).
        throw GitError.unavailable
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var argv = ["git"]
        if useGitDir { argv += ["--git-dir", gitDir.path] }
        if token != nil {
            argv += ["-c", "credential.helper=",
                     "-c", "credential.helper=!f() { echo username=infinitus; echo \"password=$\(Self.tokenEnv)\"; }; f"]
        }
        argv += args
        p.arguments = argv
        p.environment = Self.childEnvironment(base: ProcessInfo.processInfo.environment, extra: extra, token: token)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let feeding = DispatchGroup()
        if let stdin {
            let input = Pipe()
            p.standardInput = input
            try p.run()
            DispatchQueue.global(qos: .utility).async(group: feeding) { Self.feed(input.fileHandleForWriting, stdin) }
        } else {
            p.standardInput = FileHandle.nullDevice
            try p.run()
        }
        // Both pipes at once (see `drain`) while stdin is fed, then wait:
        // any one of the three blocking on another would hang the publish.
        let (data, errData) = Self.drain(out: out.fileHandleForReading, err: err.fileHandleForReading)
        feeding.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw GitError.failed(command: args.joined(separator: " "), status: p.terminationStatus,
                                  stderr: String(decoding: errData, as: UTF8.self))
        }
        return data
        #endif
    }
}

/// What the pane and the CLI print. Both interpolate the error
/// (`"\(error)"`), and a bare enum would read "notEmpty" or
/// "failed(command: …, status: 128, stderr: …)" at the user.
extension TeamGit.GitError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .failed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(command) failed (\(status))" + (detail.isEmpty ? "" : ": \(detail)")
        case .notOpen: return "the team store is not open"
        case .badPath(let path): return "\(path) is not a team store path"
        case .raceLost: return "another writer pushed first"
        case .unavailable: return "this platform runs no git (the phone hands team work to its Mac)"
        case .notEmpty: return "That remote already has content — use an empty repository"
        }
    }
}
