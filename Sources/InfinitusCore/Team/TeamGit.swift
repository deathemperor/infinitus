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
        /// A network command printed nothing for `stallTimeout` and was
        /// killed. Not `.failed`: `putAll`'s race retry must never fire
        /// on a stall, and the pane words it differently.
        case stalled(command: String, idle: TimeInterval)
    }

    /// The idle watchdog on `fetch`, `push` and `ls-remote`: a child that
    /// prints NOTHING to stderr for this long is killed and the command
    /// throws `.stalled`. Idle, not slow — `--progress` keeps a moving
    /// transfer talking, however slow the link, so only a dead one dies.
    /// The 2026-09-07 "Approving…" hang was a 55 s silent fetch that did
    /// succeed; the default has to outlast one of those. Plumbing
    /// (`hash-object` on a big file, `read-tree`) is never watched.
    nonisolated(unsafe) public static var stallTimeout: TimeInterval = 90
    /// After this long with nothing said, `activity` gets one "waiting"
    /// line so a silent connect does not look like a hung app.
    nonisolated(unsafe) public static var quietNotice: TimeInterval = 10
    /// git's latest progress line ("Receiving objects: 45% (…)") for a
    /// UI. Process-wide: the app opens a fresh `TeamClient` per call, so
    /// an instance property would have to be threaded through every one.
    /// Called on the reading thread, at most every ~2 s.
    public static let activity = ActivitySink()

    public final class ActivitySink: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (String) -> Void)?
        public func set(_ sink: (@Sendable (String) -> Void)?) { lock.lock(); self.sink = sink; lock.unlock() }
        func fire(_ line: String) {
            lock.lock(); let s = sink; lock.unlock()
            s?(line)
        }
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
    /// Branches a fresh store's first sync fetches; nil = every branch.
    /// A join needs `roster` and `requests` only (#321): fetching every
    /// branch meant the leader's 1.2 GB of transcripts, twenty minutes
    /// at 1 MB/s, before the request was even pushed. Set before `open()`.
    public var firstSyncBranches: [String]?
    /// What `sync()` fetches when the caller names no branches (nil =
    /// every branch). `TeamClient` sets it to the roster, the requests,
    /// every `m/*` and its own `t/<kid>` — never other members'
    /// transcript branches, which `TeamClient.fetch` adds for the
    /// senders whose hint names this reader (#321).
    public var defaultBranches: [String]?

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
        if fresh { try sync(branches: firstSyncBranches) }
    }

    // MARK: TeamStore

    public func sync() throws { try sync(branches: nil) }

    /// `branches` nil fetches them all; a list fetches just those (the
    /// prune then only touches those refs). Each is a pattern, not an
    /// exact ref: a branch nobody has pushed yet (`requests`, before the
    /// first join) then matches nothing instead of failing the fetch.
    public func sync(branches: [String]?) throws {
        let branches = branches ?? defaultBranches
        // No refspec at all would fall back to the remote's configured
        // one and fetch everything.
        if let branches, branches.isEmpty { return }
        heads = [:]
        let refspecs = branches?.map { "+refs/heads/\($0)*:refs/remotes/origin/\($0)*" }
            ?? ["+refs/heads/*:refs/remotes/origin/*"]
        _ = try run(["fetch", "--progress", "--prune", "origin"] + refspecs, network: true)
    }

    /// Spec §6.1's "empty private repo", asked of the REMOTE. Not
    /// `branches()` — that filters to the store's own branches (Task 4),
    /// so a repo holding only `main` or a README would read as empty —
    /// and not the local refs, which a fresh mirror has none of either
    /// way.
    public func requireEmptyRemote() throws {
        guard opened else { throw GitError.notOpen }
        let text = String(decoding: try run(["ls-remote", "origin"], network: true), as: UTF8.self)
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

    /// Every version of `path` on its branch, newest first and the
    /// current one included, at most `limit` deep: a first fetch walks
    /// the roster back to one its trust root signed (`TeamClient.fetch`).
    public func history(of path: String, limit: Int) throws -> [Data] {
        guard opened else { throw GitError.notOpen }
        guard let (branch, rest) = StorePath.branch(of: path) else { throw GitError.badPath(path) }
        guard let head = try head(of: branch) else { return [] }
        let shas = String(decoding: try run(["rev-list", "--max-count=\(limit)", head, "--", rest]), as: UTF8.self)
            .split(separator: "\n")
        return try shas.compactMap { sha in
            do { return try run(["cat-file", "blob", "\(sha):\(rest)"]) } catch GitError.failed { return nil }
        }
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
            .filter { $0 == "roster" || $0 == "requests" || $0.hasPrefix("m/") || $0.hasPrefix("t/") }
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
        _ = try run(["push", "--progress", "origin", "\(commit):refs/heads/\(branch)"], network: true)
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
    /// `network` puts the command under the idle watchdog and feeds its
    /// progress to `activity`.
    @discardableResult
    private func run(_ args: [String], stdin: Data? = nil, env extra: [String: String] = [:],
                     useGitDir: Bool = true, network: Bool = false) throws -> Data {
        // NSTask/NSPipe objects and their blob buffers are autoreleased;
        // see DrainingPool.swift.
        try drainingPool { try runOnce(args, stdin: stdin, env: extra, useGitDir: useGitDir, network: network) }
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

    /// The readers' landing pad. Locked, not group-joined: a watched
    /// drain that killed its child may return before a reader has seen
    /// EOF (a helper process can hold the pipe a moment longer).
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var lastByte = Date()
        func append(out data: Data) { lock.lock(); out.append(data); lock.unlock() }
        func append(err data: Data) { lock.lock(); err.append(data); lastByte = Date(); lock.unlock() }
        var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastByte) }
        var contents: (out: Data, err: Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }

    /// The idle watchdog on a network command (see `stallTimeout`).
    struct Watch {
        var idle: TimeInterval = TeamGit.stallTimeout
        var quiet: TimeInterval = TeamGit.quietNotice
        /// git's latest stderr line, throttled; the "waiting" notice.
        var activity: (@Sendable (String) -> Void)?
        /// Kills the child; the pipes close behind it.
        var kill: @Sendable () -> Void
    }

    /// stdout and stderr read at the SAME time. Sequentially, a child
    /// that fills the other pipe's 64 KB buffer first never exits: `git
    /// push` writes progress to stderr while we block on stdout, and the
    /// publish hangs (2026-09-06). Same bytes, same order. Unwatched: no
    /// timeout. Watched: stderr is read as it arrives, every byte resets
    /// the idle clock, and a child silent for `watch.idle` is killed —
    /// `stalled` says so, and the caller throws instead of parsing.
    static func drain(out: FileHandle, err: FileHandle, watch: Watch? = nil) -> (out: Data, err: Data, stalled: Bool) {
        let buffer = Buffer()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)
        queue.async(group: group) {
            var lastReport = Date.distantPast, tail = ""
            while true {
                let chunk = err.availableData
                if chunk.isEmpty { break }
                buffer.append(err: chunk)
                guard let watch, let activity = watch.activity else { continue }
                // Progress lines are `\r`-updated; the last segment of the
                // last line is what a terminal would show right now.
                tail = Self.lastLine(tail + String(decoding: chunk, as: UTF8.self))
                let now = Date()
                if !tail.isEmpty, now.timeIntervalSince(lastReport) >= 2 { lastReport = now; activity(tail) }
            }
        }
        queue.async(group: group) { buffer.append(out: out.readDataToEndOfFile()) }
        guard let watch else {
            group.wait()
            let (o, e) = buffer.contents
            return (o, e, false)
        }
        var stalled = false, noticed = false
        while group.wait(timeout: .now() + 1) == .timedOut {
            let idle = buffer.idle
            if idle >= watch.idle {
                stalled = true
                watch.kill()
                // The readers finish when the pipes close; a helper that
                // survives its parent may hold them a little longer.
                _ = group.wait(timeout: .now() + 5)
                break
            }
            if !noticed, idle >= watch.quiet {
                noticed = true
                watch.activity?("waiting for the store to answer…")
            }
        }
        let (o, e) = buffer.contents
        return (o, e, stalled)
    }

    /// The last non-empty `\r`/`\n`-separated segment of `text`, so a
    /// progress stream reads as its current line.
    static func lastLine(_ text: String) -> String {
        for piece in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }).reversed() {
            let line = piece.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return ""
    }

    /// stderr for an error message: each `\r`-updated progress line
    /// collapsed to its final state, so `--progress` output does not
    /// land in the pane as a hundred half-drawn percentages.
    static func collapsed(_ stderr: Data) -> String {
        String(decoding: stderr, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
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

    /// The git binary, found once. On a Mac `/usr/bin/git` is the xcrun
    /// shim: every call re-resolves the developer dir (~100 ms, three
    /// times git's own start), and a publish is dozens of calls — the
    /// Team test suites spent 17 CI minutes mostly there (2026-09-07).
    /// `xcrun --find` names the real binary; elsewhere the first `git`
    /// on PATH; `/usr/bin/env git` when neither answers.
    static let gitExecutable: URL = {
        #if os(macOS)
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["--find", "git"]
        let out = Pipe()
        xcrun.standardOutput = out; xcrun.standardError = FileHandle.nullDevice
        if (try? xcrun.run()) != nil {
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            xcrun.waitUntilExit()
            if xcrun.terminationStatus == 0, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        #endif
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(dir) + "/git"
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }()

    private func runOnce(_ args: [String], stdin: Data?, env extra: [String: String], useGitDir: Bool, network: Bool) throws -> Data {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // Foundation has no Process here; InfinitusCore is linked into the
        // phone app, which never drives git itself (spec §6.2: the phone
        // hands team work to its Mac over the mirror).
        throw GitError.unavailable
        #else
        let p = Process()
        p.executableURL = Self.gitExecutable
        var argv: [String] = []
        if useGitDir { argv += ["--git-dir", gitDir.path] }
        if token != nil {
            argv += ["-c", "credential.helper=",
                     "-c", "credential.helper=!f() { echo username=infinitus; echo \"password=$\(Self.tokenEnv)\"; }; f"]
        }
        argv += args
        p.arguments = Self.gitExecutable.path == "/usr/bin/env" ? ["git"] + argv : argv
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
        let watch = network ? Watch(activity: { Self.activity.fire($0) }, kill: { Self.terminate(p) }) : nil
        let (data, errData, stalled) = Self.drain(out: out.fileHandleForReading, err: err.fileHandleForReading, watch: watch)
        feeding.wait()
        p.waitUntilExit()
        let command = args.joined(separator: " ")
        if stalled { throw GitError.stalled(command: command, idle: watch?.idle ?? Self.stallTimeout) }
        guard p.terminationStatus == 0 else {
            throw GitError.failed(command: command, status: p.terminationStatus, stderr: Self.collapsed(errData))
        }
        return data
        #endif
    }

    #if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
    /// SIGTERM, then SIGKILL for a child that ignores it. git dying
    /// closes its helper's stdin, so `git-remote-https` follows on its own.
    static func terminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        for _ in 0..<30 where p.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        #if canImport(Darwin) || canImport(Glibc)
        if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }   // Windows' terminate() is already TerminateProcess
        #endif
    }
    #endif
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
        case .stalled(let command, let idle):
            return "the store did not answer for \(Int(idle)) s (git \(command.split(separator: " ").first ?? "") gave up)"
        }
    }
}
