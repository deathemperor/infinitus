import Foundation
import InfinitusCore

/// An owned session's parked prompts (#151) never reach its transcript —
/// they arrive as control requests over stdin — so the feed the phone,
/// the browser page and the Mac window read gets them appended here, in
/// the item shapes those clients already render and answer (`.key`
/// "1"/"3"/N, `.approve`, `.answers` for every question at once). The stamp moves with them so a long-poll wakes.
enum OwnedFeed {
    static func augment(_ feed: SessionFeed, pending: [PendingRequest], limits: [LimitNote] = []) -> SessionFeed {
        guard !pending.isEmpty || !limits.isEmpty else { return feed }
        var items = feed.items
        // A limit lands before the prompt it paused; the prompt stays
        // last so `pendingPrompt` still finds it.
        for l in limits { items.append(SessionFeedItem(kind: .limit, text: l.text, at: l.receivedAt)) }
        for p in pending {
            if p.toolName == "AskUserQuestion", !p.questions.isEmpty {
                items.append(p.feedItem)
            } else {
                items.append(SessionFeedItem(kind: .permission, text: p.planMarkdown ?? p.description ?? p.inputJSON,
                                             at: p.receivedAt, toolName: p.toolName))
            }
        }
        return SessionFeed(pid: feed.pid, sessionId: feed.sessionId, cwd: feed.cwd, status: feed.status,
                           waiting: feed.waiting || !pending.isEmpty, items: items, name: feed.name,
                           stamp: decorate(feed.stamp ?? "", pending: pending, limits: limits),
                           timeline: feed.timeline?.appending(limits: limits).appending(pending: pending))
    }

    /// The disk stamp plus the parked prompts, so a prompt parking or
    /// being answered counts as a change for `waitForChange` — the same
    /// string `augment` hands the client back as the feed's stamp.
    static func decorate(_ stamp: String, pending: [PendingRequest], limits: [LimitNote] = []) -> String {
        var out = stamp
        if !pending.isEmpty { out += "+" + pending.map(\.requestId).joined(separator: ",") }
        if !limits.isEmpty { out += "+L" + limits.map(\.key).joined(separator: ",") }
        return out
    }
}
