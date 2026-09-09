import XCTest
@testable import InfinitusCore

final class T3GitFactsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3gitfacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: URL) -> String? {
        T3GitFacts.run(["git"] + arguments, cwd: directory.path)
    }

    func testReadsTheCheckedOutBranch() throws {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        throw XCTSkip("no child processes on this platform")
        #else
        guard T3GitFacts.run(["git", "--version"], cwd: root.path) != nil else {
            throw XCTSkip("git is not on PATH")
        }
        git(["init", "-q", "-b", "trunk"], at: root)
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], at: root)
        XCTAssertEqual(T3GitFacts.branch(cwd: root.path), "trunk")

        git(["checkout", "-q", "-b", "feature/one"], at: root)
        XCTAssertEqual(T3GitFacts.branch(cwd: root.path), "feature/one")
        #endif
    }

    func testNoBranchOutsideAWorkTree() throws {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        throw XCTSkip("no child processes on this platform")
        #else
        XCTAssertNil(T3GitFacts.branch(cwd: root.path))
        XCTAssertNil(T3GitFacts.branch(cwd: root.appendingPathComponent("missing").path))
        #endif
    }

    /// A detached HEAD has no branch to name — `--abbrev-ref` answers `HEAD`,
    /// which must not reach the strip as a label.
    func testDetachedHeadHasNoBranch() throws {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        throw XCTSkip("no child processes on this platform")
        #else
        guard T3GitFacts.run(["git", "--version"], cwd: root.path) != nil else {
            throw XCTSkip("git is not on PATH")
        }
        git(["init", "-q", "-b", "trunk"], at: root)
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], at: root)
        guard let sha = T3GitFacts.run(["git", "rev-parse", "HEAD"], cwd: root.path)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return XCTFail("no HEAD") }
        git(["checkout", "-q", sha], at: root)
        XCTAssertNil(T3GitFacts.branch(cwd: root.path))
        #endif
    }

    func testWorkspaceLabel() {
        XCTAssertEqual(T3GitFacts.workspaceLabel(worktreePath: nil), "Local checkout")
        XCTAssertEqual(T3GitFacts.workspaceLabel(worktreePath: "/tmp/wt"), "Worktree")
    }
}
