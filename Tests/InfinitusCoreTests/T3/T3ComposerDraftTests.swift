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
}
