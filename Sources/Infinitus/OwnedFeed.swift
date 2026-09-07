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
        let mark = pending.map(\.requestId).joined(separator: ",")
        return SessionFeed(pid: feed.pid, sessionId: feed.sessionId, cwd: feed.cwd, status: feed.status,
                           waiting: true, items: items, name: feed.name, stamp: (feed.stamp ?? "") + "+" + mark)
    }

    /// The transcript stamp a client hands back, without our suffix.
    static func transcriptStamp(_ since: String?) -> String? {
        guard let since, let plus = since.firstIndex(of: "+") else { return since }
        return String(since[..<plus])
    }

    /// A parked prompt changes nothing on disk, so an owned session's
    /// long-poll is capped: the prompt shows within this many seconds.
    static let ownedWait: TimeInterval = 2
}
