import XCTest
@testable import InfinitusCore

/// `T3ComposerMenuState`: the `/` and `@` menu's own state, apart from the
/// view — its highlight and which trigger ⎋ shut.
final class T3ComposerMenuStateTests: XCTestCase {

    // MARK: - dismissKey / trigger

    func testDismissKeyIsKindAndStart() {
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        XCTAssertEqual(T3ComposerMenuState.dismissKey(found), "command:0")
    }

    func testADismissedTriggerStaysNilWhileTypingOnInsideIt() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        state.dismissed = T3ComposerMenuState.dismissKey(found)
        XCTAssertNil(state.trigger(found))
        // Same kind + start, a longer query: still shut.
        let longer = T3ComposerTrigger.detect(text: "/review", caret: 7)!
        XCTAssertNil(state.trigger(longer))
    }

    func testATriggerAtADifferentOffsetReopens() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        state.dismissed = T3ComposerMenuState.dismissKey(found)
        let elsewhere = T3ComposerTrigger.detect(text: "hi\n/re", caret: 6)!
        XCTAssertEqual(state.trigger(elsewhere), elsewhere)
    }

    // MARK: - triggerMoved

    func testTriggerMovedKeepsDismissedForTheSameKey() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        state.dismissed = T3ComposerMenuState.dismissKey(found)
        let longer = T3ComposerTrigger.detect(text: "/review", caret: 7)!
        state.triggerMoved(longer)
        XCTAssertEqual(state.dismissed, T3ComposerMenuState.dismissKey(found))
    }

    func testTriggerMovedClearsDismissedForADifferentKey() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        state.dismissed = T3ComposerMenuState.dismissKey(found)
        let elsewhere = T3ComposerTrigger.detect(text: "hi\n/re", caret: 6)!
        state.triggerMoved(elsewhere)
        XCTAssertNil(state.dismissed)
    }

    func testTriggerMovedClearsDismissedForNil() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        state.dismissed = T3ComposerMenuState.dismissKey(found)
        state.triggerMoved(nil)
        XCTAssertNil(state.dismissed)
    }

    // MARK: - opened

    func testOpenedClearsTheHighlightButNotADismissal() {
        var state = T3ComposerMenuState()
        state.highlighted = "a"
        state.highlightedKey = "command:"
        state.dismissed = "command:0"
        state.opened()
        XCTAssertNil(state.highlighted)
        XCTAssertNil(state.highlightedKey)
        XCTAssertEqual(state.dismissed, "command:0")
    }

    // MARK: - key

    func testKeyWithNoTriggerIsUnhandledForEveryKey() {
        var state = T3ComposerMenuState()
        for key: T3ComposerMenuKey in [.up, .down, .pick, .dismiss] {
            XCTAssertEqual(state.key(key, trigger: nil, itemIDs: ["a"]), .unhandled)
        }
    }

    func testUpAndDownWithNoRowsAreUnhandled() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        XCTAssertEqual(state.key(.down, trigger: found, itemIDs: []), .unhandled)
        XCTAssertEqual(state.key(.up, trigger: found, itemIDs: []), .unhandled)
    }

    /// Nothing highlighted yet resolves to the first row by fallback
    /// (`T3ComposerMenuHighlight.resolve`, exercised through `activeItemID`),
    /// and ↓ nudges forward from THAT — so the first ↓ lands on the SECOND
    /// row, not the first (the first row reads as already active before any
    /// key is pressed).
    func testDownFromNoHighlightMovesPastTheDefaultedFirstRow() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        XCTAssertEqual(state.key(.down, trigger: found, itemIDs: ["a", "b"]), .moved)
        XCTAssertEqual(state.highlighted, "b")
        XCTAssertEqual(state.highlightedKey, found.searchKey)
    }

    func testUpWrapsLikeADirectNudgeCall() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        XCTAssertEqual(state.key(.up, trigger: found, itemIDs: ["a", "b", "c"]), .moved)
        let expected = T3ComposerMenuHighlight.nudge(itemIDs: ["a", "b", "c"], highlighted: nil, direction: -1)
        XCTAssertEqual(state.highlighted, expected)
    }

    /// `T3ComposerMenuHighlight.resolve` falls back to the first row whenever
    /// nothing is highlighted (or the highlight doesn't match the current
    /// query) — so `.pick` with a non-empty list never comes back
    /// `.unhandled`; only an empty list does (covered above).
    func testPickWithRowsButNoHighlightResolvesToTheFirstRow() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        XCTAssertEqual(state.key(.pick, trigger: found, itemIDs: ["a", "b"]), .pick("a"))
    }

    func testPickAfterADownPicksTheHighlightedRow() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        // ↓ moves past the defaulted first row onto "b" (see above).
        _ = state.key(.down, trigger: found, itemIDs: ["a", "b"])
        XCTAssertEqual(state.key(.pick, trigger: found, itemIDs: ["a", "b"]), .pick("b"))
    }

    func testDismissShutsTheMenu() {
        var state = T3ComposerMenuState()
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)!
        XCTAssertEqual(state.key(.dismiss, trigger: found, itemIDs: ["a"]), .dismissed)
        XCTAssertEqual(state.dismissed, T3ComposerMenuState.dismissKey(found))
    }

    // MARK: - picked

    func testPickedClearsAllThree() {
        var state = T3ComposerMenuState()
        state.highlighted = "a"
        state.highlightedKey = "k"
        state.dismissed = "d"
        state.picked()
        XCTAssertNil(state.highlighted)
        XCTAssertNil(state.highlightedKey)
        XCTAssertNil(state.dismissed)
    }
}
