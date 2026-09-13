import Foundation

/// A session's parked prompt: a tool that needs a permission verdict, or
/// `AskUserQuestion` waiting for its answers. Folded into a timeline by
/// `SessionTimeline.appending(pending:)` — `TimelineCache`/`T3TimelineEntry`
/// take the list as a closure a caller feeds; the Mac's own producer (a
/// headless owned session) is gone, so today it's always empty here, kept
/// for the phone's `QuestionsPrompt` and the wire shape.
public struct PendingRequest: Sendable, Equatable, Codable {
    public struct Question: Sendable, Equatable, Codable {
        public let question: String
        public let header: String
        public let options: [String]
        public let multiSelect: Bool
    }
    public let requestId: String
    public let toolName: String
    public let toolUseId: String?
    public let description: String?
    /// The tool's input, as the JSON text it arrived in — echoed back
    /// verbatim as `updatedInput` on allow.
    public let inputJSON: String
    /// `permission_suggestions` as JSON text, when Claude Code offered a
    /// rule that would stop asking ("allow for this session").
    public let suggestionsJSON: String?
    public let questions: [Question]
    public let receivedAt: Date

    /// `ExitPlanMode`'s proposed plan (its `plan` input), so the card
    /// shows the plan itself rather than its JSON; nil for other tools.
    public var planMarkdown: String? {
        guard toolName == "ExitPlanMode",
              let obj = try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any],
              let plan = obj["plan"] as? String, !plan.isEmpty else { return nil }
        return plan
    }
}
