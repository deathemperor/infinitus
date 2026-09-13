import Foundation

/// The permission modes a session can run in and be moved to, as Claude
/// Code spells them, with the labels the pickers show.
public enum SessionModes {
    /// The modes a session can start in. The default (ask for every
    /// tool) is "no flag", so it is not in this list.
    public static let permissionModes: [(mode: String, label: String)] = [
        ("manual", "Ask every time"),
        ("acceptEdits", "Auto-accept edits"),
        ("auto", "Auto"),
        ("bypassPermissions", "Full access"),
    ]
    /// The modes a running session can be moved to (#163 phase 2) through
    /// the plugin's PreToolUse hook: `supervised` clears the hook mode.
    /// `auto` is Claude Code's own classifier and has no hook equivalent.
    public static let hookModes: [(mode: String, label: String)] = [
        ("supervised", "Supervised"),
        ("acceptEdits", "Auto-accept edits"),
        ("bypassPermissions", "Full access"),
    ]
    /// How much a mode lets through, for "a start mode is a floor": the
    /// hook can only widen what Claude Code would otherwise ask about.
    public static func modeRank(_ mode: String?) -> Int {
        switch mode {
        case "bypassPermissions": return 2
        case "acceptEdits", "auto": return 1
        default: return 0
        }
    }
}

/// How a session was started by Infinitus (#163 / #165): the profile it
/// was born from, the permission mode it runs in, the session it
/// resumed. Claude Code's own session record carries none of this, so
/// the Mac remembers it per pid from the moment a started session
/// registers, and the snapshot carries it to the phone.
public struct SessionBirth: Codable, Sendable, Equatable {
    public let profile: String?
    /// One of `SessionStart.permissionModes`; nil = supervised.
    public let permissionMode: String?
    /// The past session id this one resumed, when it did.
    public let resumedFrom: String?
    /// The resume was a fork (#167 phase 3): a new id from that transcript.
    public let forked: Bool?
    /// The mode the phone moved the running session to (#163 phase 2),
    /// answered by the plugin's PreToolUse hook; nil = as started.
    public let hookMode: String?
    /// Claude Code's session id, once the roster showed it. The record is
    /// keyed by pid for the row, but a pid comes back after a reboot on
    /// some other process — anything that grants (the hook mode) is
    /// reseeded only when the live session's id is this one.
    public let sessionId: String?
    /// Infinitus owns the process (#151): no terminal, stdin is the
    /// input. The roster can't tell (its record says "interactive",
    /// entrypoint "sdk-cli" like any SDK host), so the birth remembers.
    public let headless: Bool?

    public init(profile: String? = nil, permissionMode: String? = nil, resumedFrom: String? = nil,
                hookMode: String? = nil, sessionId: String? = nil, forked: Bool? = nil, headless: Bool? = nil) {
        self.profile = profile
        self.permissionMode = permissionMode
        self.resumedFrom = resumedFrom
        self.hookMode = hookMode
        self.sessionId = sessionId
        self.forked = forked
        self.headless = headless
    }

    /// The same birth moved to `mode` (nil = back to how it started).
    public func moved(to mode: String?) -> SessionBirth {
        SessionBirth(profile: profile, permissionMode: permissionMode, resumedFrom: resumedFrom,
                     hookMode: mode, sessionId: sessionId, forked: forked, headless: headless)
    }

    /// The same birth pinned to the session id the roster showed.
    public func identified(as sessionId: String) -> SessionBirth {
        SessionBirth(profile: profile, permissionMode: permissionMode, resumedFrom: resumedFrom,
                     hookMode: hookMode, sessionId: sessionId, forked: forked, headless: headless)
    }

    /// The mode in force: the hook's when set, else the start mode.
    public var effectiveMode: String? { hookMode ?? permissionMode }
    /// The start mode as the pickers spell it, nil when supervised.
    public var modeLabelForStart: String? {
        permissionMode.flatMap { m in SessionModes.permissionModes.first { $0.mode == m }?.label }
    }

    /// The mode as the pickers spell it ("Full access"), nil when supervised.
    public var modeLabel: String? {
        effectiveMode.flatMap { m in SessionModes.permissionModes.first { $0.mode == m }?.label }
    }

    /// What the session row shows beside the name: "Review · Full access",
    /// "resumed", "Ask every time · headless", or nil when there is
    /// nothing worth a chip.
    public var chip: String? {
        var parts: [String] = []
        if let profile { parts.append(profile) }
        if let modeLabel { parts.append(modeLabel) }
        if parts.isEmpty, resumedFrom != nil { parts.append(forked == true ? "forked" : "resumed") }
        if headless == true { parts.append("headless") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Full access is the one mode worth a warning color.
    public var isUnrestricted: Bool { effectiveMode == "bypassPermissions" }
}

public enum SessionBirths {
    /// Missing or unreadable → empty (never an error).
    public static func load(from url: URL) -> [Int: SessionBirth] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: SessionBirth].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    /// Keys are strings on disk (JSON objects), ints in memory.
    public static func save(_ births: [Int: SessionBirth], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = Dictionary(uniqueKeysWithValues: births.map { (String($0.key), $0.value) })
        try encoder.encode(raw).write(to: url, options: .atomic)
    }

    /// Only pids still in the roster keep a record — a pid is reused by
    /// the OS eventually, and a dead session's chip must not outlive it.
    public static func pruned(_ births: [Int: SessionBirth], alive: Set<Int>) -> [Int: SessionBirth] {
        births.filter { alive.contains($0.key) }
    }
}
