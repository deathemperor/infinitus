import XCTest
@testable import InfinitusCore

/// `detectComposerTrigger` (`packages/shared/src/composerTrigger.ts:50-116`)
/// and the menu's highlight rules (`composerMenuHighlight.ts:1-20`,
/// `nudgeComposerMenuHighlight`, `ChatComposer.tsx:2810-2824`).
final class T3ComposerTriggerTests: XCTestCase {

    // MARK: - The `/` command trigger (line-anchored, `:56-60`)

    func testSlashAtTheStartOpensTheCommandMenu() {
        let found = T3ComposerTrigger.detect(text: "/re", caret: 3)
        XCTAssertEqual(found?.kind, .command)
        XCTAssertEqual(found?.query, "re")
        XCTAssertEqual(found?.start, 0)
        XCTAssertEqual(found?.end, 3)
    }

    /// The line prefix must START with the slash (`:59`) — a slash after text
    /// on the same line reaches the agent as literal text.
    func testSlashAfterTextIsNotATrigger() {
        XCTAssertNil(T3ComposerTrigger.detect(text: "fix /re", caret: 7))
    }

    func testSlashAtTheStartOfALaterLineOpensTheCommandMenu() {
        let found = T3ComposerTrigger.detect(text: "hello\n/re", caret: 9)
        XCTAssertEqual(found?.kind, .command)
        XCTAssertEqual(found?.query, "re")
        XCTAssertEqual(found?.start, 6)
    }

    /// `^\/(\S*)$` matches the bare slash too (`:60`): an empty query offers
    /// the whole list.
    func testABareSlashOffersTheWholeList() {
        let found = T3ComposerTrigger.detect(text: "/", caret: 1)
        XCTAssertEqual(found?.kind, .command)
        XCTAssertEqual(found?.query, "")
    }

    func testSlashInsideAWordIsNotATrigger() {
        XCTAssertNil(T3ComposerTrigger.detect(text: "a/b", caret: 3))
    }

    /// `\S*` ends at the first space (`:60`): the command menu closes once the
    /// command is typed out and a space follows.
    func testASpaceAfterTheCommandClosesTheMenu() {
        XCTAssertNil(T3ComposerTrigger.detect(text: "/review this", caret: 12))
    }

    // MARK: - The `@` mention trigger (token-anchored, `:90-115`)

    func testAtAfterWhitespaceOpensTheMentionMenu() {
        let found = T3ComposerTrigger.detect(text: "fix @Sour", caret: 9)
        XCTAssertEqual(found?.kind, .mention)
        XCTAssertEqual(found?.query, "Sour")
        XCTAssertEqual(found?.start, 4)
        XCTAssertEqual(found?.end, 9)
    }

    func testAtAtTheStartOfThePromptOpensTheMentionMenu() {
        XCTAssertEqual(T3ComposerTrigger.detect(text: "@Sour", caret: 5)?.kind, .mention)
    }

    /// The token starts after whitespace (`:91-95`), so an address is not a
    /// mention.
    func testAnAtInsideAWordIsNotATrigger() {
        XCTAssertNil(T3ComposerTrigger.detect(text: "email@x", caret: 7))
    }

    func testASpaceAfterTheMentionClosesTheMenu() {
        XCTAssertNil(T3ComposerTrigger.detect(text: "@Sour ", caret: 6))
    }

    /// The range ends at the caret (`:113`), never at the end of the word: a
    /// pick replaces only what was typed before it.
    func testTheQueryIsOnlyWhatPrecedesTheCaret() {
        let found = T3ComposerTrigger.detect(text: "fix @Sources/T3 more", caret: 8)
        XCTAssertEqual(found?.kind, .mention)
        XCTAssertEqual(found?.query, "Sou")
        XCTAssertEqual(found?.start, 4)
        XCTAssertEqual(found?.end, 8)
    }

    /// JS strings index UTF-16 code units and so does `NSTextView`'s selected
    /// range: the offsets are UTF-16, not characters.
    func testOffsetsAreUTF16CodeUnits() {
        let text = "🎉 @Sou"
        let found = T3ComposerTrigger.detect(text: text, caret: 7)
        XCTAssertEqual(found?.kind, .mention)
        XCTAssertEqual(found?.query, "Sou")
        XCTAssertEqual(found?.start, 3)
        XCTAssertEqual(found?.end, 7)
        XCTAssertEqual(found.map { String(text[$0.range]) }, "@Sou")
    }

    /// `clampCursor` (`:34-37`).
    func testAnOutOfRangeCaretIsClamped() {
        XCTAssertEqual(T3ComposerTrigger.detect(text: "/re", caret: 999)?.query, "re")
        XCTAssertNil(T3ComposerTrigger.detect(text: "/re", caret: -4))
    }

    /// `$` opens the skill menu upstream (`:98-105`); this port has no skill
    /// producer, so the token stays literal text.
    func testTheDollarSkillTriggerIsNotPorted() {
        XCTAssertNil(T3ComposerTrigger.detect(text: "$ui", caret: 3))
    }

    // MARK: - Replacement (`replaceTextRange`, `:118-128`)

    func testReplacingTheTriggerRangeMovesTheCaretAfterTheInsertion() {
        let result = T3ComposerTrigger.replacing("fix @Sou", start: 4, end: 8,
                                                 with: "@Sources/T3/x.swift ")
        XCTAssertEqual(result.text, "fix @Sources/T3/x.swift ")
        XCTAssertEqual(result.caret, 24)
    }

    func testReplacingClampsAnOutOfRangeRange() {
        let result = T3ComposerTrigger.replacing("hi", start: 5, end: 1, with: "/plan ")
        XCTAssertEqual(result.text, "hi/plan ")
        XCTAssertEqual(result.caret, 8)
    }

    func testReplacingCountsUTF16CodeUnits() {
        let result = T3ComposerTrigger.replacing("🎉 @Sou", start: 3, end: 7, with: "@a.swift ")
        XCTAssertEqual(result.text, "🎉 @a.swift ")
        XCTAssertEqual(result.caret, 12)
    }

    /// `composerMenuSearchKey` (`ChatComposer.tsx:2024-2026`).
    func testTheSearchKeyIsTheKindAndTheTrimmedLowercasedQuery() {
        XCTAssertEqual(T3ComposerTrigger.detect(text: "/Re", caret: 3)?.searchKey, "command:re")
        XCTAssertEqual(T3ComposerTrigger.detect(text: "@Sour", caret: 5)?.searchKey, "mention:sour")
    }

    // MARK: - The highlight (`composerMenuHighlight.ts`)

    private let ids = ["a", "b", "c"]

    func testResolveKeepsTheHighlightWhileTheQueryIsUnchanged() {
        XCTAssertEqual(T3ComposerMenuHighlight.resolve(itemIDs: ids, highlighted: "b",
                                                       currentKey: "command:re",
                                                       highlightedKey: "command:re"), "b")
    }

    func testResolveFallsBackToTheFirstItemWhenTheQueryMoved() {
        XCTAssertEqual(T3ComposerMenuHighlight.resolve(itemIDs: ids, highlighted: "b",
                                                       currentKey: "command:rev",
                                                       highlightedKey: "command:re"), "a")
    }

    func testResolveFallsBackWhenTheHighlightedItemIsGone() {
        XCTAssertEqual(T3ComposerMenuHighlight.resolve(itemIDs: ids, highlighted: "z",
                                                       currentKey: "command:re",
                                                       highlightedKey: "command:re"), "a")
    }

    func testResolveHasNothingToHighlightInAnEmptyList() {
        XCTAssertNil(T3ComposerMenuHighlight.resolve(itemIDs: [], highlighted: "a",
                                                     currentKey: "command:re",
                                                     highlightedKey: "command:re"))
    }

    /// `nudgeComposerMenuHighlight` (`ChatComposer.tsx:2814-2822`): with no
    /// highlight ↓ starts at the first row and ↑ at the last, and both wrap.
    func testNudgeDownFromNoHighlightTakesTheFirstRow() {
        XCTAssertEqual(T3ComposerMenuHighlight.nudge(itemIDs: ids, highlighted: nil, direction: 1), "a")
    }

    func testNudgeUpFromNoHighlightTakesTheLastRow() {
        XCTAssertEqual(T3ComposerMenuHighlight.nudge(itemIDs: ids, highlighted: nil, direction: -1), "c")
    }

    func testNudgeWraps() {
        XCTAssertEqual(T3ComposerMenuHighlight.nudge(itemIDs: ids, highlighted: "c", direction: 1), "a")
        XCTAssertEqual(T3ComposerMenuHighlight.nudge(itemIDs: ids, highlighted: "a", direction: -1), "c")
        XCTAssertEqual(T3ComposerMenuHighlight.nudge(itemIDs: ids, highlighted: "a", direction: 1), "b")
    }

    func testNudgeHasNothingToMoveInAnEmptyList() {
        XCTAssertNil(T3ComposerMenuHighlight.nudge(itemIDs: [], highlighted: nil, direction: 1))
    }
}
