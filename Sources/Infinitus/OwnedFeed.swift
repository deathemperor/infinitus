import Foundation
import InfinitusCore

/// An owned session's parked prompts (#151) never reach its transcript —
/// they arrive as control requests over stdin — so the feed the phone,
/// the browser page and the Mac window read gets them appended here, in
/// the item shapes those clients already render and answer (`.key`
/// "1"/"3"/N, `.approve`). The stamp moves with them so a long-poll wakes.
enum OwnedFeed {
    static func augment(_ feed: SessionFeed, pending: [PendingRequest]) -> SessionFeed {
        guard !pending.isEmpty else { return feed }
        var items = feed.items
        for p in pending {
            if p.toolName == "AskUserQuestion", let q = p.questions.first {
                items.append(SessionFeedItem(kind: .question, text: q.question, at: p.receivedAt, options: q.options))
            } else {
                items.append(SessionFeedItem(kind: .permission, text: p.description ?? p.inputJSON,
                                             at: p.receivedAt, toolName: p.toolName))
            }
        }
        return SessionFeed(pid: feed.pid, sessionId: feed.sessionId, cwd: feed.cwd, status: feed.status,
                           waiting: true, items: items, name: feed.name, stamp: decorate(feed.stamp ?? "", pending: pending),
                           timeline: feed.timeline?.appending(pending: pending))
    }

    /// The disk stamp plus the parked prompts, so a prompt parking or
    /// being answered counts as a change for `waitForChange` — the same
    /// string `augment` hands the client back as the feed's stamp.
    static func decorate(_ stamp: String, pending: [PendingRequest]) -> String {
        pending.isEmpty ? stamp : stamp + "+" + pending.map(\.requestId).joined(separator: ",")
    }
}
