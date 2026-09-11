import Foundation

/// The pure half of the app's Haiku session namer (SessionNamer.swift):
/// what a name is made of, the prompt, and the cleanup of the reply.
public enum SessionNaming {
    /// Claude Code names every session it starts "<cwd basename>-<xx>"
    /// (limitless-bf, banyan-51, green-suites-4-14) unless the user
    /// renames it — those are the sessions the user calls "without
    /// names", and the ones Haiku titles.
    public static func isPlaceholder(_ name: String?, cwd: String) -> Bool {
        guard let name, !name.isEmpty else { return true }
        let base = (cwd as NSString).lastPathComponent
        guard name.hasPrefix(base + "-") else { return false }
        let tail = name.dropFirst(base.count + 1)
        return !tail.isEmpty && tail.count <= 3 && tail.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
    }

    /// What a row shows: the user's own name, else Haiku's title, else
    /// the repo.
    public static func displayName(name: String?, autoName: String?, cwd: String) -> String {
        if !isPlaceholder(name, cwd: cwd), let name { return name }
        if let autoName, !autoName.isEmpty { return autoName }
        return name ?? (cwd as NSString).lastPathComponent
    }

    /// A change here (a new goal after /clear, a todo list that grew, a
    /// new phase) is what earns a fresh ask.
    public static func fingerprint(_ p: SessionProgress) -> String {
        [p.goal ?? "", p.phase ?? "", "\(p.todos?.total ?? 0)", p.todos?.activeForm ?? ""]
            .joined(separator: "\u{1f}")
    }

    /// "[Infinitus]"-prefixed so the Stats scanner never counts it as a
    /// typed message.
    public static func prompt(_ p: SessionProgress) -> String {
        var lines = ["[Infinitus] Title this coding session in 3 to 6 words, like a short headline. Reply with the title only — no quotes, no trailing period.", ""]
        lines.append("Goal: " + String((p.goal ?? "").prefix(600)))
        if let t = p.todos, t.total > 0 {
            lines.append("Todos: \(t.done) of \(t.total) done" + (t.activeForm.map { " — now: \($0)" } ?? ""))
        }
        if let now = p.nowDoing, !now.isEmpty { lines.append("Now: " + String(now.prefix(200))) }
        if let phase = p.phase { lines.append("Phase: " + phase) }
        return lines.joined(separator: "\n")
    }

    /// First non-empty line, quotes and a trailing period stripped,
    /// capped — Haiku occasionally adds a flourish.
    public static func clean(_ raw: String) -> String? {
        guard var line = raw.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`."))
        if line.lowercased().hasPrefix("title:") { line = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard !line.isEmpty, line.count <= 80 else { return nil }
        return line
    }
}
