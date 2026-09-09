import Foundation
import InfinitusCore

/// What the thread is waiting on (T3 clone C-3), read off the timeline:
/// the newest `approval.requested` or `user-input.requested` activity
/// nothing has resolved. An owned session's prompts leave the timeline
/// when answered and a transcript-derived permission only exists while
/// the record waits, so "present, unresolved" is "live".
enum T3Pending {
    struct Approval: Equatable {
        let requestId: String
        let toolName: String
        /// The rendered input — a Bash command, a file, else the JSON.
        let detail: String
        var rule: ToolApproval.Rule { .from(tool: toolName, input: detail) }
        /// The wire form of "allow for this session" (#79).
        var sessionApproval: String { ToolApproval.encode(tool: toolName, input: detail) }
    }

    /// The questions and their answer rules are Core's, one copy for the
    /// Mac and the phone (#422): `T3PendingAnswers`.
    typealias Option = T3PendingAnswers.Option
    typealias Question = T3PendingAnswers.Question

    struct UserInput: Equatable {
        let requestId: String
        let questions: [Question]
        /// Whole-prompt answers ride the control channel only a session
        /// the app runs has (`SessionInput` rejects them otherwise); a
        /// terminal's menu takes one key. Transcript-derived prompts carry
        /// the `perm:` prefix, an owned session's its control request id.
        var owned: Bool { !requestId.hasPrefix("perm:") }
    }

    /// What a card sends: every answer at once, or one menu key.
    enum Submission: Equatable {
        case answers(String)
        case key(String)
    }

    struct Live: Equatable {
        var approval: Approval?
        var userInput: UserInput?
        /// Ids of the requested activities the cards stand in for.
        var activityIds: Set<String> = []
    }

    static func derive(_ timeline: SessionTimeline) -> Live {
        let resolved = Set(timeline.activities.filter { $0.kind.hasSuffix(".resolved") }
            .compactMap { $0.payload["requestId"]?.stringValue })
        var live = Live()
        for a in timeline.activities.sorted(by: { $0.sequence < $1.sequence }) {
            guard let requestId = a.payload["requestId"]?.stringValue, !resolved.contains(requestId) else { continue }
            switch a.kind {
            case "approval.requested":
                let tool = a.payload["toolName"]?.stringValue ?? a.summary
                live.approval = Approval(requestId: requestId, toolName: tool,
                                         detail: renderedInput(tool: tool, a.payload["input"], summary: a.summary))
                live.activityIds.insert(a.id)
            case "user-input.requested":
                let questions = T3PendingAnswers.parse(a.payload["questions"]?.arrayValue ?? [])
                guard !questions.isEmpty else { continue }
                live.userInput = UserInput(requestId: requestId, questions: questions)
                live.activityIds.insert(a.id)
            default: continue
            }
        }
        return live
    }

    /// The feed shows a permission as its rendered input (`describeTool`);
    /// the rule for "allow for this session" reads a Bash command's first
    /// word from the same text.
    static func renderedInput(tool: String, _ input: JSONValue?, summary: String) -> String {
        guard let object = input?.objectValue, !object.isEmpty else { return summary }
        if tool == "Bash", let command = object["command"]?.stringValue { return command }
        if let path = object["file_path"]?.stringValue { return path }
        if let data = try? JSONEncoder().encode(input), let text = String(data: data, encoding: .utf8) { return text }
        return summary
    }
}
