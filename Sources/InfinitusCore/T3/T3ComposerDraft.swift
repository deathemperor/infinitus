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

    public init(path: String, mime: String) {
        self.path = path
        self.mime = mime
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

    public init(text: String = "", attachments: [T3ComposerAttachmentRef] = []) {
        self.text = text
        self.attachments = attachments
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
        return running ? .queue : .send
    }

    /// `getComposerPromptLengthValidationMessage`'s sentence
    /// (`composerSubmission.ts:20-22`) with its `toLocaleString("en-US")`
    /// grouping and its singular/plural.
    public static func tooLongMessage(length: Int, maxLength: Int = SessionInput.maxMessageLength) -> String {
        let excess = length - maxLength
        let label = excess == 1 ? "character" : "characters"
        return "Prompt is \(grouped(excess)) \(label) over the \(grouped(maxLength))-character limit. Shorten or split it before sending."
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
