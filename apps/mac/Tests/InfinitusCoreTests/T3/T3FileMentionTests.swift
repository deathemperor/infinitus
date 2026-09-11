import XCTest
@testable import InfinitusCore

/// The `@` menu's file source and its ranking: `git ls-files` with a bounded
/// walk behind it, and `scoreQueryMatch` / `scoreSubsequenceMatch`
/// (`packages/shared/src/searchRanking.ts:22-136`) over the tiers the file
/// tree uses (`apps/mobile/src/features/files/fileTree.ts:130-143`).
final class T3FileMentionTests: XCTestCase {

    // MARK: - rank

    func testTheExactFilenameOutranksAPrefixWhichOutranksASubsequence() {
        let paths = ["c/a-p-p.swift", "b/apple.swift", "a/app"]
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "app"),
                       ["a/app", "b/apple.swift", "c/a-p-p.swift"])
    }

    func testRankingIsCaseInsensitive() {
        let paths = ["Sources/App.swift"]
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "APP"), paths)
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "app.SWIFT"), paths)
    }

    /// A query with a separator in it reaches the directory part
    /// (`includesBase` on the whole relative path).
    func testAQueryWithASeparatorMatchesTheDirectory() {
        let paths = ["Sources/T3/ComposerView.swift", "Tests/Other.swift"]
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "t3/comp"),
                       ["Sources/T3/ComposerView.swift"])
    }

    func testANonMatchingQueryDropsThePath() {
        XCTAssertEqual(T3FileMention.rank(paths: ["a/app"], query: "zzz"), [])
    }

    /// `normalizeSearchQuery` (`searchRanking.ts:81-83`): no query keeps the
    /// list as it came in, cut to the limit.
    func testAnEmptyQueryKeepsTheInputOrder() {
        let paths = (1...20).map { "f\($0).swift" }
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: ""), Array(paths.prefix(12)))
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "   "), Array(paths.prefix(12)))
    }

    func testTheLimitIsRespected() {
        let paths = (1...20).map { "app\($0).swift" }
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "app", limit: 3).count, 3)
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "app").count, 12)
    }

    /// `insertRankedSearchResult` keeps the best-ranked candidates within the
    /// limit (`searchRanking.test.ts:81-92`) — a worse score never displaces a
    /// better one.
    func testTheLimitKeepsTheBestRankedPaths() {
        let paths = ["deep/nested/appliance-registry.swift", "app.swift", "b/apple.swift"]
        XCTAssertEqual(T3FileMention.rank(paths: paths, query: "app", limit: 2),
                       ["app.swift", "b/apple.swift"])
    }

    /// `compareRankedSearchResults` (`searchRanking.ts:138-145`): the path is
    /// the tie-breaker.
    func testEqualScoresBreakOnThePath() {
        XCTAssertEqual(T3FileMention.rank(paths: ["b/x.swift", "a/x.swift"], query: "x.swift"),
                       ["a/x.swift", "b/x.swift"])
    }

    // MARK: - The scoring primitives (transcribed from `searchRanking.test.ts`)

    /// `searchRanking.test.ts:21-42`.
    func testScoreQueryMatchPrefersExactMatchesOverBroaderContainsMatches() {
        XCTAssertEqual(T3FileMention.scoreQueryMatch(value: "ui", query: "ui", exactBase: 0,
                                                     prefixBase: 10, includesBase: 20), 0)
        let contains = T3FileMention.scoreQueryMatch(value: "building native ui", query: "ui",
                                                     exactBase: 0, prefixBase: 10,
                                                     boundaryBase: 20, includesBase: 30)
        XCTAssertNotNil(contains)
        XCTAssertGreaterThan(contains ?? 0, 0)
    }

    /// `searchRanking.test.ts:44-67`.
    func testScoreQueryMatchTreatsBoundaryMatchesAsStrongerThanContainsMatches() {
        let boundary = T3FileMention.scoreQueryMatch(value: "gh-fix-ci", query: "fix", exactBase: 0,
                                                     prefixBase: 10, boundaryBase: 20,
                                                     includesBase: 30, boundaryMarkers: ["-"])
        let contains = T3FileMention.scoreQueryMatch(value: "highfixci", query: "fix", exactBase: 0,
                                                     prefixBase: 10, boundaryBase: 20,
                                                     includesBase: 30, boundaryMarkers: ["-"])
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(contains)
        XCTAssertLessThan(boundary ?? 0, contains ?? 0)
    }

    /// `searchRanking.test.ts:70-79`.
    func testScoreSubsequenceMatchScoresTighterSubsequencesAhead() {
        let compact = T3FileMention.scoreSubsequenceMatch("ghfixci", "gfc")
        let spread = T3FileMention.scoreSubsequenceMatch("github-fix-ci", "gfc")
        XCTAssertNotNil(compact)
        XCTAssertNotNil(spread)
        XCTAssertLessThan(compact ?? 0, spread ?? 0)
    }

    func testScoreQueryMatchAnswersNothingForAnEmptyValueOrQuery() {
        XCTAssertNil(T3FileMention.scoreQueryMatch(value: "", query: "ui", exactBase: 0))
        XCTAssertNil(T3FileMention.scoreQueryMatch(value: "ui", query: "", exactBase: 0))
    }

    // MARK: - list / walk

    private func tree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-mention-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTheWalkSkipsTheBuildAndVendorDirectoriesAndReturnsRelativePaths() throws {
        let root = try tree(["README.md", "Sources/a.swift", ".gitignore",
                             ".git/config", "node_modules/pkg/index.js", ".build/debug/x.o"])
        XCTAssertEqual(T3FileMention.walk(cwd: root.path).sorted(),
                       [".gitignore", "README.md", "Sources/a.swift"])
    }

    func testTheWalkIsCapped() throws {
        let root = try tree(["a.swift", "b.swift", "c.swift"])
        XCTAssertEqual(T3FileMention.walk(cwd: root.path, maxEntries: 2).count, 2)
    }

    func testTheWalkOfAMissingDirectoryIsEmpty() {
        XCTAssertEqual(T3FileMention.walk(cwd: "/nope/not/here"), [])
    }

    /// End to end on a tree with no `.git` in it: `git ls-files` fails there,
    /// so the walk answers.
    func testListFallsBackToTheWalkOutsideARepository() throws {
        let root = try tree(["README.md", "Sources/a.swift"])
        XCTAssertEqual(T3FileMention.list(cwd: root.path).sorted(),
                       ["README.md", "Sources/a.swift"])
    }

    /// Claude Code's own mention syntax is the bare path — not upstream's
    /// markdown link (`serializeComposerFileLink`, `composerTrigger.ts:29-32`).
    func testTheInsertionIsTheAtPathAndASpace() {
        XCTAssertEqual(T3FileMention.insertion(for: "Sources/a.swift"), "@Sources/a.swift ")
    }

    /// `composerMentionFromTreePath` (`composerMentionDrag.ts:10-16`): the
    /// mention on its own, no trailing space — what "Copy mention" copies
    /// (`FileBrowserPanel.tsx:164`).
    func testTheMentionForAFilesTreePathHasNoTrailingSpace() {
        XCTAssertEqual(T3FileMention.mention(forTreePath: "Sources/a.swift"), "@Sources/a.swift")
    }

    /// A folder's tree path ends in `/` upstream (`treePath`,
    /// `FileBrowserPanel.tsx:42-44`) and its mention never does (`:145`).
    func testAFoldersTrailingSlashesAreDropped() {
        XCTAssertEqual(T3FileMention.mention(forTreePath: "Sources/"), "@Sources")
        XCTAssertEqual(T3FileMention.mention(forTreePath: "Sources//"), "@Sources")
    }

    func testAPathOfNothingButSeparatorsHasNoMention() {
        XCTAssertNil(T3FileMention.mention(forTreePath: ""))
        XCTAssertNil(T3FileMention.mention(forTreePath: "/"))
    }
}
