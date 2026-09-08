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

    struct Option: Equatable, Identifiable {
        let label: String
        let description: String
        var id: String { label }
    }

    struct Question: Equatable, Identifiable {
        let id: String
        let question: String
        let header: String
        let multiSelect: Bool
        let options: [Option]
    }

    struct UserInput: Equatable {
        let requestId: String
        let questions: [Question]
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
                let questions = (a.payload["questions"]?.arrayValue ?? []).compactMap { q -> Question? in
                    guard let o = q.objectValue, let text = o["question"]?.stringValue else { return nil }
                    return Question(id: o["id"]?.stringValue ?? text, question: text,
                                    header: o["header"]?.stringValue ?? "",
                                    multiSelect: o["multiSelect"].map { $0 == .bool(true) } ?? false,
                                    options: (o["options"]?.arrayValue ?? []).compactMap { opt in
                                        guard let d = opt.objectValue, let label = d["label"]?.stringValue else { return nil }
                                        return Option(label: label, description: d["description"]?.stringValue ?? "")
                                    })
                }
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

    /// The `answers` request's text: every question answered by label(s)
    /// or a typed answer; nil until each has one.
    static func encodeAnswers(_ questions: [Question], picks: [String: Set<String>], custom: [String: String]) -> String? {
        var out: [String: String] = [:]
        for q in questions {
            let typed = custom[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let chosen = q.options.map(\.label).filter { picks[q.id]?.contains($0) == true }
            let parts = chosen + (typed.isEmpty ? [] : [typed])
            guard !parts.isEmpty else { return nil }
            out[q.question] = parts.joined(separator: SessionInput.Answers.separator)
        }
        return SessionInput.Answers.encode(out)
    }
}
