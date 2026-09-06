import XCTest
@testable import InfinitusCore

/// Hunk comments from the phone (#166): the patch split for tapping, the
/// comments composed into one deliverable message.
final class PatchReviewTests: XCTestCase {
    static let patch = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -1,3 +1,4 @@ struct A {
     let x = 1
    -let y = 2
    +let y = 3
    +let z = 4
    @@ -10,2 +11,2 @@ func f() {
    -    old()
    +    new()
    diff --git a/New.md b/New.md
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/New.md
    @@ -0,0 +1 @@
    +hello
    diff --git a/pic.png b/pic.png
    new file mode 100644
    index 0000000..4444444
    Binary files /dev/null and b/pic.png differ
    diff --git a/old.txt b/renamed.txt
    similarity index 90%
    rename from old.txt
    rename to renamed.txt
    """

    func testParseSplitsFilesAndHunks() {
        let files = PatchReview.parse(Self.patch)
        XCTAssertEqual(files.map(\.path), ["Sources/A.swift", "New.md", "pic.png", "renamed.txt"])
        XCTAssertEqual(files[0].hunks.count, 2)
        XCTAssertEqual(files[0].hunks[0].header, "@@ -1,3 +1,4 @@ struct A {")
        XCTAssertEqual(files[0].hunks[0].lines, [" let x = 1", "-let y = 2", "+let y = 3", "+let z = 4"])
        XCTAssertEqual(files[0].hunks[1].lines, ["-    old()", "+    new()"])
        XCTAssertNil(files[0].note)
        XCTAssertEqual(files[1].note, "new file")
        XCTAssertEqual(files[1].hunks.first?.lines, ["+hello"])
        XCTAssertEqual(files[2].note, "new file, binary")
        XCTAssertTrue(files[2].hunks.isEmpty)
        XCTAssertEqual(files[3].note, "renamed from old.txt")
    }

    func testATruncatedPatchParsesAsFarAsItGoes() {
        let cut = String(Self.patch.prefix(160))
        let files = PatchReview.parse(cut)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].hunks.count, 1)
        XCTAssertEqual(PatchReview.parse(""), [])
    }

    func testComposeQuotesTheHunkAndKeepsTheMessageValid() {
        let files = PatchReview.parse(Self.patch)
        let comment = PatchReview.Comment(path: files[0].path, hunk: files[0].hunks[0], text: "why 3?\tkeep\u{7}2")
        let text = PatchReview.compose(checkpoint: 4, subject: "#4 fix the thing", verdict: .requestChanges, comments: [comment])
        XCTAssertTrue(text.hasPrefix("Reviewed the changes since checkpoint #4 (#4 fix the thing) from the phone: changes requested."))
        XCTAssertTrue(text.contains("1. Sources/A.swift @@ -1,3 +1,4 @@ struct A {"))
        XCTAssertTrue(text.contains("   > -let y = 2\n"))
        XCTAssertTrue(text.contains("   why 3?    keep2"))
        XCTAssertTrue(SessionInput.isValidMessage(text))
        let ok = PatchReview.compose(checkpoint: 4, subject: "s", verdict: .approve, comments: [])
        XCTAssertEqual(ok, "Reviewed the changes since checkpoint #4 (s) from the phone: approved, they look good. Carry on.")
    }

    func testALongReviewShrinksExcerptsBeforeCuttingText() {
        let hunk = PatchReview.Hunk(header: "@@ -1 +1 @@", lines: Array(repeating: String(repeating: "x", count: 80), count: 20))
        let comments = (0..<12).map { PatchReview.Comment(path: "f\($0).swift", hunk: hunk, text: "note \($0)") }
        let text = PatchReview.compose(checkpoint: 1, subject: "s", verdict: .requestChanges, comments: comments)
        XCTAssertEqual(PatchReview.maxLength, SessionInput.maxMessageLength)
        XCTAssertLessThanOrEqual(text.count, PatchReview.maxLength)
        XCTAssertTrue(text.contains("12. f11.swift"), "every comment survives")
        XCTAssertTrue(text.contains("note 11"))
        XCTAssertTrue(SessionInput.isValidMessage(text))
        let huge = [PatchReview.Comment(path: "f", hunk: hunk, text: String(repeating: "y", count: 5000))]
        let cut = PatchReview.compose(checkpoint: 1, subject: "s", verdict: .requestChanges, comments: huge)
        XCTAssertEqual(cut.count, PatchReview.maxLength)
        XCTAssertTrue(cut.hasSuffix("…"))
    }
}
