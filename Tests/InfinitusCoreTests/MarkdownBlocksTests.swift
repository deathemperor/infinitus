import XCTest
@testable import InfinitusCore

/// The block parser moved from `MarkdownText` (InfinitusUI can't be linked
/// from a Core-only test target) — same shapes the phone's
/// `MarkdownBlocksTests` (ios/InfinitusMobileTests, PR #360) already covers,
/// plus the nested-list `indent` this task adds (T3 clone B-10).
final class MarkdownBlocksTests: XCTestCase {
    // Lifted verbatim from ios/InfinitusMobileTests/MarkdownBlocksTests.swift,
    // except `.bullet("plain")` -> `.bullet(indent: 0, "plain")`.
    func testFenceKeepsItsLanguage() {
        let blocks = MarkdownBlocks.parse("```swift\nlet a = 1\n```\n```\nplain\n```")
        XCTAssertEqual(blocks, [.code(language: "swift", "let a = 1"), .code(language: nil, "plain")])
    }

    func testTaskItemsAndRules() {
        let blocks = MarkdownBlocks.parse("- [x] done\n- [ ] open\n- plain\n---\n***\ntext")
        XCTAssertEqual(blocks, [.task(done: true, "done"), .task(done: false, "open"), .bullet(indent: 0, "plain"),
                                .rule, .rule, .paragraph("text")])
    }

    func testPipeTables() {
        let blocks = MarkdownBlocks.parse("| PR | State |\n|---|:---:|\n| #360 | open |\n| #362 | queued |\n\nafter")
        XCTAssertEqual(blocks, [.table(header: ["PR", "State"], rows: [["#360", "open"], ["#362", "queued"]]), .paragraph("after")])
        XCTAssertEqual(MarkdownBlocks.parse("| only |"), [.table(header: ["only"], rows: [])])
    }

    func testDashesInsideAParagraphAreNotARule() {
        XCTAssertEqual(MarkdownBlocks.parse("a -- b\n--"), [.paragraph("a -- b --")])
    }

    // New for T3 clone B-10: nested lists.
    func testNestedBulletsCarryTheirIndent() {
        XCTAssertEqual(MarkdownBlocks.parse("- a\n  - b\n    - c"),
                       [.bullet(indent: 0, "a"), .bullet(indent: 1, "b"), .bullet(indent: 2, "c")])
    }

    func testATabIndentsOneLevel() {
        XCTAssertEqual(MarkdownBlocks.parse("- a\n\t- b"), [.bullet(indent: 0, "a"), .bullet(indent: 1, "b")])
    }

    func testNestedNumberedItemsCarryTheirIndent() {
        XCTAssertEqual(MarkdownBlocks.parse("1. a\n  1. b"),
                       [.numbered(indent: 0, "1", "a"), .numbered(indent: 1, "1", "b")])
    }

    func testAnOddSpaceCountFloorsToTheLowerLevel() {
        XCTAssertEqual(MarkdownBlocks.parse("1. a\n   - b"),
                       [.numbered(indent: 0, "1", "a"), .bullet(indent: 1, "b")])
    }
}
