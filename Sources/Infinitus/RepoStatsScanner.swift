// Sources/Infinitus/RepoStatsScanner.swift
import Foundation
import CryptoKit
import InfinitusCore

/// Commits / lines / PRs from the repos Claude Code sessions worked in.
/// Cached per repo by HEAD: `git log` runs only when HEAD moved, `gh`
/// at most hourly. Author = the union of `user.email` over the repos —
/// no email to type anywhere.
actor RepoStatsScanner {
    struct Outcome: Sendable {
        var days: [String: Stats.Day] = [:]
        var repos: [String] = []
        var skipped: [String] = []       // no user.email
        var timedOut: [String] = []      // git log exceeded the timeout — cached days still counted
        /// PR data comes from gh (a fetch succeeded at some point) — sticky across scans.
        var ghUsed = false
        /// Fixed, informational — carried here (not hardcoded in StatsModel)
        /// so the scanner owns the wording for what its own scope means.
        var notes: [String] = []
    }

    private struct RepoCache: Codable {
        var version = 1
        var head: String
        var emails: [String]
        var days: [String: Stats.Day]
        var prsFetchedAt: Date?
        var prDays: [String: Stats.Day]
    }

    private static let dir: URL = AppSupport.root().appendingPathComponent("stats/repos")
    private static let ghInterval: TimeInterval = 3600
    private static let branchNote = "commits on unmerged branches aren't counted"

    func scan(cwds: Set<String>, since: Date) async -> Outcome {
        var outcome = Outcome()
        var seen: Set<String> = []
        var emails: Set<String> = []
        var roots: [(root: String, common: String, email: String?)] = []
        for cwd in cwds.sorted() where FileManager.default.fileExists(atPath: cwd) {
            // INVARIANT: one repo = one `--git-common-dir`, whatever its
            // worktrees are called. `--show-toplevel` differs per linked
            // worktree, so deduping on it counted every history once per
            // worktree (banyan ×7, this repo ×5 on the dev Mac). The
            // common dir is the dedupe key and the repo cache's key; the
            // FIRST worktree's toplevel stays the directory git/gh run
            // in. rev-parse answers in the order the options are given.
            guard let out = try? await git(["rev-parse", "--path-format=absolute",
                                            "--git-common-dir", "--show-toplevel"], cwd: cwd) else { continue }
            let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty, !seen.contains(lines[0]) else { continue }
            let (common, root) = (lines[0], lines[1])
            seen.insert(common)
            let email = (try? await git(["config", "user.email"], cwd: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            if let email { emails.insert(email) }
            roots.append((root, common, email))
        }
        let authors = emails.sorted()
        for (root, common, email) in roots {
            guard email != nil, !authors.isEmpty else { outcome.skipped.append(root); continue }
            let cacheURL = Self.dir.appendingPathComponent(Self.key(common) + ".json")
            let decoded = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(RepoCache.self, from: $0) }
            // A cache from a stale schema (Stats.Day's fields changed) is
            // treated the same as no cache at all — same idiom as
            // StatsScanner.Cache.version.
            let loaded = decoded?.version == 1 ? decoded : nil
            var cache = loaded ?? RepoCache(head: "", emails: [], days: [:], prsFetchedAt: nil, prDays: [:])
            let head = (try? await git(["rev-parse", "HEAD"], cwd: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if loaded == nil || cache.head != head || cache.emails != authors {
                // HEAD only — not --all: an unbounded ref walk on a repo with
                // many branches (worktrees, scratch branches) can run for
                // many minutes and pin gigabytes of numstat text in memory
                // (measured: one repo, 90s+, 1.6 GB RSS). --max-count is a
                // second belt against a single branch with a huge history.
                //
                // `-F`: --author is a limiting PATTERN, matched as a
                // regex by default. An email is full of metacharacters
                // (`.`, and `+` in a plus-alias), and escaping them is
                // not safe either — git's default is POSIX BASIC regex,
                // where `\+` is GNU's one-or-more quantifier, so
                // `me\+work@x` matches `mework@x` and not the address
                // it was built from (probed 2026-09-04). Fixed strings
                // are what "this exact author" actually means.
                var args = ["log", "HEAD", "-F", "--no-merges", "--numstat", "--date=iso-strict",
                            "--max-count=20000", "--format=\(RepoStats.logFormat)",
                            "--since=\(ISO8601DateFormatter().string(from: since))"]
                for a in authors { args.append("--author=\(a)") }
                do {
                    let text = try await git(args, cwd: root)
                    let days = RepoStats.days(commits: RepoStats.parseLog(text), prs: [], repo: root)
                    cache = RepoCache(head: head, emails: authors, days: days,
                                      prsFetchedAt: cache.prsFetchedAt, prDays: cache.prDays)
                } catch is TimedOut {
                    // The fresh git log didn't finish, but yesterday's
                    // cached days are still good — merge them in so a
                    // slow repo regresses to stale data, never to zero.
                    for (k, d) in cache.days { outcome.days[k] = (outcome.days[k] ?? Stats.Day()) + d }
                    for (k, d) in cache.prDays { outcome.days[k] = (outcome.days[k] ?? Stats.Day()) + d }
                    outcome.timedOut.append(root)
                    continue
                } catch {
                    let days = RepoStats.days(commits: [], prs: [], repo: root)
                    cache = RepoCache(head: head, emails: authors, days: days,
                                      prsFetchedAt: cache.prsFetchedAt, prDays: cache.prDays)
                }
            }
            if let ghPath = Self.ghPath,
               cache.prsFetchedAt.map({ Date().timeIntervalSince($0) > Self.ghInterval }) ?? true,
               // `--limit 200` silently truncated a busy year; the search
               // filter bounds the query by date instead of by count.
               let json = try? await Self.run(ghPath, ["pr", "list", "--author", "@me", "--state", "all",
                                                       "--limit", "1000",
                                                       "--search", "created:>=\(Self.ghDay.string(from: since))",
                                                       "--json", "number,createdAt,mergedAt"], cwd: root) {
                cache.prDays = RepoStats.days(commits: [], prs: RepoStats.parsePRs(Data(json.utf8)), repo: root)
                cache.prsFetchedAt = Date()
                outcome.ghUsed = true
            } else if cache.prsFetchedAt != nil {
                outcome.ghUsed = true
            }
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
            outcome.repos.append(root)
            for (k, d) in cache.days { outcome.days[k] = (outcome.days[k] ?? Stats.Day()) + d }
            for (k, d) in cache.prDays { outcome.days[k] = (outcome.days[k] ?? Stats.Day()) + d }
        }
        if !outcome.repos.isEmpty { outcome.notes.append(Self.branchNote) }
        return outcome
    }

    private static func key(_ root: String) -> String {
        // Full-path SHA-256 hex — no truncation, no collisions on shared tails.
        SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// GitHub search qualifiers take a plain `yyyy-MM-dd`.
    private static let ghDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func git(_ args: [String], cwd: String) async throws -> String {
        try await Self.run("/usr/bin/git", args, cwd: cwd)
    }

    private struct TimedOut: Error {}

    /// CswapCLI.run's shape: the blocking Process on a GCD thread, bridged
    /// by a continuation (running it inline hung on macOS 26). A repo with
    /// a huge history (or a stuck `gh`) must not stall the whole scan —
    /// `timeout` seconds after launch, an armed `DispatchWorkItem`
    /// terminates the child; a clean exit cancels it first.
    private static func run(_ exe: String, _ args: [String], cwd: String, timeout: TimeInterval = 90) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                env["GIT_OPTIONAL_LOCKS"] = "0"
                env["GH_PROMPT_DISABLED"] = "1"
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let timeoutItem = DispatchWorkItem { p.terminate() }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timeoutItem.cancel()
                if p.terminationReason == .uncaughtSignal, p.terminationStatus != 0 {
                    cont.resume(throwing: TimedOut())
                    return
                }
                guard p.terminationStatus == 0 else {
                    cont.resume(throwing: NSError(domain: "RepoStatsScanner", code: Int(p.terminationStatus)))
                    return
                }
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
