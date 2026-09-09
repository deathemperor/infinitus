import XCTest
@testable import InfinitusCore

/// The preview pane's pure parts. The crumb cases are upstream's own
/// (`apps/web/src/components/files/filePath.test.ts:6-24`); the line split and
/// the notices are this port's, so they are pinned here.
final class T3FilePreviewTests: XCTestCase {

    // MARK: - Breadcrumbs

    /// `filePath.test.ts:6-15` "builds project, directory, and file crumbs".
    func testTheCrumbsRunFromTheProjectToTheFile() {
        let crumbs = T3FilePreview.breadcrumbs(projectName: "t3code", path: "apps/web/src/main.tsx")
        XCTAssertEqual(crumbs, [
            .init(label: "t3code", path: "", kind: .project),
            .init(label: "apps", path: "apps", kind: .directory),
            .init(label: "web", path: "apps/web", kind: .directory),
            .init(label: "src", path: "apps/web/src", kind: .directory),
            .init(label: "main.tsx", path: "apps/web/src/main.tsx", kind: .file),
        ])
    }

    /// `filePath.test.ts:17-24` "normalizes repeated separators".
    func testRepeatedSeparatorsCollapse() {
        XCTAssertEqual(T3FilePreview.breadcrumbs(projectName: "workspace", path: "src//index.ts")
                        .map(\.label), ["workspace", "src", "index.ts"])
    }

    /// A file at the project root is the project plus itself.
    func testAFileAtTheRootIsTwoCrumbs() {
        let crumbs = T3FilePreview.breadcrumbs(projectName: "limitless", path: "README.md")
        XCTAssertEqual(crumbs.map(\.kind), [.project, .file])
        XCTAssertEqual(crumbs.last?.path, "README.md")
    }

    /// No path at all is the project alone — the header's state before a click.
    func testNoPathIsTheProjectAlone() {
        XCTAssertEqual(T3FilePreview.breadcrumbs(projectName: "limitless", path: ""),
                       [.init(label: "limitless", path: "", kind: .project)])
    }

    // MARK: - split

    func testEveryLineKeepsItsNumberIncludingTheBlankOnes() {
        XCTAssertEqual(T3FilePreview.split("a\n\nb").lines, ["a", "", "b"])
    }

    /// A trailing newline ends the last line; it does not start a phantom one.
    func testATrailingNewlineDoesNotAddALine() {
        XCTAssertEqual(T3FilePreview.split("a\nb\n").lines, ["a", "b"])
        XCTAssertEqual(T3FilePreview.split("a\n\n").lines, ["a", ""])
    }

    func testAFileOfOneNewlineIsOneEmptyLine() {
        XCTAssertEqual(T3FilePreview.split("\n").lines, [""])
    }

    func testAnEmptyFileHasNoLines() {
        let slice = T3FilePreview.split("")
        XCTAssertEqual(slice.lines, [])
        XCTAssertFalse(slice.trimmed)
    }

    /// A CRLF file breaks like any other, and no `\r` survives into a line.
    func testCarriageReturnsGoWithTheirNewlines() {
        XCTAssertEqual(T3FilePreview.split("a\r\nb\r\n").lines, ["a", "b"])
        XCTAssertEqual(T3FilePreview.split("a\rb").lines, ["a", "b"])
    }

    func testTheLineCapCutsTheFileAndSaysSo() {
        let slice = T3FilePreview.split(String(repeating: "x\n", count: 10), lineCap: 4)
        XCTAssertEqual(slice.lines, ["x", "x", "x", "x"])
        XCTAssertTrue(slice.trimmed)
    }

    /// Exactly the cap, terminator and all, is not trimmed: the newline that
    /// ends the last line is not a line of its own.
    func testAFileOfExactlyTheCapIsNotTrimmed() {
        let slice = T3FilePreview.split(String(repeating: "x\n", count: 4), lineCap: 4)
        XCTAssertEqual(slice.lines.count, 4)
        XCTAssertFalse(slice.trimmed)
    }

    // MARK: - The states' copy

    func testTheBinaryCopyNamesTheFileAndTheWorkspace() {
        XCTAssertEqual(T3FilePreview.message(for: .binary, path: "logo.png", root: "/w"),
                       "Workspace file 'logo.png' in '/w' is binary and cannot be previewed as text.")
    }

    func testTheMissingCopyIsTheReadFailureSaidOnce() {
        XCTAssertEqual(T3FilePreview.message(for: .notFound, path: "gone.txt", root: "/w"),
                       "Failed to read workspace file 'gone.txt' in '/w'.")
    }

    func testAPathOutsideTheWorkspaceSaysSo() {
        XCTAssertEqual(T3FilePreview.message(for: .outsideRoot, path: "../etc/passwd", root: "/w"),
                       "Workspace file '../etc/passwd' resolves outside workspace root '/w'.")
    }

    /// Anything else is the route's own message, as `{file.error}` renders it.
    func testAnyOtherFailureIsItsOwnMessage() {
        XCTAssertEqual(T3FilePreview.message(for: .failed("cannot open x"), path: "x", root: "/w"),
                       "cannot open x")
    }

    // MARK: - limitNotice

    func testTheByteNoticeCarriesTheCapAndTheWholeSize() {
        XCTAssertEqual(T3FilePreview.limitNotice(byteLength: 1_234_567, truncated: true, trimmed: false,
                                                 locale: Locale(identifier: "en_US")),
                       "Preview limited to the first 256 KB of a 1,234,567 byte file.")
    }

    /// The cap in the sentence follows the cap that was applied.
    func testTheNoticeFollowsTheCapItWasGiven() {
        XCTAssertEqual(T3FilePreview.limitNotice(byteLength: 200_000, truncated: true, trimmed: false,
                                                 cap: 64 * 1024, locale: Locale(identifier: "en_US")),
                       "Preview limited to the first 64 KB of a 200,000 byte file.")
    }

    func testALineCappedFileGetsTheLineNotice() {
        XCTAssertEqual(T3FilePreview.limitNotice(byteLength: 4_000, truncated: false, trimmed: true,
                                                 lineCap: 20_000, locale: Locale(identifier: "en_US")),
                       "Preview limited to the first 20,000 lines.")
    }

    func testAWholeFileHasNoNotice() {
        XCTAssertNil(T3FilePreview.limitNotice(byteLength: 12, truncated: false, trimmed: false))
    }
}
