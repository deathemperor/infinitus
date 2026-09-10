import XCTest
@testable import InfinitusCore

/// The terminal surface's two pure rules (#507): upstream's terminal label and
/// the reset/append + `since` bookkeeping a tab switch depends on.
final class T3TerminalSurfaceTests: XCTestCase {

    // MARK: - getTerminalLabel (terminalLabels.ts:4-11)

    func testLabelNumbersTermIds() {
        XCTAssertEqual(T3TerminalSurface.label(terminalId: "term-1"), "Terminal 1")
        XCTAssertEqual(T3TerminalSurface.label(terminalId: "term-42"), "Terminal 42")
        XCTAssertEqual(T3TerminalSurface.label(terminalId: T3Terminal.defaultTerminalId), "Terminal 1")
    }

    /// The regex is `/^term(?:inal)?-(\d+)$/i` — the long spelling and any case.
    func testLabelAcceptsTerminalSpellingAndAnyCase() {
        XCTAssertEqual(T3TerminalSurface.label(terminalId: "terminal-3"), "Terminal 3")
        XCTAssertEqual(T3TerminalSurface.label(terminalId: "TERM-7"), "Terminal 7")
        XCTAssertEqual(T3TerminalSurface.label(terminalId: "Terminal-8"), "Terminal 8")
    }

    /// Anything the regex misses is its own label, verbatim.
    func testLabelFallsBackToTheId() {
        for id in ["build", "term-", "term-1a", "term-1-2", "termx-1", "-1", "term_1", "term-٢"] {
            XCTAssertEqual(T3TerminalSurface.label(terminalId: id), id, id)
        }
    }

    // MARK: - Attachment: reset vs append

    func testFirstSnapshotResetsAndLaterChunksAppend() {
        var attachment = T3TerminalSurface.Attachment()
        let first = T3Terminal.Frame.snapshot(.init(history: "one", status: .running, sequence: 3))
        let second = T3Terminal.Frame.snapshot(.init(history: "two", status: .running, sequence: 6))
        XCTAssertEqual(attachment.step(first), .reset("one"))
        XCTAssertEqual(attachment.step(second), .append("two"))
        XCTAssertEqual(attachment.sequence, 6)
    }

    func testOutputAppendsAndCarriesTheResumePoint() {
        var attachment = T3TerminalSurface.Attachment()
        _ = attachment.step(.snapshot(.init(history: "hi", status: .running, sequence: 2)))
        XCTAssertEqual(attachment.step(.output(.init(data: "$ ", sequence: 4))), .append("$ "))
        XCTAssertEqual(attachment.sequence, 4)
    }

    /// A re-attach whose `since` the ring still covers gets a replay and no
    /// snapshot at all: the replay must land on the screen that is already
    /// there, not wait for a reset that never comes.
    func testReplayWithoutASnapshotAppends() {
        var attachment = T3TerminalSurface.Attachment()
        XCTAssertEqual(attachment.step(.output(.init(data: "back", sequence: 9))), .append("back"))
        XCTAssertFalse(attachment.awaitingSnapshot)
    }

    /// The tab switch: detach, re-attach, and the snapshot the Mac sends
    /// because the ring had rolled past `since` resets the screen once.
    func testAttachingRearmsTheResetButKeepsTheSequence() {
        var attachment = T3TerminalSurface.Attachment()
        _ = attachment.step(.snapshot(.init(history: "old", status: .running, sequence: 3)))
        _ = attachment.step(.output(.init(data: "more", sequence: 7)))
        attachment.attaching()
        XCTAssertEqual(attachment.sequence, 7, "the resume point survives a detach")
        XCTAssertEqual(attachment.step(.snapshot(.init(history: "fresh", status: .running, sequence: 20))),
                       .reset("fresh"))
        XCTAssertEqual(attachment.step(.output(.init(data: "!", sequence: 21))), .append("!"))
    }

    func testNonTextFramesAndEmptyPayloadsWriteNothing() {
        var attachment = T3TerminalSurface.Attachment()
        _ = attachment.step(.snapshot(.init(history: "x", status: .running, sequence: 1)))
        XCTAssertEqual(attachment.step(.output(.init(data: "", sequence: 1))), .nothing)
        XCTAssertEqual(attachment.step(.exited(.init(exitCode: 0, exitSignal: nil))), .nothing)
        XCTAssertEqual(attachment.step(.closed(.init(reason: "idle"))), .nothing)
        XCTAssertEqual(attachment.step(.error(.init(message: "no"))), .nothing)
        XCTAssertEqual(attachment.sequence, 1, "a frame with no text moves no resume point")
    }

    /// An empty first snapshot — a terminal opened a millisecond ago — still
    /// resets, so a stale screen from a previous shell cannot survive it.
    func testEmptyFirstSnapshotStillResets() {
        var attachment = T3TerminalSurface.Attachment()
        XCTAssertEqual(attachment.step(.snapshot(.init(history: "", status: .running, sequence: 0))),
                       .reset(""))
    }

    // MARK: - System lines (ThreadTerminalDrawer.tsx:107-109, :439)

    func testSystemMessageBracketsLikeUpstream() {
        XCTAssertEqual(T3TerminalSurface.systemMessage(T3TerminalSurface.exitedMessage),
                       "\r\n[terminal] Process exited\r\n")
        XCTAssertEqual(T3TerminalSurface.closedMessage, "Terminal closed")
    }
}
