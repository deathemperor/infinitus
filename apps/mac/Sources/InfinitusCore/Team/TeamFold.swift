import Foundation

/// The pure fold `team-days` answers from (#1592; what the git-store
/// publisher's `collect` was): the stats scan's per-file entries, minus
/// the private projects, into days. The desktop's Team publisher sends
/// them to Infinitus Connect; nothing here touches a store.
public enum TeamFold {
    public struct Collected: Equatable, Sendable {
        public var days: [String: Stats.Day] = [:]
        public init() {}
    }

    /// The same rule `StatsScanner.scan` walks with: `<project>/<sid>.jsonl`
    /// is a session, `<project>/<sid>/subagents/<agent>.jsonl` one of its
    /// sub-agents. For Codex files the "project dir" is a date; callers
    /// ignore it there. String work only — `URL(fileURLWithPath:)` lstats
    /// the path, and this runs over every scan entry (#346).
    public static func transcriptIdentity(_ path: String) -> (session: String, agent: String?, projectDir: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let n = parts.count
        guard n >= 2 else { return (stem(parts.last ?? ""), nil, "") }
        if parts[n - 2] == "subagents", n >= 4 {
            return (String(parts[n - 3]), stem(parts[n - 1]), String(parts[n - 4]))
        }
        return (stem(parts[n - 1]), nil, String(parts[n - 2]))
    }

    /// `URL.deletingPathExtension().lastPathComponent` without the URL.
    private static func stem(_ name: Substring) -> String {
        if let dot = name.lastIndex(of: "."), dot > name.startIndex { return String(name[..<dot]) }
        return String(name)
    }

    /// Folds the scan's per-file entries minus excluded projects into
    /// days (Stats v2 `+`).
    public static func collect(entries: [String: StatsScanner.FileEntry], exclusions: TeamExclusions) -> Collected {
        var out = Collected()
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let identity = transcriptIdentity(path)
            let claude = entry.engine == Stats.Engine.claude.rawValue
            if exclusions.excludes(cwd: entry.cwd, projectDir: claude ? identity.projectDir : nil) { continue }
            for (key, day) in entry.daysWithOpenStretch() { out.days[key] = (out.days[key] ?? Stats.Day()) + day }
        }
        for key in out.days.keys { out.days[key]!.finalizePeak() }
        return out
    }

    /// The entries with a day inside the history window (`historyDays`
    /// back from the start of today): what `collect` folds.
    public static func inWindow(_ entries: [String: StatsScanner.FileEntry], floorDay: String) -> [String: StatsScanner.FileEntry] {
        entries.filter { ($0.value.days.keys.max() ?? "") >= floorDay }
    }

    public static func floorDay(now: Date, historyDays: Int, calendar: Calendar) -> String {
        let floor = calendar.date(byAdding: .day, value: -historyDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        return Stats.dayKey(floor, calendar: calendar)
    }
}
