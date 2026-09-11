import XCTest
@testable import InfinitusCore

#if !os(Windows)
/// Per-turn checkpoints (#167) against a throwaway repository.
final class CheckpointsTests: XCTestCase {
    var repo: URL!
    let git = GitRunner()

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-ckpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try git.run(["init", "-q"], cwd: repo.path)
        try git.run(["config", "user.email", "t@t"], cwd: repo.path)
        try git.run(["config", "user.name", "t"], cwd: repo.path)
        try write("src/a.txt", "a\n")
        try write(".gitignore", "*.log\n")
        try git.run(["add", "-A"], cwd: repo.path)
        try git.run(["commit", "-qm", "base"], cwd: repo.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    /// Symlinks resolved, no trailing slash — Linux's URL keeps one on
    /// directories, macOS's does not.
    private func realPath(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    func testSnapshotsAreHiddenRefsThatLeaveStatusAlone() throws {
        try write("src/a.txt", "a2\n")
        try write("src/new.txt", "new\n")
        try write("debug.log", "ignored\n")
        // From a subfolder: the snapshot covers the whole repository.
        let c1 = try XCTUnwrap(Checkpoints.snapshot(cwd: repo.appendingPathComponent("src").path, sessionId: "s1",
                                                    subject: "Fix the crash\nmore detail"))
        XCTAssertEqual(c1.n, 1)
        XCTAssertEqual(c1.subject, "#1 Fix the crash")
        XCTAssertEqual(realPath(c1.root), realPath(repo.path))
        XCTAssertEqual(try git.run(["status", "--short"], cwd: repo.path).split(separator: "\n").map(String.init).sorted(),
                       [" M src/a.txt", "?? src/new.txt"])   // index untouched, .log stayed ignored
        XCTAssertEqual(try git.run(["branch", "--list"], cwd: repo.path).contains("infinitus"), false)
        let files = try git.run(["ls-tree", "-r", "--name-only", c1.sha], cwd: repo.path)
        XCTAssertTrue(files.contains("src/new.txt"))
        XCTAssertFalse(files.contains("debug.log"))
        // Nothing changed: the same checkpoint comes back, no new ref.
        XCTAssertEqual(try Checkpoints.snapshot(cwd: repo.path, sessionId: "s1", subject: "again"), c1)
        XCTAssertEqual(try Checkpoints.list(cwd: repo.path, sessionId: "s1").map(\.n), [1])
        // Another session in the same repository keeps its own numbering.
        try write("src/a.txt", "a3\n")
        let other = try XCTUnwrap(Checkpoints.snapshot(cwd: repo.path, sessionId: "s2", subject: "other"))
        XCTAssertEqual(other.n, 1)
        XCTAssertEqual(try Checkpoints.list(cwd: repo.path, sessionId: "s1").map(\.n), [1])
    }

    func testDiffAndRestoreRoundTrip() throws {
        try write("src/a.txt", "one\n")
        let c1 = try XCTUnwrap(Checkpoints.snapshot(cwd: repo.path, sessionId: "s", subject: "turn one"))
        try write("src/a.txt", "two\n")
        try write("src/b.txt", "b\n")
        let c2 = try XCTUnwrap(Checkpoints.snapshot(cwd: repo.path, sessionId: "s", subject: "turn two"))
        XCTAssertEqual([c1.n, c2.n], [1, 2])

        let between = try Checkpoints.diff(cwd: repo.path, sessionId: "s", from: 1, to: 2)
        XCTAssertTrue(between.stat.contains("src/a.txt") && between.stat.contains("src/b.txt"), between.stat)
        XCTAssertTrue(between.patch.contains("-one") && between.patch.contains("+two"))
        XCTAssertFalse(between.truncated)

        try write("src/untracked.txt", "u\n")
        let live = try Checkpoints.diff(cwd: repo.path, sessionId: "s", from: 2, to: nil)
        XCTAssertTrue(live.stat.contains("src/untracked.txt"), "worktree diff sees untracked files: \(live.stat)")

        let (restored, backup) = try Checkpoints.restore(cwd: repo.path, sessionId: "s", n: 1)
        XCTAssertEqual(restored.n, 1)
        XCTAssertEqual(backup?.n, 3)                      // the state before the restore, kept
        XCTAssertEqual(backup?.subject, "#3 before restoring #1")
        XCTAssertEqual(read("src/a.txt"), "one\n")
        XCTAssertNil(read("src/b.txt"))                    // tracked at #2, gone at #1
        XCTAssertNil(read("src/untracked.txt"))            // born after #1: gone, but kept in the backup
        XCTAssertTrue(try git.run(["ls-tree", "-r", "--name-only", backup!.sha], cwd: repo.path).contains("src/untracked.txt"))
        XCTAssertEqual(try git.run(["status", "--short"], cwd: repo.path).contains("src/a.txt"), true) // vs HEAD: a.txt differs
        XCTAssertThrowsError(try Checkpoints.restore(cwd: repo.path, sessionId: "s", n: 9))
    }

    func testAWorktreeOfTheSameCloneIsDiffedAndRestoredWhereItWasTaken() throws {
        // The session's record says the main checkout; the prompt lands in
        // a worktree of the same clone. The checkpoint remembers the
        // worktree, so a diff "vs now" and a restore act there.
        let wt = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + "-wt")
        defer { try? FileManager.default.removeItem(at: wt) }
        try git.run(["worktree", "add", "-q", "--detach", wt.path], cwd: repo.path)
        try "wt\n".write(to: wt.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        let c1 = try XCTUnwrap(Checkpoints.snapshot(cwd: wt.path, sessionId: "s", subject: "in the worktree"))
        XCTAssertEqual(realPath(c1.root), realPath(wt.path))
        // Looked up from the main checkout: found (shared refs), and the
        // live diff compares against the WORKTREE, which is unchanged.
        let listed = try Checkpoints.list(cwd: repo.path, sessionId: "s")
        XCTAssertEqual(listed.map(\.n), [1])
        XCTAssertEqual(try Checkpoints.diff(cwd: repo.path, sessionId: "s", from: 1, to: nil).stat, "")
        try "wt2\n".write(to: wt.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try Checkpoints.diff(cwd: repo.path, sessionId: "s", from: 1, to: nil).stat.contains("src/a.txt"))
        _ = try Checkpoints.restore(cwd: repo.path, sessionId: "s", n: 1)
        XCTAssertEqual(try String(contentsOf: wt.appendingPathComponent("src/a.txt"), encoding: .utf8), "wt\n")
        XCTAssertEqual(read("src/a.txt"), "a\n")   // the main checkout was never touched
    }

    func testReplyEmptyReasonNamesTheMissingPrecondition() throws {
        // A Mac older than the fields decodes with them nil and gets the
        // generic reason.
        let legacy = try JSONDecoder().decode(
            Checkpoints.Reply.self, from: Data(#"{"sessionId":"s","cwd":"/w/app","checkpoints":[]}"#.utf8))
        XCTAssertNil(legacy.enabled)
        XCTAssertTrue(legacy.emptyReason.hasPrefix("No checkpoints yet"))
        XCTAssertTrue(Checkpoints.Reply(sessionId: "s", cwd: "/w/app", checkpoints: [], enabled: false, inGit: true)
                        .emptyReason.hasPrefix("Checkpoints are off on the Mac"))
        XCTAssertEqual(Checkpoints.Reply(sessionId: "s", cwd: "/w/app", checkpoints: [], enabled: true, inGit: false)
                        .emptyReason, "app isn't inside a git repository, and checkpoints need one.")
        XCTAssertTrue(Checkpoints.Reply(sessionId: "s", cwd: "/w/app", checkpoints: [], enabled: true, inGit: true)
                        .emptyReason.hasPrefix("No checkpoints yet"))
    }

    func testOutsideARepositoryIsNil() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("infinitus-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertNil(try Checkpoints.snapshot(cwd: plain.path, sessionId: "s", subject: "x"))
        XCTAssertEqual(try Checkpoints.list(cwd: plain.path, sessionId: "s"), [])
    }
}
#endif
