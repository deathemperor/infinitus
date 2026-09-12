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
    /// Stop: whether a stop hook (not this one) is what ended the turn —
    /// then the turn isn't really over, so no idle hint (#79).
    public let stopHookActive: Bool?
    /// SessionEnd's own field; unused beyond `statusHint` today.
    public let reason: String?
    /// StopFailure: the error kind (`rate_limit`, `overloaded`, …) — the
    /// only part of the payload ever logged. `errorDetails` is the API's
    /// own text and, like `last_assistant_message`, is never parsed into
    /// anything the app logs (#79).
    public let error: String?
    public let errorDetails: String?

    public init(name: String, sessionId: String? = nil, cwd: String? = nil,
                message: String? = nil, notificationType: String? = nil,
                toolName: String? = nil, toolCommand: String? = nil, prompt: String? = nil,
                stopHookActive: Bool? = nil, reason: String? = nil,
                error: String? = nil, errorDetails: String? = nil) {
        self.name = name
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
        self.notificationType = notificationType
        self.toolName = toolName
        self.toolCommand = toolCommand
        self.prompt = prompt
        self.stopHookActive = stopHookActive
        self.reason = reason
        self.error = error
        self.errorDetails = errorDetails
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
                         prompt: object["prompt"] as? String,
                         stopHookActive: object["stop_hook_active"] as? Bool,
                         reason: object["reason"] as? String,
                         error: object["error"] as? String,
                         errorDetails: object["error_details"] as? String)
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

    /// The status the hook lets the app assume ahead of the record (#79).
    /// nil: nothing to assume (a `Stop` fired by a stop hook, or any
    /// other event).
    public func statusHint(now: Date = Date()) -> SessionStatusHints.Hint? {
        switch name {
        case "Stop": return stopHookActive == true ? nil : .init(status: "idle", at: now)
        case "StopFailure": return .init(status: "idle", at: now)
        case "SessionEnd": return .init(status: nil, at: now)
        default: return nil
        }
    }

    public var logLine: String {
        var line = "\(name) — \(repo)"
        if let type = notificationType ?? (name == "StopFailure" ? error : nil) { line += " (\(type))" }
        if let message, !message.isEmpty { line += ": \(message)" }
        return line
    }
}
