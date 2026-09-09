import XCTest
@testable import InfinitusCore

/// The composer's Core seams (Task 13): the per-thread draft store the window
/// persists, the prompt history it recalls from, and the send verdict the
/// button and the queue badge are both gated on.
final class T3ComposerDraftTests: XCTestCase {

    // MARK: - load / save

    func testSaveLoadRoundTrip() {
        let drafts: [String: T3ComposerDraft] = [
            "t3fix-hi": T3ComposerDraft(text: "half a sentence", attachments: [
                T3ComposerAttachmentRef(path: "/tmp/shot.png", mime: "image/png"),
            ]),
            "draft:9E0B": T3ComposerDraft(text: "another thread"),
        ]
        XCTAssertEqual(T3ComposerDrafts.load(from: T3ComposerDrafts.save(drafts)), drafts)
    }

    func testLoadWithoutDataIsEmpty() {
        XCTAssertEqual(T3ComposerDrafts.load(from: nil), [:])
    }

    func testLoadOfUnreadableDataIsEmpty() {
        XCTAssertEqual(T3ComposerDrafts.load(from: Data("not json".utf8)), [:])
    }

    /// A thread whose draft was emptied leaves no entry behind: the window
    /// writes back what the composer holds, and an empty draft is not state
    /// worth restoring (nor a key worth growing the defaults with).
    func testSaveDropsEmptyDrafts() {
        let saved = T3ComposerDrafts.save(["a": T3ComposerDraft(text: "   "), "b": T3ComposerDraft(text: "kept")])
        XCTAssertEqual(T3ComposerDrafts.load(from: saved), ["b": T3ComposerDraft(text: "kept")])
    }

    // MARK: - pushHistory

    func testPushHistoryPutsTheNewestFirst() {
        var history = T3ComposerDrafts.pushHistory([], prompt: "first")
        history = T3ComposerDrafts.pushHistory(history, prompt: "second")
        XCTAssertEqual(history, ["second", "first"])
    }

    func testPushHistoryDedups() {
        let history = T3ComposerDrafts.pushHistory(["b", "a"], prompt: "a")
        XCTAssertEqual(history, ["a", "b"])
    }

    func testPushHistoryTrimsAndIgnoresBlanks() {
        XCTAssertEqual(T3ComposerDrafts.pushHistory([], prompt: "  spaced  "), ["spaced"])
        XCTAssertEqual(T3ComposerDrafts.pushHistory(["kept"], prompt: "   "), ["kept"])
        XCTAssertEqual(T3ComposerDrafts.pushHistory(["kept"], prompt: "\n"), ["kept"])
    }

    func testPushHistoryCaps() {
        var history: [String] = []
        for i in 0..<(T3ComposerDraft.historyLimit + 10) {
            history = T3ComposerDrafts.pushHistory(history, prompt: "p\(i)")
        }
        XCTAssertEqual(history.count, T3ComposerDraft.historyLimit)
        XCTAssertEqual(history.first, "p\(T3ComposerDraft.historyLimit + 9)")
        XCTAssertEqual(history.last, "p10")
    }

    func testPushHistoryHonoursACallerLimit() {
        XCTAssertEqual(T3ComposerDrafts.pushHistory(["b", "a"], prompt: "c", limit: 2), ["c", "b"])
    }

    // MARK: - canSend

    func testCanSendOnBlankTextIsEmpty() {
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "  ", running: false), .empty)
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "", running: false), .empty)
        // Blank beats running: there is nothing to queue either.
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "\n ", running: true), .empty)
    }

    func testCanSendWhileRunningQueues() {
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "and another thing", running: true), .queue)
    }

    func testCanSendWhenIdleSends() {
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "hello", running: false), .send)
    }

    func testCanSendOverTheCapIsTooLong() {
        let long = String(repeating: "x", count: SessionInput.maxMessageLength + 1)
        XCTAssertEqual(T3ComposerDrafts.canSend(text: long, running: false), .tooLong(SessionInput.maxMessageLength + 1))
        // The cap applies to the trimmed prompt — what is actually sent.
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "  " + long + "  ", running: false),
                       .tooLong(SessionInput.maxMessageLength + 1))
        XCTAssertEqual(T3ComposerDrafts.canSend(text: String(repeating: "x", count: SessionInput.maxMessageLength),
                                                running: false), .send)
        // Too long beats queueing: a running session would reject it too.
        XCTAssertEqual(T3ComposerDrafts.canSend(text: long, running: true), .tooLong(long.count))
    }

    func testCanSendHonoursACallerCap() {
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "abcd", running: false, maxLength: 3), .tooLong(4))
    }

    /// The message the composer shows under the cap, upstream's own sentence
    /// (`composerSubmission.ts:20-22`).
    func testTooLongMessage() {
        XCTAssertEqual(T3ComposerDrafts.tooLongMessage(length: 4001, maxLength: 4000),
                       "Prompt is 1 character over the 4,000-character limit. Shorten or split it before sending.")
        XCTAssertEqual(T3ComposerDrafts.tooLongMessage(length: 5234, maxLength: 4000),
                       "Prompt is 1,234 characters over the 4,000-character limit. Shorten or split it before sending.")
    }

    // MARK: - Control characters (the wire's own rule)

    /// `SessionInput.isValidMessage` (SessionInput.swift:148-155) refuses every
    /// control scalar but `\n`. That check is `#if !os(iOS)`, so the composer
    /// cannot call it — it would gate on length alone, send a pasted Tab, get
    /// "invalid message" back and have cleared the draft by then.
    func testCanSendRefusesControlCharacters() {
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "a\tb", running: false), .invalid)
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "line\r\nline", running: false), .invalid)
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "esc\u{1B}[0m", running: false), .invalid)
        // The one control scalar a prompt may carry.
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "line\nline", running: false), .send)
        // A running session queues a valid multi-line prompt, and refuses an
        // invalid one just the same.
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "line\nline", running: true), .queue)
        XCTAssertEqual(T3ComposerDrafts.canSend(text: "a\tb", running: true), .invalid)
    }

    /// Every verdict the composer refuses on agrees with the wire, so a send
    /// the button allows is never answered "invalid message".
    func testCanSendAgreesWithTheWire() {
        for text in ["hi", "line\nline", "a\tb", "a\rb", "  ", String(repeating: "x", count: 4001)] {
            let allowed = T3ComposerDrafts.canSend(text: text, running: false) == .send
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(allowed, SessionInput.isValidMessage(trimmed), text.debugDescription)
        }
    }

    // MARK: - Prompt recall

    func testStepHistoryBackwardFromAFreshComposer() {
        let history = ["newest", "older", "oldest"]
        let step = T3ComposerDrafts.stepHistory(history: history, index: nil, current: "", direction: -1)
        XCTAssertEqual(step?.index, 0)
        XCTAssertEqual(step?.text, "newest")
    }

    func testStepHistoryBackwardFallsThroughOnATypedPrompt() {
        XCTAssertNil(T3ComposerDrafts.stepHistory(history: ["a"], index: nil, current: "typed", direction: -1))
    }

    func testStepHistoryStopsAtTheOldest() {
        let history = ["newest", "oldest"]
        XCTAssertNil(T3ComposerDrafts.stepHistory(history: history, index: 1, current: "oldest", direction: -1))
    }

    func testStepHistoryForwardPastTheNewestEmptiesTheField() {
        let step = T3ComposerDrafts.stepHistory(history: ["newest", "older"], index: 0, current: "newest", direction: 1)
        XCTAssertNil(step?.index)
        XCTAssertEqual(step?.text, "")
    }

    func testStepHistoryForwardFallsThroughWhenNotBrowsing() {
        XCTAssertNil(T3ComposerDrafts.stepHistory(history: ["a"], index: nil, current: "", direction: 1))
    }

    /// An edited recall ends browsing (`composerPromptHistory.ts:186-188`):
    /// the field no longer holds what was recalled, so ↑ starts over — and
    /// only from an empty field, so an edited one falls through.
    func testStepHistoryRestartsAfterAnEdit() {
        let history = ["newest", "older"]
        XCTAssertNil(T3ComposerDrafts.stepHistory(history: history, index: 1, current: "older, edited", direction: -1))
        XCTAssertNil(T3ComposerDrafts.stepHistory(history: history, index: 1, current: "older, edited", direction: 1))
        let fresh = T3ComposerDrafts.stepHistory(history: history, index: 1, current: "", direction: -1)
        XCTAssertEqual(fresh?.index, 0)
    }

    func testStepHistoryOnAnEmptyHistory() {
        XCTAssertNil(T3ComposerDrafts.stepHistory(history: [], index: nil, current: "", direction: -1))
    }

    // MARK: - The queue badge

    private func userMessage(_ text: String, at: Date) -> SessionTimeline.Message {
        SessionTimeline.Message(id: UUID().uuidString, role: .user, text: text, images: nil, sender: nil,
                                turnId: "t", streaming: false, createdAt: at)
    }

    func testDrainQueueMatchesOnePerMessage() {
        let sent = Date()
        let queued = [T3QueuedSend(text: "again", sentAt: sent), T3QueuedSend(text: "again", sentAt: sent)]
        let one = T3ComposerDrafts.drainQueue(queued: queued,
                                              userMessages: [userMessage("again", at: sent.addingTimeInterval(1))])
        XCTAssertEqual(one.count, 1)
        let both = T3ComposerDrafts.drainQueue(queued: queued, userMessages: [
            userMessage("again", at: sent.addingTimeInterval(1)),
            userMessage("again", at: sent.addingTimeInterval(2)),
        ])
        XCTAssertTrue(both.isEmpty)
    }

    /// The transcript before the send is somebody else's prompt.
    func testDrainQueueIgnoresAnOlderMessage() {
        let sent = Date()
        let queued = [T3QueuedSend(text: "hello", sentAt: sent)]
        XCTAssertEqual(T3ComposerDrafts.drainQueue(queued: queued,
                                                   userMessages: [userMessage("hello", at: sent.addingTimeInterval(-60))]),
                       queued)
    }

    /// Exact text, not `contains`: a longer prompt that merely quotes this one
    /// is a different send.
    func testDrainQueueIgnoresASuperstring() {
        let sent = Date()
        let queued = [T3QueuedSend(text: "hi", sentAt: sent)]
        XCTAssertEqual(T3ComposerDrafts.drainQueue(queued: queued,
                                                   userMessages: [userMessage("hi there", at: sent.addingTimeInterval(1))]),
                       queued)
        XCTAssertEqual(T3ComposerDrafts.drainQueue(queued: queued, userMessages: [userMessage("say hi", at: sent.addingTimeInterval(1))]),
                       queued)
    }

    /// An assistant message never drains anything.
    func testDrainQueueIgnoresAssistantMessages() {
        let sent = Date()
        let queued = [T3QueuedSend(text: "hi", sentAt: sent)]
        let reply = SessionTimeline.Message(id: "a", role: .assistant, text: "hi", images: nil, sender: nil,
                                            turnId: "t", streaming: false, createdAt: sent.addingTimeInterval(1))
        XCTAssertEqual(T3ComposerDrafts.drainQueue(queued: queued, userMessages: [reply]), queued)
    }

    /// `SessionInput.deliver` appends the attachment line to the delivered text
    /// (SessionInput.swift:321) and the transcript keeps it, so the queued
    /// prompt is compared against the body without it.
    func testDrainQueueMatchesThroughTheAttachmentLine() {
        let sent = Date()
        let queued = [T3QueuedSend(text: "look at this", sentAt: sent)]
        let message = userMessage("look at this\n\n[attached: /tmp/a.png, /tmp/b.png]", at: sent.addingTimeInterval(1))
        XCTAssertTrue(T3ComposerDrafts.drainQueue(queued: queued, userMessages: [message]).isEmpty)
    }

    /// A draft persisted before the ref carried its size still loads (the row
    /// stats that one file instead of reading `bytes`).
    func testLoadADraftWrittenBeforeAttachmentSizes() {
        let json = #"{"t":{"text":"hi","attachments":[{"path":"/tmp/a.png","mime":"image/png"}]}}"#
        let drafts = T3ComposerDrafts.load(from: Data(json.utf8))
        XCTAssertEqual(drafts["t"]?.attachments.first?.path, "/tmp/a.png")
        XCTAssertNil(drafts["t"]?.attachments.first?.bytes)
    }
}
