import Foundation

/// `push` on the control socket (#269 G): Infinitus desktop tells the Mac
/// a thread changed phase, and the Mac pushes it the way it pushes its
/// own news — Notification Center, the phone, Slack/Telegram — under the
/// same gating. Title and phase only: the payload carries no prompt text,
/// and nothing here reads more than these fields.
public struct ThreadPhasePush: Equatable, Sendable {
    public let threadId: String
    public let title: String
    public let phase: String
    public let detail: String?

    /// `{kind: "thread.phase", threadId, title, phase, detail?}`; nil for
    /// any other shape, so a stray payload is refused, never pushed.
    public static func parse(_ json: String) -> ThreadPhasePush? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              object["kind"] as? String == "thread.phase",
              let threadId = object["threadId"] as? String, !threadId.isEmpty,
              let phase = object["phase"] as? String, !phase.isEmpty else { return nil }
        let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (object["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ThreadPhasePush(threadId: threadId, title: title.isEmpty ? "a thread" : title,
                               phase: phase, detail: (detail?.isEmpty ?? true) ? nil : detail)
    }

    /// One line, the way the Mac's own pushes read: "<title> — waiting
    /// for approval". A phase this build does not know is spelled out
    /// rather than dropped.
    public var line: String {
        let what: String
        switch phase {
        case "waiting_for_approval": what = "waiting for approval"
        case "waiting_for_input": what = "waiting for input"
        case "completed": what = "finished"
        case "failed": what = "failed"
        default: what = phase.replacingOccurrences(of: "_", with: " ")
        }
        return detail.map { "\(title) — \(what): \($0)" } ?? "\(title) — \(what)"
    }
}
