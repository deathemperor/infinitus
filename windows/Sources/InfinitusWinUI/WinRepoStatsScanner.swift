import Foundation
import InfinitusCore

public enum WinRepoStatsScanner {
    public struct Outcome: Sendable {
        public var days: [String: Stats.Day] = [:]
        public var repos: [String] = []
        public var skipped: [String] = []
        public var notes: [String] = []

        public init() {}
    }

    private struct RepoCache: Codable {
        var version = 1
        var head: String
        var emails: [String]
        var days: [String: Stats.Day]
    }

    public static var cacheDir: URL {
        WinSettingsStore.infinitusHome.appendingPathComponent("stats/repos")
    }

    private static func runProcess(_ executable: String, _ args: [String], cwd: String, timeout: TimeInterval = 10) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > timeout {
                process.terminate()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private static func findGit() -> String? {
        // Try where git.exe usually is, or via cmd /c where git
        let candidates = [
            "C:\\Program Files\\Git\\cmd\\git.exe",
            "C:\\Program Files\\Git\\bin\\git.exe",
            "C:\\Program Files (x86)\\Git\\cmd\\git.exe",
            "C:\\Users\\BM\\AppData\\Local\\Programs\\Git\\cmd\\git.exe",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Check PATH
        if let pathEnv = ProcessInfo.processInfo.environment["Path"] ?? ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ";") {
                let p = String(dir) + "\\git.exe"
                if FileManager.default.isExecutableFile(atPath: p) {
                    return p
                }
            }
        }
        return nil
    }

    public static func scan(cwds: Set<String>, since: Date) -> Outcome {
        var outcome = Outcome()
        guard let gitExe = findGit() else {
            outcome.notes.append("git not found — commits and lines aren't counted")
            return outcome
        }

        var seenCommon: Set<String> = []
        var roots: [(root: String, common: String, email: String?)] = []
        var emails: Set<String> = []

        for cwd in cwds.sorted() where FileManager.default.fileExists(atPath: cwd) {
            guard let out = runProcess(gitExe, ["rev-parse", "--git-common-dir", "--show-toplevel"], cwd: cwd) else { continue }
            let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty, !seenCommon.contains(lines[0]) else { continue }
            let (common, root) = (lines[0], lines[1])
            seenCommon.insert(common)

            let email = runProcess(gitExe, ["config", "user.email"], cwd: root)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEmail = (email?.isEmpty ?? true) ? nil : email
            if let trimmedEmail { emails.insert(trimmedEmail) }
            roots.append((root, common, trimmedEmail))
        }

        let authors = emails.sorted()
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let sinceFormatter = ISO8601DateFormatter()

        for (root, common, email) in roots {
            guard email != nil, !authors.isEmpty else {
                outcome.skipped.append(root)
                continue
            }

            let cacheFileName = common.replacingOccurrences(of: "\\", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_") + ".json"
            let cacheURL = cacheDir.appendingPathComponent(cacheFileName)
            let loaded = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(RepoCache.self, from: $0) }
            var cache = (loaded?.version == 1 ? loaded : nil)
                ?? RepoCache(head: "", emails: [], days: [:])

            let head = runProcess(gitExe, ["rev-parse", "HEAD"], cwd: root)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if loaded == nil || cache.head != head || cache.emails != authors {
                var args = ["log", "HEAD", "-F", "--no-merges", "--numstat", "--date=iso-strict",
                            "--max-count=20000", "--format=\(RepoStats.logFormat)",
                            "--since=\(sinceFormatter.string(from: since))"]
                for a in authors { args.append("--author=\(a)") }

                if let text = runProcess(gitExe, args, cwd: root, timeout: 20) {
                    let days = RepoStats.days(commits: RepoStats.parseLog(text), prs: [], repo: root)
                    cache = RepoCache(head: head, emails: authors, days: days)
                    if let data = try? JSONEncoder().encode(cache) {
                        try? data.write(to: cacheURL, options: .atomic)
                    }
                }
            }

            outcome.repos.append(root)
            for (k, d) in cache.days {
                outcome.days[k] = (outcome.days[k] ?? Stats.Day()) + d
            }
        }

        if !outcome.repos.isEmpty {
            outcome.notes.append("commits on unmerged branches aren't counted")
        }
        return outcome
    }
}
