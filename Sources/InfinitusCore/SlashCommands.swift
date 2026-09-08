import Foundation

/// A Claude Code slash command or skill the composer's `/` menu offers
/// (T3 `ComposerCommandMenu.tsx` over the provider's command list). Read
/// from Claude Code's own files — `~/.claude/commands`, `<cwd>/.claude/commands`,
/// and the `skills/*/SKILL.md` folders — never from any engine.
public struct SlashCommand: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable {
        case userCommand = "user", projectCommand = "project", userSkill = "user-skill", projectSkill = "project-skill"
    }
    public let name: String
    public let description: String
    public let source: Source
    public init(name: String, description: String, source: Source) {
        self.name = name; self.description = description; self.source = source
    }
    public var id: String { "\(source.rawValue):\(name)" }
    /// What the composer inserts when the row is picked.
    public var insertion: String { "/\(name) " }
}

public enum SlashCommands {
    /// Project first so it shadows a same-named user command (Claude Code's
    /// own precedence); commands before skills; sorted by name.
    public static func discover(cwd: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> [SlashCommand] {
        let project = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
        let user = home.appendingPathComponent(".claude")
        var seen = Set<String>()
        var out: [SlashCommand] = []
        func add(_ c: SlashCommand) { if seen.insert(c.name).inserted { out.append(c) } }
        for c in commands(under: project.appendingPathComponent("commands"), source: .projectCommand, fm: fileManager) { add(c) }
        for c in commands(under: user.appendingPathComponent("commands"), source: .userCommand, fm: fileManager) { add(c) }
        for c in skills(under: project.appendingPathComponent("skills"), source: .projectSkill, fm: fileManager) { add(c) }
        for c in skills(under: user.appendingPathComponent("skills"), source: .userSkill, fm: fileManager) { add(c) }
        return out.sorted { $0.name < $1.name }
    }

    /// `composerSlashCommandSearch.ts`: prefix on name, then name substring,
    /// then description substring; case-insensitive; stable within a tier.
    public static func filter(_ all: [SlashCommand], query: String) -> [SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        let prefix = all.filter { $0.name.lowercased().hasPrefix(q) }
        let name = all.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        let desc = all.filter { !$0.name.lowercased().contains(q) && $0.description.lowercased().contains(q) }
        return prefix + name + desc
    }

    private static func commands(under dir: URL, source: SlashCommand.Source, fm: FileManager) -> [SlashCommand] {
        // `enumerator(atPath:)` yields paths relative to `dir`, sidestepping
        // `enumerator(at:)`'s absolute URLs, which can be symlink-resolved
        // (e.g. macOS's /var -> /private/var) and no longer share a literal
        // prefix with `dir.path` for character-offset math.
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        var out: [SlashCommand] = []
        for case let rel as String in e where rel.hasSuffix(".md") {
            guard !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let name = rel.dropLast(3).replacingOccurrences(of: "/", with: ":")
            let url = dir.appendingPathComponent(rel)
            out.append(SlashCommand(name: name, description: describe(url), source: source))
        }
        return out
    }

    private static func skills(under dir: URL, source: SlashCommand.Source, fm: FileManager) -> [SlashCommand] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name in
            let skill = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skill.path) else { return nil }
            return SlashCommand(name: name, description: describe(skill), source: source)
        }
    }

    /// Frontmatter `description:`; else the first non-empty body line.
    static func describe(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            var description: String?
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("description:") {
                    description = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                i += 1
            }
            if let description, !description.isEmpty { return description }
            lines = Array(lines.dropFirst(min(i + 1, lines.count)))
        }
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
