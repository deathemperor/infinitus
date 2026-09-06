import Foundation

/// "Allow for this session" from the phone (#79): a rule the Mac keeps
/// for one Claude Code session and answers the plugin's PreToolUse hook
/// with. Session-scoped and in memory only — a relaunch forgets them,
/// the way Claude Code's own "don't ask again this session" does.
public enum ToolApproval {
    public struct Rule: Equatable, Sendable, Codable {
        public let tool: String
        /// Bash only: the command's first word ("git", "swift"); nil
        /// means any input of that tool.
        public let prefix: String?

        public init(tool: String, prefix: String? = nil) {
            self.tool = tool
            self.prefix = prefix
        }

        /// What the phone's card shows for the prompt: the tool and the
        /// rendered input. Bash narrows to the command's first word so
        /// "allow git" never allows "rm".
        public static func from(tool: String, input: String) -> Rule {
            guard tool == "Bash" else { return Rule(tool: tool) }
            return Rule(tool: tool, prefix: firstWord(input))
        }

        public func matches(tool: String, command: String?) -> Bool {
            guard self.tool == tool else { return false }
            guard let prefix else { return true }
            return Rule.firstWord(command ?? "") == prefix
        }

        static func firstWord(_ command: String) -> String? {
            // Skip leading env assignments and `cd x &&` so the verb is the tool.
            var words = command.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
            while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
            return words.first
        }

        public var label: String { prefix.map { "\(tool) \($0) …" } ?? tool }
    }

    /// Wire form of the phone's "allow for this session": the tool on the
    /// first line, the rendered input after it.
    public static func encode(tool: String, input: String) -> String { tool + "\n" + input }
    public static func decode(_ text: String) -> Rule? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tool = parts.first, !tool.isEmpty else { return nil }
        return Rule.from(tool: String(tool), input: parts.count > 1 ? String(parts[1]) : "")
    }

    /// The hook's answer, in Claude Code's PreToolUse output shape.
    public static let allowOutput =
        #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Allowed from the phone for this session (Infinitus)"}}"#
}

/// The rules, by Claude Code session id. Lock-protected: the mirror
/// server records them off the main thread, the control socket reads.
public final class ToolApprovals: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [String: [ToolApproval.Rule]] = [:]
    /// The phone's mid-session mode per session id (#163 phase 2):
    /// "acceptEdits" allows the editing tools, "bypassPermissions" every
    /// tool; nil = supervised, the rules alone decide.
    private var modes: [String: String] = [:]
    /// What "Auto-accept edits" lets through, Claude Code's own set.
    public static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public init() {}

    public func setMode(_ mode: String?, sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        modes[sessionId] = mode
    }

    public func mode(for sessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return modes[sessionId]
    }

    /// Why a tool is allowed: the session's mode, or a rule from the
    /// phone — nil when Claude Code should ask as usual.
    public func reason(sessionId: String, tool: String, command: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch modes[sessionId] {
        case "bypassPermissions": return "the session's Full access mode"
        case "acceptEdits" where ToolApprovals.editTools.contains(tool): return "the session's Auto-accept edits mode"
        default: break
        }
        return (rules[sessionId] ?? []).contains { $0.matches(tool: tool, command: command) } ? "the phone's session rule" : nil
    }

    public func add(_ rule: ToolApproval.Rule, sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        var list = rules[sessionId] ?? []
        if !list.contains(rule) { list.append(rule) }
        rules[sessionId] = list
    }

    public func allows(sessionId: String, tool: String, command: String?) -> Bool {
        reason(sessionId: sessionId, tool: tool, command: command) != nil
    }

    public func rules(for sessionId: String) -> [ToolApproval.Rule] {
        lock.lock(); defer { lock.unlock() }
        return rules[sessionId] ?? []
    }
}
