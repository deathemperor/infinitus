// Sources/InfinitusCore/RepoStats.swift
import Foundation

/// git / gh output → `Stats.Day`s. Pure parsers; the app runs the
/// commands (RepoStatsScanner) — `Process` is macOS-only and this module
/// also builds for the phone.
public enum RepoStats {
    /// `git log --format=<logFormat> --numstat --date=iso-strict`: one
    /// record per commit, RS-separated, fields US-separated.
    public static let logFormat = "%x1e%H%x1f%aI%x1f%ae%x1f%s%x1f%(trailers:key=Co-authored-by,valueonly,separator=%x20)"

    public struct Commit: Equatable, Sendable {
        public let sha: String
        public let at: Date
        public let email: String
        public let coAuthoredByClaude: Bool
        public let revert: Bool
        public var added = 0
        public var removed = 0
        public var files = 0
    }

    public struct PR: Equatable, Sendable {
        public let number: Int
        public let createdAt: Date
        public let mergedAt: Date?
    }

    public static func parseLog(_ text: String) -> [Commit] {
        let iso = ISO8601DateFormatter()
        var out: [Commit] = []
        for record in text.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let head = lines.first else { continue }
            let fields = head.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let at = iso.date(from: fields[1]) else { continue }
            let trailers = fields.count > 4 ? fields[4] : ""
            var commit = Commit(sha: fields[0], at: at, email: fields[2],
                                coAuthoredByClaude: trailers.localizedCaseInsensitiveContains("claude"),
                                revert: fields[3].hasPrefix("Revert "))
            for line in lines.dropFirst() {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count >= 3 else { continue }
                commit.files += 1
                commit.added += Int(cols[0]) ?? 0      // "-" = binary
                commit.removed += Int(cols[1]) ?? 0
            }
            out.append(commit)
        }
        return out
    }

    /// `gh pr list --json number,createdAt,mergedAt`.
    public static func parsePRs(_ data: Data) -> [PR] {
        let iso = ISO8601DateFormatter()
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int,
                  let created = (row["createdAt"] as? String).flatMap(iso.date(from:)) else { return nil }
            return PR(number: number, createdAt: created,
                      mergedAt: (row["mergedAt"] as? String).flatMap(iso.date(from:)))
        }
    }

    public static func days(commits: [Commit], prs: [PR], repo: String,
                            calendar: Calendar = .current) -> [String: Stats.Day] {
        var days: [String: Stats.Day] = [:]
        for c in commits {
            var d = days[Stats.dayKey(c.at, calendar: calendar)] ?? Stats.Day()
            d.commits += 1
            d.linesAdded += c.added
            d.linesRemoved += c.removed
            d.filesTouched += c.files
            if c.coAuthoredByClaude { d.coAuthoredByClaude += 1 }
            if c.revert { d.reverts += 1 }
            d.repos.insert(repo)
            days[Stats.dayKey(c.at, calendar: calendar)] = d
        }
        for pr in prs {
            var opened = days[Stats.dayKey(pr.createdAt, calendar: calendar)] ?? Stats.Day()
            opened.prsOpened += 1
            days[Stats.dayKey(pr.createdAt, calendar: calendar)] = opened
            if let merged = pr.mergedAt {
                var m = days[Stats.dayKey(merged, calendar: calendar)] ?? Stats.Day()
                m.prsMerged += 1
                m.mergeHoursTotal += merged.timeIntervalSince(pr.createdAt) / 3600
                m.mergeCount += 1
                days[Stats.dayKey(merged, calendar: calendar)] = m
            }
        }
        return days
    }
}
