import XCTest
@testable import InfinitusCore

final class TeamGitTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("teamgit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// TeamGit shells out through `/usr/bin/env git` — macOS/Linux only
    /// until Windows grows a PATH-resolved git shim (upstream, Team).
    func skipOffPOSIX() throws {
        #if os(Windows)
        try XCTSkipIf(true, "Team git shellouts are POSIX-only; not ported to Windows yet")
        #endif
    }

    /// A bare repo standing in for the team's remote.
    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return "file://" + bare.path
    }

    func testPathsMapToBranches() {
        XCTAssertEqual(StorePath.branch(of: "roster/team.json")?.branch, "roster")
        XCTAssertEqual(StorePath.branch(of: "roster/team.json")?.rest, "team.json")
        XCTAssertEqual(StorePath.branch(of: "requests/abc.json")?.branch, "requests")
        XCTAssertEqual(StorePath.branch(of: "m/abc/days/2026-09-05.json")?.branch, "m/abc")
        XCTAssertEqual(StorePath.branch(of: "m/abc/days/2026-09-05.json")?.rest, "days/2026-09-05.json")
        XCTAssertNil(StorePath.branch(of: "m/abc"))
        XCTAssertNil(StorePath.branch(of: "other/x"))
        XCTAssertNil(StorePath.branch(of: "roster/../x"))
    }

    func testTwoClonesExchangeFilesThroughTheRemote() throws {
        try skipOffPOSIX()
        let remote = try makeRemote()
        let a = TeamGit(dir: scratch.appendingPathComponent("a"), remote: remote, token: nil, author: "kid-a")
        let b = TeamGit(dir: scratch.appendingPathComponent("b"), remote: remote, token: nil, author: "kid-b")
        try a.open(); try b.open()

        XCTAssertEqual(try a.list(""), [])
        try a.put("roster/team.json", Data("{\"rev\":1}".utf8))
        try a.putAll(["m/kid-a/days/1.json": Data("d1".utf8), "m/kid-a/now.json": Data("n".utf8)])

        try b.sync()
        XCTAssertEqual(try b.get("roster/team.json"), Data("{\"rev\":1}".utf8))
        XCTAssertEqual(try b.list("m/kid-a/").map(\.path).sorted(), ["m/kid-a/days/1.json", "m/kid-a/now.json"])
        XCTAssertEqual(try b.list("m/kid-a/days/").map(\.size), [2])
        XCTAssertNil(try b.get("m/kid-a/missing.json"))
        XCTAssertNil(try b.get("m/nobody/x.json"))

        // b writes its own branch; a sees it after a sync, and the cursor moves.
        let (initial, cursor1) = try a.changes(since: nil)
        XCTAssertEqual(Set(initial.map(\.path)), ["roster/team.json", "m/kid-a/days/1.json", "m/kid-a/now.json"])
        try b.put("m/kid-b/now.json", Data("b".utf8))
        try b.put("requests/kid-b.json", Data("r".utf8))
        try a.sync()
        let (delta, cursor2) = try a.changes(since: cursor1)
        XCTAssertEqual(Set(delta.map(\.path)), ["m/kid-b/now.json", "requests/kid-b.json"])
        XCTAssertNotEqual(cursor1, cursor2)
        XCTAssertEqual(try a.changes(since: cursor2).0, [])

        // Overwrite and delete.
        try a.put("m/kid-a/now.json", Data("n2".utf8))
        try a.delete("m/kid-a/days/1.json")
        try b.sync()
        XCTAssertEqual(try b.get("m/kid-a/now.json"), Data("n2".utf8))
        XCTAssertEqual(try b.list("m/kid-a/").map(\.path), ["m/kid-a/now.json"])
        let (delta2, _) = try b.changes(since: cursor2)
        XCTAssertTrue(delta2.contains { $0.path == "m/kid-a/now.json" })

        // Concurrent writers on the same branch: the second push retries on top of the first.
        let a2 = TeamGit(dir: scratch.appendingPathComponent("a2"), remote: remote, token: nil, author: "kid-a")
        try a2.open()
        try a.put("m/kid-a/x.json", Data("x".utf8))
        try a2.put("m/kid-a/y.json", Data("y".utf8))
        try b.sync()
        XCTAssertEqual(try b.list("m/kid-a/").map(\.path).sorted(), ["m/kid-a/now.json", "m/kid-a/x.json", "m/kid-a/y.json"])
    }

    func testBadPathsAreRefused() throws {
        try skipOffPOSIX()
        let g = TeamGit(dir: scratch.appendingPathComponent("g"), remote: try makeRemote(), token: nil, author: "k")
        try g.open()
        XCTAssertThrowsError(try g.put("nope/x", Data()))
        XCTAssertThrowsError(try g.put("m/k/../../x", Data()))
        XCTAssertThrowsError(try g.put("m/k/.git/config", Data()))
    }

    /// I1: rebuilding the same bytes on the winner's tip is a blind
    /// overwrite for read-modify-write objects like the roster.
    func testALostRaceIsReportedWhenRetryIsOff() throws {
        try skipOffPOSIX()
        let remote = try makeRemote()
        let a = TeamGit(dir: scratch.appendingPathComponent("r-a"), remote: remote, token: nil, author: "kid-a")
        let b = TeamGit(dir: scratch.appendingPathComponent("r-b"), remote: remote, token: nil, author: "kid-b")
        try a.open(); try b.open()
        try a.put("roster/team.json", Data("one".utf8))
        // b never saw a's commit, so its push is not a fast-forward.
        XCTAssertThrowsError(try b.putAll(["roster/team.json": Data("two".utf8)], retryOnRace: false)) {
            guard case TeamGit.GitError.raceLost = $0 else { return XCTFail("expected raceLost, got \($0)") }
        }
        try b.sync()
        XCTAssertEqual(try b.get("roster/team.json"), Data("one".utf8))
        // Retrying is still the default for append-only objects.
        try b.putAll(["roster/team.json": Data("two".utf8)])
        try a.sync()
        XCTAssertEqual(try a.get("roster/team.json"), Data("two".utf8))
    }
}
