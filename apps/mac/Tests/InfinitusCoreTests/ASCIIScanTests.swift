import XCTest
@testable import InfinitusCore

final class ASCIIScanTests: XCTestCase {
    func testFoldsOnlyASCIILettersAndMatchesLikeLowercasedContains() {
        let text = "Aws: [ERROR] Über-Session EXPIRED\n  Fix: AWS login --profile Papaya"
        let lower = ASCIIScan.lowered(text)
        XCTAssertEqual(String(decoding: lower, as: UTF8.self), "aws: [error] Über-session expired\n  fix: aws login --profile papaya")
        XCTAssertTrue(ASCIIScan.contains(lower, Array("fix: aws login".utf8)))
        XCTAssertFalse(ASCIIScan.contains(lower, Array("gcloud".utf8)))
        XCTAssertFalse(ASCIIScan.contains([], Array("a".utf8)))
        XCTAssertFalse(ASCIIScan.contains(lower, []))
    }

    func testLineStartsSkipEmptyLinesAndIgnoreMidLineHits() {
        let lower = ASCIIScan.lowered("\n\nreading aws: [error] quoted mid-line\n  fix: aws login\n")
        XCTAssertTrue(ASCIIScan.anyLineStarts(lower, with: [Array("  fix: aws login".utf8)]))
        XCTAssertFalse(ASCIIScan.anyLineStarts(lower, with: [Array("aws: [error]".utf8)]), "mid-line is not a line start")
        XCTAssertFalse(ASCIIScan.anyLineStarts(lower, with: [Array("fix: aws login".utf8)]), "the indent is part of the prefix")
        XCTAssertTrue(ASCIIScan.anyLineStarts(Array("x".utf8), with: [Array("x".utf8)]), "a last line without a newline counts")
    }
}
