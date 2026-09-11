import Foundation

/// Spec §7: Claude Code project directories this machine keeps private —
/// nothing from them is published (no transcript, no session row, no
/// `Stats.Day` contribution). Local to the machine, never sent; one
/// file for every team (`<base>/exclusions.json`).
public struct TeamExclusions: Codable, Equatable, Sendable {
    /// Absolute project directories, no trailing slash.
    public var projects: [String]

    public init(projects: [String] = []) { self.projects = projects.map(Self.normalise).filter { !$0.isEmpty } }

    private enum CodingKeys: String, CodingKey { case projects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projects: try c.decode([String].self, forKey: .projects))
    }

    static func normalise(_ path: String) -> String {
        var s = path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Claude Code's project directory name for a cwd — the same rule as
    /// `Transcript.path`: every non-alphanumeric character becomes `-`.
    public static func slug(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public mutating func set(_ project: String, excluded: Bool) {
        let p = Self.normalise(project)
        projects.removeAll { $0 == p }
        if excluded, !p.isEmpty { projects.append(p) }
    }

    /// `cwd` is the transcript's own cwd when it recorded one;
    /// `projectDir` the `~/.claude/projects/<dir>` it sits in (nil for
    /// Codex files, whose directories are dates). Either signal excludes
    /// on its own — the slug check runs regardless of `cwd`, so it can
    /// over-match a lossy slug; that's the safe direction.
    public func excludes(cwd: String?, projectDir: String?) -> Bool {
        for p in projects {
            if let cwd, cwd == p || cwd.hasPrefix(p + "/") { return true }
            if let projectDir, projectDir == Self.slug(p) { return true }
        }
        return false
    }

    public static func file(paths: TeamPaths) -> URL { paths.base.appendingPathComponent("exclusions.json") }

    public static func load(paths: TeamPaths) -> TeamExclusions {
        (try? Data(contentsOf: file(paths: paths))).flatMap { try? CanonicalJSON.decode(TeamExclusions.self, from: $0) }
            ?? TeamExclusions()
    }

    public func save(paths: TeamPaths) throws {
        try FileManager.default.createDirectory(at: paths.base, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(paths: paths), options: .atomic)
    }
}
