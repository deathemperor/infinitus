import Foundation

/// A named way to start a session (#165): folder, engine, permission
/// mode, model, an appended system prompt and a first prompt, saved on
/// the Mac (Settings › Profiles, `infinitusctl profile-set`) and mirrored
/// to the phone as chips in Start a session. Every field but the name is
/// optional — a profile fills in only what it names.
public struct SessionProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var cwd: String?
    /// "claude" (default) or "codex".
    public var engine: String?
    /// One of `SessionStart.permissionModes`; nil = supervised.
    public var permissionMode: String?
    /// `claude --model`.
    public var model: String?
    /// `claude --append-system-prompt`.
    public var systemPrompt: String?
    /// The first prompt the session opens with.
    public var prompt: String?
    /// Tools allowed without asking for a session born from this profile
    /// (#165), in `ToolApproval.Rule.text` form ("Edit", "Bash git"); the
    /// plugin's PreToolUse hook answers from them. Claude only.
    public var allowTools: [String]?

    public init(name: String, cwd: String? = nil, engine: String? = nil, permissionMode: String? = nil,
                model: String? = nil, systemPrompt: String? = nil, prompt: String? = nil,
                allowTools: [String]? = nil) {
        self.name = name
        self.cwd = cwd
        self.engine = engine
        self.permissionMode = permissionMode
        self.model = model
        self.systemPrompt = systemPrompt
        self.prompt = prompt
        self.allowTools = allowTools
    }

    /// The allow-list as rules, malformed entries dropped.
    public var allowRules: [ToolApproval.Rule] { (allowTools ?? []).compactMap(ToolApproval.Rule.parse) }

    /// The fields set, as one caption: "codex · acceptEdits · opus".
    public var summary: String {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty { parts.append((cwd as NSString).lastPathComponent) }
        if let engine, engine != "claude" { parts.append(engine) }
        if let permissionMode, !permissionMode.isEmpty {
            parts.append(SessionStart.permissionModes.first { $0.mode == permissionMode }?.label ?? permissionMode)
        }
        if let model, !model.isEmpty { parts.append(model) }
        if let systemPrompt, !systemPrompt.isEmpty { parts.append("system prompt") }
        if let allowTools, !allowTools.isEmpty { parts.append(allowTools.count == 1 ? "allows \(allowTools[0])" : "allows \(allowTools.count) tools") }
        return parts.isEmpty ? "nothing set — starts like a plain session" : parts.joined(separator: " · ")
    }
}

public enum SessionProfiles {
    /// Names match case-insensitively, so "Review" and "review" are one
    /// profile.
    public static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    /// Missing or unreadable file → no profiles (never an error: the
    /// pane shows an empty list and the first save creates the file).
    public static func load(from url: URL) -> [SessionProfile] {
        guard let data = try? Data(contentsOf: url),
              let profiles = try? JSONDecoder().decode([SessionProfile].self, from: data) else { return [] }
        return profiles
    }

    public static func save(_ profiles: [SessionProfile], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }

    /// Replaces the profile of that name in place, or appends it. Empty
    /// optional strings are stored as nil so "cleared" and "never set"
    /// read the same.
    public static func upsert(_ profile: SessionProfile, into profiles: [SessionProfile]) -> [SessionProfile] {
        var out = profiles
        let clean = SessionProfile(name: profile.name.trimmingCharacters(in: .whitespaces),
                                   cwd: blankToNil(profile.cwd), engine: blankToNil(profile.engine),
                                   permissionMode: blankToNil(profile.permissionMode), model: blankToNil(profile.model),
                                   systemPrompt: blankToNil(profile.systemPrompt), prompt: blankToNil(profile.prompt),
                                   allowTools: cleanList(profile.allowTools))
        if let i = out.firstIndex(where: { same($0.name, clean.name) }) {
            out[i] = clean
        } else {
            out.append(clean)
        }
        return out
    }

    public static func removing(_ name: String, from profiles: [SessionProfile]) -> [SessionProfile] {
        profiles.filter { !same($0.name, name) }
    }

    /// Entries trimmed, blanks and duplicates dropped; an empty list is nil.
    static func cleanList(_ list: [String]?) -> [String]? {
        var seen = Set<String>(), out: [String] = []
        for raw in list ?? [] {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").joined(separator: " ")
            if !t.isEmpty, seen.insert(t).inserted { out.append(t) }
        }
        return out.isEmpty ? nil : out
    }

    /// "Edit, Bash git" → ["Edit", "Bash git"]: the form the pane and
    /// `profile-set --allow` take.
    public static func parseAllowList(_ text: String) -> [String]? {
        cleanList(text.split(separator: ",").map(String.init))
    }

    private static func blankToNil(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
