import XCTest
@testable import InfinitusCore

/// The Diff tab's model over one fixed patch, plus upstream's own cases for
/// the changed-files tree (`apps/web/src/components/diffs/
/// diffFileTree.logic.test.ts`) and the stat label
/// (`apps/web/src/components/chat/DiffStatLabel.tsx:8-20`).
final class T3DiffModelTests: XCTestCase {

    /// A `git diff` between two trees with one of every shape in it: a change
    /// with two hunks, a new file, a deletion, a pure rename, a rename with an
    /// edit, and a binary file.
    private let patch = """
    diff --git a/README.md b/README.md
    index 8b13789..1e4bfd8 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,4 +1,5 @@ Title
     # Infinitus
    -old tagline
    +new tagline
    +a second line
     \n\
     ## Build
    @@ -20,3 +21,3 @@ func build()
     make
    -swift build --target X
    +swift build --product Infinitus
    diff --git a/src/new.swift b/src/new.swift
    new file mode 100644
    index 0000000..3f2a1cd
    --- /dev/null
    +++ b/src/new.swift
    @@ -0,0 +1,2 @@
    +import Foundation
    +let answer = 42
    \\ No newline at end of file
    diff --git a/src/gone.swift b/src/gone.swift
    deleted file mode 100644
    index 3f2a1cd..0000000
    --- a/src/gone.swift
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -import Foundation
    -let old = 1
    diff --git a/docs/old.md b/docs/notes/new.md
    similarity index 100%
    rename from docs/old.md
    rename to docs/notes/new.md
    diff --git a/src/moved.swift b/src/lib/moved.swift
    similarity index 92%
    rename from src/moved.swift
    rename to src/lib/moved.swift
    index 1111111..2222222 100644
    --- a/src/moved.swift
    +++ b/src/lib/moved.swift
    @@ -3 +3 @@
    -let n = 1
    +let n = 2
    diff --git a/assets/icon.png b/assets/icon.png
    index 4444444..5555555 100644
    Binary files a/assets/icon.png and b/assets/icon.png differ

    """

    private func parsed() -> [T3DiffModel.File] { T3DiffModel.parse(patch) }

    // MARK: - Files

    func testEveryFileInThePatchIsReadInItsOwnOrder() {
        XCTAssertEqual(parsed().map(\.path),
                       ["README.md", "src/new.swift", "src/gone.swift", "docs/notes/new.md",
                        "src/lib/moved.swift", "assets/icon.png"])
    }

    /// The five `FileDiffMetadata["type"]` values `diffFileTree.logic.ts:12-24`
    /// switches over — a rename with no hunk is pure, one with a hunk is not.
    func testEachFilesKindComesFromItsHeader() {
        XCTAssertEqual(parsed().map(\.kind),
                       [.modified, .added, .deleted, .renamedPure, .renamedChanged, .modified])
    }

    func testARenameKeepsBothNamesAndAPlainChangeKeepsOne() {
        let files = parsed()
        XCTAssertEqual(files[3].previousPath, "docs/old.md")
        XCTAssertEqual(files[3].path, "docs/notes/new.md")
        XCTAssertEqual(files[3].key, "docs/old.md\u{0}docs/notes/new.md")
        XCTAssertEqual(files[0].key, "README.md\u{0}README.md")
    }

    /// `--- /dev/null` / `+++ /dev/null` leave only the side that exists.
    func testAnAddedOrDeletedFileTakesTheNameOfTheSideItHas() {
        let files = parsed()
        XCTAssertEqual(files[1].path, "src/new.swift")
        XCTAssertEqual(files[1].previousPath, "src/new.swift")
        XCTAssertEqual(files[2].path, "src/gone.swift")
    }

    func testABinaryFileHasNoLinesToShow() {
        let binary = parsed()[5]
        XCTAssertTrue(binary.isBinary)
        XCTAssertTrue(binary.hunks.isEmpty)
    }

    // MARK: - Hunks and lines

    func testAHunkKeepsItsRangesAndTheHeadingGitWroteAfterTheAtSigns() {
        let hunks = parsed()[0].hunks
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual([hunks[0].oldStart, hunks[0].oldCount, hunks[0].newStart, hunks[0].newCount],
                       [1, 4, 1, 5])
        XCTAssertEqual(hunks[0].heading, "Title")
        XCTAssertEqual(hunks[1].heading, "func build()")
    }

    /// A count of 1 may be left out of the range (`@@ -3 +3 @@`).
    func testAnOmittedCountIsOne() {
        let hunk = parsed()[4].hunks[0]
        XCTAssertEqual([hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount], [3, 1, 3, 1])
    }

    /// `collapsedBefore` (`diffRendering.ts:209`): the unmodified lines skipped
    /// before the hunk, which the separator row counts out.
    func testEachHunkCountsTheLinesSkippedBeforeIt() {
        let hunks = parsed()[0].hunks
        XCTAssertEqual(hunks[0].collapsedBefore, 0)          // starts at line 1
        XCTAssertEqual(hunks[1].collapsedBefore, 15)         // 20 - (1 + 4)
        XCTAssertEqual(parsed()[4].hunks[0].collapsedBefore, 2)
    }

    func testEveryLineCarriesItsKindItsNumbersAndItsTextWithoutTheMarker() {
        let lines = parsed()[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.kind),
                       [.context, .deletion, .addition, .addition, .context, .context])
        XCTAssertEqual(lines.map(\.text),
                       ["# Infinitus", "old tagline", "new tagline", "a second line", "", "## Build"])
        XCTAssertEqual(lines.map(\.oldNumber), [1, 2, nil, nil, 3, 4])
        XCTAssertEqual(lines.map(\.newNumber), [1, nil, 2, 3, 4, 5])
    }

    func testTheNoNewlineMarkerLandsOnTheLineBeforeIt() {
        let lines = parsed()[1].hunks[0].lines
        XCTAssertEqual(lines.map(\.noNewlineAtEnd), [false, true])
    }

    /// Nothing is validated against the `@@` header: a patch cut mid-line at
    /// `Checkpoints.patchCap` still yields every file before the cut.
    func testATruncatedPatchKeepsEverythingBeforeTheCut() {
        let start = patch.range(of: "diff --git a/assets")!.lowerBound
        // 60 characters past the last file's header: its `index` line is cut
        // in half, so only the `diff --git` names are left to go on.
        let cut = String(patch.prefix(patch.distance(from: patch.startIndex, to: start) + 60))
        let files = T3DiffModel.parse(cut)
        XCTAssertEqual(files.map(\.path),
                       ["README.md", "src/new.swift", "src/gone.swift", "docs/notes/new.md",
                        "src/lib/moved.swift", "assets/icon.png"])
        XCTAssertEqual(files.last?.hunks.count, 0)
    }

    /// The patch ends with a newline, and the empty string after it is not a
    /// context line (`getRenderablePatch` trims first, `diffRendering.ts:115`).
    func testTheNewlineEndingThePatchAddsNoLine() {
        let hunk = T3DiffModel.parse("""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         kept
        -old
        +new

        """).first?.hunks.first
        XCTAssertEqual(hunk?.lines.map(\.text), ["kept", "old", "new"])
    }

    func testTextThatIsNotAPatchIsNoFiles() {
        XCTAssertTrue(T3DiffModel.parse("").isEmpty)
        XCTAssertTrue(T3DiffModel.parse("fatal: not a git repository").isEmpty)
    }

    // MARK: - Stats

    /// `getDiffLineStat` (`diffRendering.ts:60-72`) counts every hunk of every
    /// file.
    func testTheStatAddsUpEveryHunkOfEveryFile() {
        let files = parsed()
        XCTAssertEqual(files[0].additions, 3)
        XCTAssertEqual(files[0].deletions, 2)
        let stat = T3DiffModel.stat(files)
        XCTAssertEqual(stat.additions, 6)
        XCTAssertEqual(stat.deletions, 5)
    }

    /// `formatCompactDiffCount` (`DiffStatLabel.tsx:8-20`).
    func testTheStatLabelCompactsThousands() {
        XCTAssertEqual(T3DiffModel.compactCount(0), "0")
        XCTAssertEqual(T3DiffModel.compactCount(999), "999")
        XCTAssertEqual(T3DiffModel.compactCount(1_000), "1k")
        XCTAssertEqual(T3DiffModel.compactCount(1_250), "1.3k")
        XCTAssertEqual(T3DiffModel.compactCount(12_400), "12k")
        XCTAssertEqual(T3DiffModel.compactCount(1_000_000), "1m")
        XCTAssertEqual(T3DiffModel.compactCount(2_500_000_000), "2.5b")
    }

    /// `DiffPanel.tsx:412-417`: digits read as numbers, case ignored.
    func testTheFilesSortByPathTheWayThePanelShowsThem() {
        let files = T3DiffModel.parse(patch)
        XCTAssertEqual(T3DiffModel.sortedByPath(files).map(\.path),
                       ["assets/icon.png", "docs/notes/new.md", "README.md",
                        "src/gone.swift", "src/lib/moved.swift", "src/new.swift"])
    }

    // MARK: - The changed-files tree

    /// `diffFileTree.logic.test.ts:15-31` "maps each change type to its git
    /// status under the file's current path".
    func testEachChangeTypeMapsToItsGitStatusUnderTheFilesCurrentPath() {
        let files = [
            T3DiffModel.File(path: "src/a.ts", previousPath: "src/a.ts", kind: .added, hunks: []),
            T3DiffModel.File(path: "src/b.ts", previousPath: "src/b.ts", kind: .deleted, hunks: []),
            T3DiffModel.File(path: "src/c.ts", previousPath: "src/old-c.ts", kind: .renamedPure, hunks: []),
            T3DiffModel.File(path: "src/d.ts", previousPath: "src/old-d.ts", kind: .renamedChanged, hunks: []),
            T3DiffModel.File(path: "README.md", previousPath: "README.md", kind: .modified, hunks: []),
        ]
        XCTAssertEqual(T3DiffModel.entries(files).map { "\($0.path):\($0.status.rawValue)" },
                       ["src/a.ts:added", "src/b.ts:deleted", "src/c.ts:renamed",
                        "src/d.ts:renamed", "README.md:modified"])
    }

    /// `:34-42` "lists every ancestor once, parents first" — upstream's
    /// trailing slash is `@pierre/trees`'s directory id and is dropped here.
    func testEveryAncestorIsListedOnceParentsFirst() {
        XCTAssertEqual(T3DiffModel.directoryPaths(["apps/web/src/a.ts", "apps/web/b.ts", "README.md"]),
                       ["apps", "apps/web", "apps/web/src"])
    }

    /// The four cases of `buildDiffFileTreeUpdates` (`:44-69`), as what they
    /// are for: the expansion a changed path list carries over.
    func testANewFilesFoldersArriveOpen() {
        let previous = T3DiffModel.directoryPaths(["README.md"])
        let next = T3DiffModel.directoryPaths(["README.md", "src/lib/a.ts"])
        XCTAssertEqual(T3DiffModel.carryExpansion(previous: previous, next: next, expanded: []),
                       ["src", "src/lib"])
    }

    func testAFolderThatLeftTheDiffLeavesTheExpansion() {
        let previous = T3DiffModel.directoryPaths(["src/lib/a.ts", "src/b.ts"])
        let next = T3DiffModel.directoryPaths(["src/b.ts"])
        XCTAssertEqual(T3DiffModel.carryExpansion(previous: previous, next: next,
                                                  expanded: ["src", "src/lib"]),
                       ["src"])
    }

    func testAFolderThatStillHoldsAFileKeepsTheStateTheReaderPutItIn() {
        let paths = T3DiffModel.directoryPaths(["src/a.ts", "src/b.ts"])
        XCTAssertEqual(T3DiffModel.carryExpansion(previous: paths, next: paths, expanded: []), [])
        XCTAssertEqual(T3DiffModel.carryExpansion(previous: paths, next: paths, expanded: ["src"]),
                       ["src"])
    }

    func testAnUnchangedPathListChangesNothing() {
        let paths = T3DiffModel.directoryPaths(["src/a.ts"])
        XCTAssertEqual(T3DiffModel.carryExpansion(previous: paths, next: paths, expanded: ["src"]),
                       ["src"])
    }
}
