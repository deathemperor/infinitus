import Foundation

/// The open prompts of a session, derived from its activities in one pass
/// (t3code `packages/client-runtime/src/pendingRequests.ts`, upstream
/// e63ddb48): a `resolved` for an id closes it for good, so a replayed or
/// late `requested` — another client answered — never reopens a sheet.
/// Shared by the Mac popup, the phone and the browser page.
public struct PendingRequests: Sendable, Equatable {
    public struct PendingApproval: Sendable, Equatable {
        public let requestId: String
        public let toolName: String
        public let requestType: String
        public let summary: String
        public let input: JSONValue
        public let createdAt: Date
    }
    public struct PendingUserInput: Sendable, Equatable {
        public let requestId: String
        public let questions: [JSONValue]
        public let createdAt: Date
    }
    public let approvals: [PendingApproval]
    public let userInputs: [PendingUserInput]

    public static func derive(_ activities: [SessionTimeline.Activity]) -> PendingRequests {
        var closed: Set<String> = []
        var approvals: [String: PendingApproval] = [:]
        var inputs: [String: PendingUserInput] = [:]
        var order: [String] = []
        for a in activities {
            guard let id = a.payload["requestId"]?.stringValue else { continue }
            switch a.kind {
            case "approval.resolved", "user-input.resolved":
                closed.insert(id)
                approvals[id] = nil
                inputs[id] = nil
            case "approval.requested":
                guard !closed.contains(id), approvals[id] == nil else { continue }
                approvals[id] = PendingApproval(requestId: id, toolName: a.payload["toolName"]?.stringValue ?? "",
                                                requestType: a.payload["requestType"]?.stringValue ?? "dynamic_tool_call",
                                                summary: a.summary, input: a.payload["input"] ?? .object([:]),
                                                createdAt: a.createdAt)
                order.append(id)
            case "user-input.requested":
                guard !closed.contains(id), inputs[id] == nil else { continue }
                let questions = (a.payload["questions"]?.arrayValue ?? []).compactMap(validQuestion)
                guard !questions.isEmpty else { continue }
                inputs[id] = PendingUserInput(requestId: id, questions: questions, createdAt: a.createdAt)
                order.append(id)
            default:
                continue
            }
        }
        return PendingRequests(approvals: order.compactMap { approvals[$0] },
                               userInputs: order.compactMap { inputs[$0] })
    }

    /// A question with at least one well-formed option; malformed options
    /// are filtered, not fatal (T3 rule).
    static func validQuestion(_ q: JSONValue) -> JSONValue? {
        guard var obj = q.objectValue else { return nil }
        let options = (obj["options"]?.arrayValue ?? []).filter { $0.objectValue?["label"]?.stringValue != nil }
        guard !options.isEmpty else { return nil }
        obj["options"] = .array(options)
        return .object(obj)
    }
}
