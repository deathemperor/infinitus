import Foundation

/// One file staged on a draft. Upstream keeps the bytes
/// (`ComposerImageAttachment` / `ComposerFileAttachment`,
/// `composerDraftStore.ts`) because a browser tab has nowhere else to put
/// them; here the Mac has the file itself, so a draft remembers only the path
/// and its type — `SessionInput.deliver` reads and copies the bytes at send
/// (SessionInput.swift:300-321).
public struct T3ComposerAttachmentRef: Codable, Sendable, Equatable {
    public var path: String
    /// One of `SessionInput.allowedAttachmentMimes`.
    public var mime: String
    /// The file's size, stat'ed once when it was staged. Optional so a draft
    /// written before this field decodes, and because the row that shows it
    /// must not stat the file on every keystroke.
    public var bytes: Int?

    public init(path: String, mime: String, bytes: Int? = nil) {
        self.path = path
        self.mime = mime
        self.bytes = bytes
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// What one thread's composer holds while it is not being looked at —
/// upstream's per-thread draft (`composerDraftStore.ts`, keyed by its
/// `draftTarget`), keyed here by `T3Thread.id` (a live session's id) or
/// `"draft:<uuid>"` for a thread that has no session yet.
public struct T3ComposerDraft: Codable, Sendable, Equatable {
    public var text: String
    public var attachments: [T3ComposerAttachmentRef]
    /// Draft keys only: the project the row was in. Upstream's draft survives
    /// a reload because the draft record itself is persisted
    /// (`composerDraftStore.ts`); here the row is rebuilt at launch from this
    /// field, so a `draft:` entry that predates it (or one whose project is
    /// gone) is unreachable and gets pruned instead
    /// (`T3ComposerDrafts.restorable` / `prunable`). Optional so a draft
    /// written before this field decodes.
    public var projectId: String?

    public init(text: String = "", attachments: [T3ComposerAttachmentRef] = [], projectId: String? = nil) {
        self.text = text
        self.attachments = attachments
        self.projectId = projectId
    }

    /// Nothing worth keeping: no prompt and no staged file.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// Ours: T3 recalls prompts from the thread's own user messages, so
    /// `composerPromptHistory.ts` has nothing to cap (`:10-12`, "derived from
    /// the thread's user messages on every keypress, so there is no store to
    /// persist or sync"). B has no such reducer on the window side, so the
    /// window persists a flat list instead — capped, or it grows forever.
    public static let historyLimit = 50
}

/// The draft store's pure parts: what the window persists, what the recall
/// list becomes on a send, and whether the composer may send at all.
public enum T3ComposerDrafts {

    // MARK: - Persistence

    /// `UserDefaults` data → drafts. Unreadable or absent data is no drafts,
    /// never a crash: a defaults key written by an older build must not be
    /// able to take the window down.
    public static func load(from data: Data?) -> [String: T3ComposerDraft] {
        guard let data, !data.isEmpty,
              let drafts = try? JSONDecoder().decode([String: T3ComposerDraft].self, from: data)
        else { return [:] }
        return drafts.filter { !$0.value.isEmpty }
    }

    /// Drafts → `UserDefaults` data, empty ones dropped (a cleared composer is
    /// not state to restore, and its key would otherwise live forever).
    public static func save(_ drafts: [String: T3ComposerDraft]) -> Data {
        (try? JSONEncoder().encode(drafts.filter { !$0.value.isEmpty })) ?? Data()
    }

    /// The persisted `draft:` entries a relaunch can put a sidebar row back
    /// for: the ones that still name a project this Mac has
    /// (`draftId -> projectId`). Everything else — an entry written before
    /// `projectId` existed, or one whose project is gone — has no row to
    /// reach it and is `prunable` below.
    public static func restorable(_ drafts: [String: T3ComposerDraft],
                                  projects: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for (id, draft) in drafts where T3WorkspaceState.isDraft(id) {
            guard let projectId = draft.projectId, projects.contains(projectId) else { continue }
            out[id] = projectId
        }
        return out
    }

    /// Keys `workspace.drafts` should stop carrying, decided after an apply:
    /// a draft key with no row left (discarded, started, or never restorable)
    /// and a thread key whose session is not in the fleet and whose entry is
    /// empty (no text, no staged files). Anything with content stays: a
    /// live thread's facts can lag its record for a tick, and that tick must
    /// not throw away what a returning session would want back. Without this
    /// the defaults key grows with every thread this Mac ever ran.
    public static func prunable(_ drafts: [String: T3ComposerDraft],
                                liveDraftIds: Set<String>,
                                liveThreadIds: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for (id, draft) in drafts {
            if T3WorkspaceState.isDraft(id) {
                if !liveDraftIds.contains(id) { out.insert(id) }
            } else if !liveThreadIds.contains(id), draft.isEmpty {
                out.insert(id)
            }
        }
        return out
    }

    // MARK: - Prompt recall

    /// The sent prompt at the front, newest first, one entry per distinct
    /// prompt, capped. Upstream collapses only *consecutive* duplicates
    /// (`buildComposerPromptHistoryEntries`, `composerPromptHistory.ts:163-181`,
    /// shell `HISTCONTROL=ignoredups`); a flat cross-thread list would keep
    /// re-offering an older copy of the same prompt, so this dedups outright.
    /// Blank prompts are not history (`recallableComposerPrompt`, `:141-159`).
    public static func pushHistory(_ history: [String], prompt: String,
                                  limit: Int = T3ComposerDraft.historyLimit) -> [String] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        return Array(([trimmed] + history.filter { $0 != trimmed }).prefix(limit))
    }

    // MARK: - The send verdict

    /// What pressing Send (or ⏎) does with the prompt as typed.
    public enum SendVerdict: Sendable, Equatable {
        /// Straight through: the session is not working.
        case send
        /// The session is working — Claude Code takes the message into its own
        /// queue and answers it after the running turn.
        case queue
        /// Nothing typed. Upstream's `hasSendableContent`
        /// (`ComposerPrimaryActions.tsx:237`) also counts staged attachments,
        /// which this text-only verdict cannot see — the caller adds them.
        case empty
        /// The trimmed prompt's length, over the cap.
        case tooLong(Int)
        /// A control scalar other than `\n` — the wire would answer "invalid
        /// message" (`SessionInput.isValidMessage`), and by then the composer
        /// would have cleared the draft.
        case invalid
    }

    /// `submitComposerDraft`'s two gates (`composerSubmission.ts:33-49`) plus
    /// the running check `ChatComposer.tsx:5572` makes with `phase ===
    /// "running"`: the prompt is trimmed first (`:13`), the length rejection
    /// wins over everything a send could do, and a blank prompt is a no-op
    /// rather than a queued nothing.
    public static func canSend(text: String, running: Bool,
                               maxLength: Int = SessionInput.maxMessageLength) -> SendVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.count > maxLength { return .tooLong(trimmed.count) }
        if hasUnsupportedControlCharacters(trimmed) { return .invalid }
        return running ? .queue : .send
    }

    /// `SessionInput.isValidMessage`'s scalar loop (SessionInput.swift:150-153),
    /// ported rather than called: that check lives behind `#if !os(iOS)`, and
    /// this file builds for the phone too. A stray Tab or CR — pasted from a
    /// terminal, or the `\r\n` of a Windows file — must never reach a real
    /// terminal, so the wire refuses it; the composer has to refuse it first or
    /// it clears the draft (and loses the staged attachments) for a send that
    /// comes back rejected.
    static func hasUnsupportedControlCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar != "\n" {
            if scalar.properties.generalCategory == .control { return true }
        }
        return false
    }

    /// Ours. Upstream has no such message: a browser textarea cannot produce a
    /// raw control character, so `composerSubmission.ts` validates length and
    /// nothing else.
    public static let invalidMessage = "Message contains unsupported control characters"

    /// `getComposerPromptLengthValidationMessage`'s sentence
    /// (`composerSubmission.ts:20-22`) with its `toLocaleString("en-US")`
    /// grouping and its singular/plural.
    public static func tooLongMessage(length: Int, maxLength: Int = SessionInput.maxMessageLength) -> String {
        let excess = length - maxLength
        let label = excess == 1 ? "character" : "characters"
        return "Prompt is \(grouped(excess)) \(label) over the \(grouped(maxLength))-character limit. Shorten or split it before sending."
    }

    // MARK: - Prompt recall, stepped

    /// `stepComposerPromptHistory` (`composerPromptHistory.ts:183-211`) over a
    /// flat newest-first list: nil when the key should fall through to normal
    /// caret movement, else the new position (nil = not browsing any more) and
    /// the text to put in the field. `direction` is −1 backward (older), +1
    /// forward (newer).
    ///
    /// Browsing is identified the way upstream does it (`:198`): the position
    /// counts only while the field still holds what was recalled into it, so an
    /// edit ends browsing by itself and there is no "edited" flag to keep in
    /// sync.
    public static func stepHistory(history: [String], index: Int?, current: String,
                                   direction: Int) -> (index: Int?, text: String)? {
        let active = index.flatMap { $0 >= 0 && $0 < history.count && history[$0] == current ? $0 : nil }
        if direction < 0 {
            // Backward starts only from an empty composer (`:200`).
            guard active != nil || current.isEmpty else { return nil }
            let next = (active ?? -1) + 1
            guard next < history.count else { return nil }   // stops at the oldest
            return (next, history[next])
        }
        guard let active else { return nil }
        let next = active - 1
        // "Forward past the newest entry empties the composer and ends
        // browsing" (`:186-187`, `:209`) — it does not restore a stashed
        // prompt; upstream stashes only through ⌘S, which B does not port.
        guard next >= 0 else { return (nil, "") }
        return (next, history[next])
    }

    // MARK: - The queue badge

    /// A user message drains the oldest queued send whose text it carries. The
    /// comparison is exact on the delivered body, never `contains`: a later
    /// prompt that quotes this one is a different send, and the badge would
    /// clear on the wrong message.
    public static func drainQueue(queued: [T3QueuedSend],
                                  userMessages: [SessionTimeline.Message]) -> [T3QueuedSend] {
        guard !queued.isEmpty else { return queued }
        var remaining = queued
        for message in userMessages where message.role == .user {
            let body = deliveredBody(message.text)
            guard let index = remaining.firstIndex(where: {
                body == $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    && message.createdAt >= $0.sentAt.addingTimeInterval(-stampSlack)
            }) else { continue }
            remaining.remove(at: index)   // oldest first: two identical prompts drain in order
        }
        return remaining
    }

    /// A transcript entry may be stamped to the whole second — `parseStamp`
    /// accepts `2026-09-05T04:02:47Z` as readily as `…47.463Z`
    /// (TokenRates.swift:196-199) — so a message written moments after a send
    /// can carry a `createdAt` up to a second before it. Without this the badge
    /// would sit on a delivered send until the turn ended.
    static let stampSlack: TimeInterval = 1

    /// The prompt as the transcript kept it: `SessionInput.deliver` appends
    /// `\n\n[attached: …]` for staged files (SessionInput.swift:321) and the
    /// timeline keeps that line (`SessionTimelineBuilder.visitUser`), while the
    /// phone preface is already stripped by the reader
    /// (`SessionFeedReader`, SessionFeed.swift:682-684).
    static func deliveredBody(_ text: String) -> String {
        var body = text
        if body.hasSuffix("]"), let line = body.range(of: "\n\n[attached: ", options: .backwards) {
            body = String(body[..<line.lowerBound])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Number.toLocaleString("en-US")`: thousands separated by commas
    /// whatever the Mac's own locale is.
    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// One message the composer sent while a turn was running and has not yet seen
/// come back as a user message — the queue badge's unit. Ours: upstream sends
/// into the running turn and lets the server order the result, so it has no
/// queue and no component for one.
public struct T3QueuedSend: Sendable, Equatable {
    public var text: String
    public var sentAt: Date

    public init(text: String, sentAt: Date) {
        self.text = text
        self.sentAt = sentAt
    }
}
