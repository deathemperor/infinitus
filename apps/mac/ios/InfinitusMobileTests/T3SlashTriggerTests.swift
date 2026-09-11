import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// `detectComposerTrigger`'s slash case, cursor at the end of the text.
final class T3SlashTriggerTests: XCTestCase {
    func testASlashAtLineStartOpensWithTheQuery() {
        XCTAssertEqual(T3SlashTrigger.detect("/")?.query, "")
        XCTAssertEqual(T3SlashTrigger.detect("/rev")?.query, "rev")
        XCTAssertEqual(T3SlashTrigger.detect("first line\n/x")?.query, "x")
    }

    func testAnythingElseKeepsTheMenuClosed() {
        XCTAssertNil(T3SlashTrigger.detect(""))
        XCTAssertNil(T3SlashTrigger.detect("hello /rev"), "not at the line start")
        XCTAssertNil(T3SlashTrigger.detect("/review "), "a space after the command closes it")
        XCTAssertNil(T3SlashTrigger.detect("/a\nmore"), "the trigger is on the current line only")
    }

    func testSelectingReplacesTheTriggerWithTheInsertion() {
        let review = SlashCommand(name: "review", description: "", source: .projectCommand)
        let match = T3SlashTrigger.detect("note\n/rev")!
        XCTAssertEqual(T3SlashTrigger.apply(review, to: "note\n/rev", match: match), "note\n/review ")
    }
}
