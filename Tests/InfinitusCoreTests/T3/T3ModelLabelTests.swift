import XCTest
@testable import InfinitusCore

/// `activeThreadModelDisplayName` (`ChatComposer.tsx:5566`).
final class T3ModelLabelTests: XCTestCase {
    func testDropsTheVendorPrefixAndTheBuildDate() {
        XCTAssertEqual(T3ModelLabel.display("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    }

    func testKeepsTheFamilyAndVersionWithNoBuildDate() {
        XCTAssertEqual(T3ModelLabel.display("claude-opus-4-1"), "Opus 4.1")
    }

    func testHaikuWithABuildDate() {
        XCTAssertEqual(T3ModelLabel.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    func testFableWithNoBuildDate() {
        XCTAssertEqual(T3ModelLabel.display("claude-fable-5-1"), "Fable 5.1")
    }

    func testANonClaudeVendorKeepsItsPrefix() {
        XCTAssertEqual(T3ModelLabel.display("gpt-5"), "Gpt 5")
    }

    func testAFamilyWithNoVersion() {
        XCTAssertEqual(T3ModelLabel.display("sonnet"), "Sonnet")
    }

    /// The vendor prefix alone leaves no family — the id comes back unchanged.
    func testBareClaudeFallsBackToTheId() {
        XCTAssertEqual(T3ModelLabel.display("claude"), "claude")
    }
}
