import XCTest
@testable import InfinitusUI

/// MarkdownText's block split — the additions for T3's rendering (fence
/// language, task items, rules) beside the existing shapes.
final class MarkdownBlocksTests: XCTestCase {
    func testFenceKeepsItsLanguage() {
        let blocks = MarkdownText.blocks("```swift\nlet a = 1\n```\n```\nplain\n```")
        XCTAssertEqual(blocks, [.code(language: "swift", "let a = 1"), .code(language: nil, "plain")])
    }

    func testTaskItemsAndRules() {
        let blocks = MarkdownText.blocks("- [x] done\n- [ ] open\n- plain\n---\n***\ntext")
        XCTAssertEqual(blocks, [.task(done: true, "done"), .task(done: false, "open"), .bullet(indent: 0, "plain"),
                                .rule, .rule, .paragraph("text")])
    }

    func testPipeTables() {
        let blocks = MarkdownText.blocks("| PR | State |\n|---|:---:|\n| #360 | open |\n| #362 | queued |\n\nafter")
        XCTAssertEqual(blocks, [.table(header: ["PR", "State"], rows: [["#360", "open"], ["#362", "queued"]]), .paragraph("after")])
        XCTAssertEqual(MarkdownText.blocks("| only |"), [.table(header: ["only"], rows: [])])
    }

    func testDashesInsideAParagraphAreNotARule() {
        XCTAssertEqual(MarkdownText.blocks("a -- b\n--"), [.paragraph("a -- b --")])
    }
}
