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

    /// Raw git, for setting up things the store adapter would refuse.
    @discardableResult
    func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testPathsMapToBranches() {
        XCTAssertEqual(StorePath.branch(of: "roster/team.json")?.branch, "roster")
        XCTAssertEqual(StorePath.branch(of: "roster/team.json")?.rest, "team.json")
        XCTAssertEqual(StorePath.branch(of: "requests/abc.json")?.branch, "requests")
        XCTAssertEqual(StorePath.branch(of: "m/abc/days/2026-09-05.json")?.branch, "m/abc")
        XCTAssertEqual(StorePath.branch(of: "m/abc/days/2026-09-05.json")?.rest, "days/2026-09-05.json")
        XCTAssertEqual(StorePath.branch(of: "t/abc/transcripts/s1/1.jsonl")?.branch, "t/abc")
        XCTAssertEqual(StorePath.branch(of: "t/abc/transcripts/s1/1.jsonl")?.rest, "transcripts/s1/1.jsonl")
        XCTAssertNil(StorePath.branch(of: "m/abc"))
        XCTAssertNil(StorePath.branch(of: "t/abc"))
        XCTAssertNil(StorePath.branch(of: "other/x"))
        XCTAssertNil(StorePath.branch(of: "roster/../x"))
    }

    /// #339: `compact` leaves one commit holding the tree minus the dropped
    /// prefix, force-pushed; a mirror with an old cursor still reads it.
    func testCompactRewritesTheBranchToOneCommitWithoutTheDroppedPrefix() throws {
        let remote = try makeRemote()
        let a = TeamGit(dir: scratch.appendingPathComponent("a"), remote: remote, token: nil, author: "kid-a")
        try a.open()
        for v in 1...3 { try a.put("m/kid-a/now.json", Data("v\(v)".utf8)) }
        try a.putAll(["m/kid-a/transcripts/s/1.jsonl": Data("old".utf8), "m/kid-a/transcripts/s/2.jsonl": Data("old2".utf8),
                      "m/kid-a/days/2026-09-01.json": Data("d".utf8)])
        let b = TeamGit(dir: scratch.appendingPathComponent("b"), remote: remote, token: nil, author: "kid-b")
        try b.open()
        let (_, cursor) = try b.changes(since: nil)
        let bare = scratch.appendingPathComponent("remote.git").path

        XCTAssertEqual(try a.compact(branch: "m/kid-a", dropping: "transcripts/"), 2)
        XCTAssertEqual(try git(["--git-dir", bare, "rev-list", "--count", "refs/heads/m/kid-a"]).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertEqual(try a.list("m/kid-a/").map(\.path).sorted(), ["m/kid-a/days/2026-09-01.json", "m/kid-a/now.json"])
        XCTAssertEqual(try a.get("m/kid-a/now.json"), Data("v3".utf8))
        // Nothing to drop: a second compaction is a no-op rewrite that still reads back.
        XCTAssertEqual(try a.compact(branch: "m/kid-a", dropping: "transcripts/"), 0)
        // The other mirror follows, and its pre-rewrite cursor falls back to a full listing rather than failing.
        try b.sync()
        XCTAssertEqual(try b.get("m/kid-a/now.json"), Data("v3".utf8))
        XCTAssertEqual(try b.list("m/kid-a/transcripts/"), [])
        XCTAssertNoThrow(try b.changes(since: cursor))
        // Writing on top of the compacted tip works.
        try a.put("m/kid-a/now.json", Data("v4".utf8))
        try b.sync()
        XCTAssertEqual(try b.get("m/kid-a/now.json"), Data("v4".utf8))
    }

    /// Member and transcript branches arrive at depth 1 — a reader needs
    /// their tips, not the 1.3 GB of chunks behind them (#414); the roster
    /// keeps the history its trust walk reads. A shallow tip still takes
    /// this identity's own commits on top, and later syncs keep moving.
    func testMemberAndTranscriptBranchesComeShallowTheRosterInFull() throws {
        let remote = try makeRemote()
        let a = TeamGit(dir: scratch.appendingPathComponent("a"), remote: remote, token: nil, author: "kid-a")
        try a.open()
        for rev in 1...2 { try a.put("roster/team.json", Data("{\"rev\":\(rev)}".utf8)) }
        for v in 1...3 { try a.put("m/kid-a/now.json", Data("v\(v)".utf8)) }
        for v in 1...2 { try a.put("t/kid-a/transcripts/s/\(v).jsonl", Data("chunk\(v)".utf8)) }
        try a.put("m/kid-b/seed.json", Data("seed".utf8))   // another device of b's, before b ever synced

        let b = TeamGit(dir: scratch.appendingPathComponent("b"), remote: remote, token: nil, author: "kid-b")
        try b.open()
        let bGit = scratch.appendingPathComponent("b/store.git").path
        func depth(_ branch: String) throws -> Int {
            Int(try git(["--git-dir", bGit, "rev-list", "--count", "refs/remotes/origin/\(branch)"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        XCTAssertEqual(try depth("m/kid-a"), 1)
        XCTAssertEqual(try depth("t/kid-a"), 1)
        XCTAssertEqual(try depth("roster"), 2)
        XCTAssertEqual(try b.history(of: "roster/team.json", limit: 10).count, 2)
        XCTAssertEqual(try b.get("m/kid-a/now.json"), Data("v3".utf8))
        XCTAssertEqual(try b.list("t/kid-a/").map(\.path).sorted(), ["t/kid-a/transcripts/s/1.jsonl", "t/kid-a/transcripts/s/2.jsonl"])

        // b commits on its shallow own branch and a sees it; a moves on and b follows.
        try b.put("m/kid-b/now.json", Data("b".utf8))
        try a.sync()
        XCTAssertEqual(try a.list("m/kid-b/").map(\.path).sorted(), ["m/kid-b/now.json", "m/kid-b/seed.json"])
        let (_, cursor) = try b.changes(since: nil)
        try a.put("m/kid-a/now.json", Data("v4".utf8))
        try b.sync()
        XCTAssertEqual(try b.get("m/kid-a/now.json"), Data("v4".utf8))
        XCTAssertEqual(try b.changes(since: cursor).0.map(\.path), ["m/kid-a/now.json"])
        XCTAssertEqual(try depth("m/kid-a"), 1)
    }

    func testTwoClonesExchangeFilesThroughTheRemote() throws {
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
        let g = TeamGit(dir: scratch.appendingPathComponent("g"), remote: try makeRemote(), token: nil, author: "k")
        try g.open()
        XCTAssertThrowsError(try g.put("nope/x", Data()))
        XCTAssertThrowsError(try g.put("m/k/../../x", Data()))
        XCTAssertThrowsError(try g.put("m/k/.git/config", Data()))
    }

    /// I1: rebuilding the same bytes on the winner's tip is a blind
    /// overwrite for read-modify-write objects like the roster.
    func testALostRaceIsReportedWhenRetryIsOff() throws {
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

    /// Reading stdout to the end first deadlocks as soon as the child
    /// fills its 64 KB stderr pipe — git push writes its progress there
    /// while we block, and neither side ever moves again.
    func testDrainReadsBothPipesAtOnce() throws {
        let done = expectation(description: "drained")
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo ok"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return XCTFail("\(error)") }
            let (stdout, stderr, stalled) = TeamGit.drain(out: out.fileHandleForReading, err: err.fileHandleForReading)
            p.waitUntilExit()
            XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "ok\n")
            XCTAssertEqual(stderr.count, 200_000, "the whole chatty stderr, not one pipe buffer's worth")
            XCTAssertFalse(stalled)
            XCTAssertEqual(p.terminationStatus, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    /// (a) A rejected push is a race; an unreachable remote is not. They
    /// used to be the same error, so `approve` retried a dead network
    /// three times and reported "raceLost" for it.
    func testOnlyARejectedPushCountsAsALostRace() throws {
        XCTAssertTrue(TeamGit.isRaceRejection(" ! [rejected]        abc -> roster (fetch first)\n"))
        XCTAssertTrue(TeamGit.isRaceRejection("Updates were rejected because of a non-fast-forward\n"))
        XCTAssertFalse(TeamGit.isRaceRejection("fatal: 'origin' does not appear to be a git repository\n"))
        XCTAssertFalse(TeamGit.isRaceRejection("fatal: could not read Username for 'https://host': terminal prompts disabled\n"))

        let remote = try makeRemote()
        let g = TeamGit(dir: scratch.appendingPathComponent("gone"), remote: remote, token: nil, author: "k")
        try g.open()
        try g.put("m/k/now.json", Data("n".utf8))
        // The remote disappears under us: a network failure, not a race.
        try FileManager.default.removeItem(at: scratch.appendingPathComponent("remote.git"))
        XCTAssertThrowsError(try g.putAll(["m/k/now.json": Data("n2".utf8)], retryOnRace: false)) {
            guard case TeamGit.GitError.failed(let command, _, let stderr) = $0 else {
                return XCTFail("expected failed, got \($0)")
            }
            XCTAssertTrue(command.hasPrefix("push"))
            XCTAssertFalse(stderr.isEmpty, "git's own words reach the caller")
        }
    }

    /// (b) Whatever git environment we inherited points at ANOTHER
    /// repository: `init --bare` runs without `--git-dir`, so a stray
    /// GIT_DIR would silently redirect it. `GIT_CONFIG_NOSYSTEM` is
    /// deliberately NOT set here (it would drop Apple git's osxkeychain
    /// credential helper for token-less https remotes).
    func testTheChildEnvironmentIsScrubbed() {
        let base = ["GIT_DIR": "/elsewhere/.git", "GIT_WORK_TREE": "/elsewhere",
                    "GIT_INDEX_FILE": "/elsewhere/index", "GIT_OBJECT_DIRECTORY": "/elsewhere/objects",
                    "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/elsewhere/alt", "PATH": "/usr/bin"]
        let env = TeamGit.childEnvironment(base: base, extra: ["GIT_INDEX_FILE": "/ours/index"], token: "t0ken")
        XCTAssertNil(env["GIT_DIR"])
        XCTAssertNil(env["GIT_WORK_TREE"])
        XCTAssertNil(env["GIT_OBJECT_DIRECTORY"])
        XCTAssertNil(env["GIT_ALTERNATE_OBJECT_DIRECTORIES"])
        XCTAssertEqual(env["GIT_INDEX_FILE"], "/ours/index", "our own index survives the scrub")
        XCTAssertNil(env["GIT_CONFIG_NOSYSTEM"], "osxkeychain must survive for token-less https remotes")
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(env[TeamGit.tokenEnv], "t0ken")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNil(TeamGit.childEnvironment(base: base, extra: [:], token: nil)[TeamGit.tokenEnv])
    }

    /// (c) A killed git leaves `index.lock` behind and every later write
    /// refuses to run. A lock a LIVE child holds is young, so only old
    /// ones go.
    func testOpenSweepsStaleLocksAndLeavesFreshOnes() throws {
        let remote = try makeRemote()
        let dir = scratch.appendingPathComponent("locks")
        let first = TeamGit(dir: dir, remote: remote, token: nil, author: "k")
        try first.open()
        try first.put("m/k/now.json", Data("n".utf8))
        XCTAssertEqual(first.sweptLocks, [])

        let gitDir = dir.appendingPathComponent("store.git")
        let stale = gitDir.appendingPathComponent("index.lock")
        let refLock = gitDir.appendingPathComponent("refs/remotes/origin/m/k.lock")
        let young = gitDir.appendingPathComponent("config.lock")
        try FileManager.default.createDirectory(at: refLock.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [stale, refLock, young] { try Data().write(to: url) }
        for url in [stale, refLock] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                                                  ofItemAtPath: url.path)
        }

        let again = TeamGit(dir: dir, remote: remote, token: nil, author: "k")
        try again.open()
        XCTAssertEqual(Set(again.sweptLocks), [stale.path, refLock.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refLock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: young.path), "a lock a live git may still hold stays")
        XCTAssertEqual(try again.get("m/k/now.json"), Data("n".utf8))
    }

    /// (d) The remote may carry anything (a host's initial `main`, a
    /// stray feature branch); the store reads only the branches §4.2
    /// defines.
    func testOnlyTheStoresOwnBranchesAreListed() throws {
        let remote = try makeRemote()
        let bare = scratch.appendingPathComponent("remote.git")
        let g = TeamGit(dir: scratch.appendingPathComponent("filtered"), remote: remote, token: nil, author: "k")
        try g.open()
        try g.put("roster/team.json", Data("{}".utf8))
        try g.put("m/k/now.json", Data("n".utf8))
        try g.put("t/k/transcripts/s1/1.jsonl", Data("c".utf8))
        // A branch the layout knows nothing about, pointing at the same tree.
        try git(["--git-dir", bare.path, "branch", "main", "roster"])
        try g.sync()

        XCTAssertEqual(try g.list("").map(\.path).sorted(), ["m/k/now.json", "roster/team.json", "t/k/transcripts/s1/1.jsonl"])
        XCTAssertEqual(try g.changes(since: nil).0.map(\.path).sorted(), ["m/k/now.json", "roster/team.json", "t/k/transcripts/s1/1.jsonl"])
        XCTAssertNil(try g.changes(since: nil).1.heads["main"])
    }

    /// #321: a store's default branch set bounds what `sync()` pulls, and
    /// an empty list pulls nothing rather than falling back to the
    /// remote's own refspec (which is everything).
    func testSyncKeepsToTheDefaultBranches() throws {
        let remote = try makeRemote()
        let writer = TeamGit(dir: scratch.appendingPathComponent("w"), remote: remote, token: nil, author: "w")
        try writer.open()
        try writer.put("roster/team.json", Data("{}".utf8))
        try writer.put("m/a/now.json", Data("n".utf8))
        try writer.put("t/a/transcripts/s1/1.jsonl", Data("c".utf8))
        try writer.put("t/b/transcripts/s1/1.jsonl", Data("c".utf8))

        let reader = TeamGit(dir: scratch.appendingPathComponent("r"), remote: remote, token: nil, author: "b")
        reader.defaultBranches = ["roster", "requests", "m/", "t/b"]
        try reader.open()
        XCTAssertEqual(try reader.list("").map(\.path), ["m/a/now.json", "roster/team.json", "t/b/transcripts/s1/1.jsonl"])
        try reader.sync(branches: [])
        XCTAssertEqual(try reader.list("t/").count, 1, "an empty list fetches nothing")
        try reader.sync(branches: ["t/a"])
        XCTAssertEqual(try reader.list("t/").map(\.path), ["t/a/transcripts/s1/1.jsonl", "t/b/transcripts/s1/1.jsonl"])
    }

    /// (e) A cursor's commit can become unreachable (the remote was
    /// rewritten, the mirror rebuilt, the object gc'd). Re-listing the
    /// branch is always correct — it is what a nil cursor does.
    func testAnUnreachableCursorFallsBackToTheFullListing() throws {
        let remote = try makeRemote()
        let g = TeamGit(dir: scratch.appendingPathComponent("cursor"), remote: remote, token: nil, author: "k")
        try g.open()
        try g.put("roster/team.json", Data("{}".utf8))
        var bogus = StoreCursor()
        bogus.heads["roster"] = String(repeating: "0", count: 40)
        let (entries, cursor) = try g.changes(since: bogus)
        XCTAssertEqual(entries.map(\.path), ["roster/team.json"])
        XCTAssertNotEqual(cursor.heads["roster"], bogus.heads["roster"])
        XCTAssertEqual(try g.changes(since: cursor).0, [], "the fresh cursor works normally")
    }

    /// #55: `GitError.failed` quotes git's stderr, which echoes the
    /// remote as configured — and the remote a team code carries IS the
    /// write credential.
    /// A child that spawns and then says nothing: the drain reads "ok" on
    /// stdout, waits `idle` for stderr, kills it, and reports the stall
    /// — after the "waiting" notice.
    func testASilentNetworkChildIsKilledAndReportedAsStalled() throws {
        let done = expectation(description: "drained")
        let notices = Locked<[String]>([])
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "echo ok; exec sleep 60"]   // exec: the killed process is the one holding the pipes
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return XCTFail("\(error)") }
            let start = Date()
            let watch = TeamGit.Watch(idle: 3, quiet: 1, activity: { line in notices.with { $0.append(line) } },
                                      kill: { TeamGit.terminate(p) })
            let (stdout, _, stalled) = TeamGit.drain(out: out.fileHandleForReading, err: err.fileHandleForReading, watch: watch)
            p.waitUntilExit()
            XCTAssertTrue(stalled)
            XCTAssertLessThan(Date().timeIntervalSince(start), 20, "killed at the idle limit, not at the child's own exit")
            XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "ok\n", "what arrived before the stall is kept")
            XCTAssertNotEqual(p.terminationStatus, 0)
            XCTAssertEqual(notices.value, ["waiting for the store to answer…"])
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }

    /// A slow child that keeps talking is never a stall, and its latest
    /// `\r`-updated line reaches the sink.
    func testAChattySlowChildIsNotAStallAndReportsItsLastLine() throws {
        let done = expectation(description: "drained")
        let notices = Locked<[String]>([])
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "for i in 1 2 3 4 5 6; do printf 'Receiving objects: %d0%%\\r' $i >&2; sleep 0.5; done; echo ok"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return XCTFail("\(error)") }
            let watch = TeamGit.Watch(idle: 2, quiet: 1, activity: { line in notices.with { $0.append(line) } },
                                      kill: { TeamGit.terminate(p) })
            let (stdout, stderr, stalled) = TeamGit.drain(out: out.fileHandleForReading, err: err.fileHandleForReading, watch: watch)
            p.waitUntilExit()
            XCTAssertFalse(stalled)
            XCTAssertEqual(p.terminationStatus, 0)
            XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "ok\n")
            XCTAssertEqual(stderr.count, "Receiving objects: 10%\r".utf8.count * 6, "every byte, not one per report")
            let lines = notices.value
            XCTAssertFalse(lines.isEmpty)
            XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("Receiving objects: ") }, "\(lines)")
            XCTAssertFalse(lines.contains("waiting for the store to answer…"), "a talking child is not quiet")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testProgressStderrCollapsesToItsFinalLines() {
        let raw = Data("remote: Counting objects:  10%\rremote: Counting objects: 100%, done.\nReceiving objects:   1%\rReceiving objects:  50%\nfatal: early EOF\n".utf8)
        XCTAssertEqual(TeamGit.collapsed(raw), "remote: Counting objects: 100%, done.\nReceiving objects:  50%\nfatal: early EOF\n")
        XCTAssertEqual(TeamGit.lastLine("a\rb\nc\r  "), "c")
        XCTAssertEqual(TeamGit.lastLine("\r\n"), "")
    }

    /// A stall is its own error: the race retry keys on `.failed` with
    /// git's rejection words, so a killed push is never re-pushed as if a
    /// teammate had won.
    func testAStallIsNotARaceRejection() {
        let error: TeamGit.GitError = .stalled(command: "push --progress origin abc:refs/heads/roster", idle: 90)
        if case .failed = error { XCTFail("a stall must not read as a failed command") }
        XCTAssertEqual("\(error)", "the store did not answer for 90 s (git push gave up)")
    }

    func testFeedingAChildThatAlreadyExitedDoesNotKillTheProcess() throws {
        // Under the old sequential write this raised SIGPIPE (#55).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["true"]
        let input = Pipe()
        p.standardInput = input
        try p.run(); p.waitUntilExit()
        // Off the test thread with a deadline: a regression that blocks in
        // the write must fail the test, not hang the suite.
        let fed = expectation(description: "feed returns")
        DispatchQueue.global().async {
            TeamGit.feed(input.fileHandleForWriting, Data(repeating: 0x2a, count: 1 << 20))   // 1 MiB, far past the pipe buffer
            fed.fulfill()
        }
        wait(for: [fed], timeout: 10)
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testTeamIDsAreOnePathSegment() {
        XCTAssertTrue(TeamPaths.isValidID(UUID().uuidString.lowercased()))
        for bad in ["", ".", "..", "../x", "a/b", "a b", "ünï", String(repeating: "a", count: 65)] {
            XCTAssertFalse(TeamPaths.isValidID(bad), bad)
        }
    }

    func testCredentialedRemotesAreMasked() {
        XCTAssertEqual(TeamGit.masked("fatal: unable to access 'https://infinitus:ghp_secret@github.com/o/r.git/'"),
                       "fatal: unable to access 'https://•••@github.com/o/r.git/'")
        XCTAssertEqual(TeamGit.masked("ssh://git:pw@host/r.git and https://u@h/x"),
                       "ssh://•••@host/r.git and https://•••@h/x")
        XCTAssertEqual(TeamGit.masked("no credential here"), "no credential here")
        XCTAssertEqual(TeamGit.masked("file:///tmp/remote.git"), "file:///tmp/remote.git")
    }
}

/// A boxed value the reader threads and the test share.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func with(_ body: (inout T) -> Void) { lock.lock(); body(&v); lock.unlock() }
}
