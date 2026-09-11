import Foundation

/// A Claude Code hook payload, as the plugin's hooks hand it to
/// `infinitusctl event` (#79) — only the fields the app acts on.
public struct HookEvent: Equatable, Sendable {
    public let name: String
    public let sessionId: String?
    public let cwd: String?
    public let message: String?
    public let notificationType: String?
    /// PreToolUse: the tool, and for Bash its command.
    public let toolName: String?
    public let toolCommand: String?
    /// UserPromptSubmit: the prompt's text — a checkpoint's subject (#167).
    public let prompt: String?

    public init(name: String, sessionId: String? = nil, cwd: String? = nil,
                message: String? = nil, notificationType: String? = nil,
                toolName: String? = nil, toolCommand: String? = nil, prompt: String? = nil) {
        self.name = name
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
        self.notificationType = notificationType
        self.toolName = toolName
        self.toolCommand = toolCommand
        self.prompt = prompt
    }

    public static func parse(_ json: String) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let name = object["hook_event_name"] as? String else { return nil }
        return HookEvent(name: name,
                         sessionId: object["session_id"] as? String,
                         cwd: object["cwd"] as? String,
                         message: object["message"] as? String,
                         notificationType: object["notification_type"] as? String,
                         toolName: object["tool_name"] as? String,
                         toolCommand: (object["tool_input"] as? [String: Any])?["command"] as? String,
                         prompt: object["prompt"] as? String)
    }

    public var repo: String {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a session"
    }

    /// The notification types a human must act on. Not `idle_prompt`:
    /// it fires a minute after every finished turn, which is the
    /// "sessions done" trigger's job, not a prompt.
    public static let humanTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
        "agent_needs_input",
    ]

    public var needsHuman: Bool {
        name == "Notification" && notificationType.map(Self.humanTypes.contains) == true
    }

    /// The poll path's wording, with the prompt's own text when there is one.
    public var pushLine: String? {
        guard needsHuman else { return nil }
        let detail = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "waiting on you — \(repo) needs an answer"
                              : "waiting on you — \(repo): \(detail)"
    }

    public var logLine: String {
        var line = "\(name) — \(repo)"
        if let type = notificationType { line += " (\(type))" }
        if let message, !message.isEmpty { line += ": \(message)" }
        return line
    }
}
