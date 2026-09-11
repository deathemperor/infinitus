import Foundation

// MARK: - cswap settings input validation

/// Client-side validation for the spec-driven settings pane. The CLI's
/// `config set` re-validates from the same SETTING_SPECS table, so this can
/// only ever be too lenient, never the authority.
public enum SettingDraft: Equatable, Sendable {
    case valid(String)   // pass to `cswap config set`
    case unset           // pass to `cswap config unset`
    case invalid(String) // reason to show inline

    public static func validate(_ input: String, for entry: SettingEntry) -> SettingDraft {
        let text = input.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .unset }
        switch entry.kind {
        case "bool":
            return ["true", "false"].contains(text.lowercased())
                ? .valid(text.lowercased())
                : .invalid("true or false")
        case "int":
            guard let n = Int(text) else { return .invalid("a whole number") }
            return bounded(Double(n), entry, text)
        case "float":
            guard let n = Double(text) else { return .invalid("a number") }
            return bounded(n, entry, text)
        case "choice":
            let choices = entry.choices ?? []
            return choices.contains(text)
                ? .valid(text)
                : .invalid("one of: \(choices.joined(separator: ", "))")
        default:
            return .valid(text)
        }
    }

    private static func bounded(_ n: Double, _ entry: SettingEntry, _ text: String) -> SettingDraft {
        if let lo = entry.lo, n < lo { return .invalid("between \(fmt(lo)) and \(fmt(entry.hi))") }
        if let hi = entry.hi, n > hi { return .invalid("between \(fmt(entry.lo)) and \(fmt(hi))") }
        return .valid(text)
    }

    private static func fmt(_ v: Double?) -> String {
        guard let v else { return "?" }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }
}

// MARK: - Claude Code's own settings (the resume-reliability panel)

/// Reads and writes the two Claude Code keys the resume flow depends on
/// (`autoContinueAtUsageLimit`, `crossSessionInbound`) — backlog item 6
/// addendum. Managed (org) settings override the user file and cannot be
/// written from here; the panel must show the EFFECTIVE value or its write
/// button would claim success while changing nothing.
public struct ClaudeCodeConfig: Sendable {
    public enum Source: Sendable, Equatable { case user, managed }
    public struct Effective: Sendable, Equatable {
        public let value: JSONValue
        public let source: Source
    }

    public let userSettingsURL: URL
    public let managedSettingsURL: URL

    public init(userSettingsURL: URL, managedSettingsURL: URL) {
        self.userSettingsURL = userSettingsURL
        self.managedSettingsURL = managedSettingsURL
    }

    public static func standard(home: String = NSHomeDirectory()) -> ClaudeCodeConfig {
        ClaudeCodeConfig(
            userSettingsURL: URL(fileURLWithPath: "\(home)/.claude/settings.json"),
            managedSettingsURL: URL(
                fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
        )
    }

    public func effectiveValue(_ key: String) throws -> Effective? {
        if let v = try read(managedSettingsURL)?[key] {
            return Effective(value: v, source: .managed)
        }
        if let v = try read(userSettingsURL)?[key] {
            return Effective(value: v, source: .user)
        }
        return nil
    }

    /// Sets one top-level key in the user file, preserving every other key
    /// byte-for-byte at the JSON level, with a timestamped backup first.
    public func writeUserValue(_ key: String, _ value: JSONValue) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: userSettingsURL),
           let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = userSettingsURL.appendingPathExtension("bak-\(stamp)")
            try data.write(to: backup)
        }
        object[key] = value.anyValue
        let out = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: userSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try out.write(to: userSettingsURL, options: .atomic)
    }

    private func read(_ url: URL) throws -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}

extension JSONValue {
    /// Foundation representation for JSONSerialization writes.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() ? Int(n) : n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }
}
