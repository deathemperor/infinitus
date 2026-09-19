import XCTest
@testable import InfinitusCore

final class TeamPublisherTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teampub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// The same fixture as TeamCollectTests.TeamFixture (repeated: each
    /// test file stands alone). s1 in /r/app (10 tokens) + agent-a1 (5),
    /// s2 in /r/secret (10); the user prompt carries an `sk-ant-…` key.
    func writeProjects(_ root: URL) throws -> URL {
        let user = #"{"type":"user","cwd":"%CWD%","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"}}"#
        let assistant = #"{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"%ID%","model":"claude-opus-5","usage":{"input_tokens":%IN%,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"#
        func transcript(_ cwd: String, _ id: String, _ input: Int) -> String {
            user.replacingOccurrences(of: "%CWD%", with: cwd) + "\n"
                + assistant.replacingOccurrences(of: "%ID%", with: id).replacingOccurrences(of: "%IN%", with: String(input)) + "\n"
        }
        let projects = root.appendingPathComponent("projects")
        let app = projects.appendingPathComponent("-r-app"), secret = projects.appendingPathComponent("-r-secret")
        let sub = app.appendingPathComponent("s1/subagents")
        for dir in [app, secret, sub] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try transcript("/r/app", "a1", 10).write(to: app.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try transcript("/r/app", "a2", 5).write(to: sub.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try transcript("/r/secret", "a3", 10).write(to: secret.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        return projects
    }

    struct Team {
        let leader: TeamClient, alice: TeamClient, bob: TeamClient
        let alicePaths: TeamPaths
    }

    /// Leader + two approved members; alice is the publisher under test.
    func team() throws -> Team {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (ap, asec) = machine("alice"), (bp, bs) = machine("bob")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let alice = try TeamClient.request(code: code, name: "Alice", devices: [], platform: "linux", paths: ap, secrets: asec, now: 1_010)
        let bob = try TeamClient.request(code: code, name: "Bob", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_011)
        _ = try leader.fetch()
        try leader.approve(kid: alice.identity.kid, now: 1_020)
        try leader.approve(kid: bob.identity.kid, now: 1_021)
        _ = try alice.fetch(); _ = try bob.fetch()
        return Team(leader: leader, alice: alice, bob: bob, alicePaths: ap)
    }

    static let secretText = "use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"

    func thread(_ id: String, _ project: String, status: String = "idle") -> TeamDocs.ThreadRow {
        TeamDocs.ThreadRow(id: id, title: "Thread \(id)", project: project, status: status, createdAt: 1, updatedAt: 2, turns: 1)
    }

    func transcript(_ id: String, _ project: String, rows: [String] = [secretText, "sure"]) -> TeamThreadSources.Transcript {
        TeamThreadSources.Transcript(threadId: id, project: project,
                                     rows: rows.enumerated().map { .init(role: $0.offset % 2 == 0 ? "user" : "assistant", text: $0.element, at: $0.offset) })
    }

    /// Stats from the fixture scan; two threads, one per project, each
    /// with a two-row transcript; the running one live; and a fleet.
    func sources(_ projects: URL) -> TeamPublisher.Sources {
        var s = TeamPublisher.Sources(home: "/Users/alice", machine: "alice-mac")
        s.entries = StatsScanner.scan(projectsDir: projects, cacheURL: nil, calendar: .current, maxAge: 10_000 * 86_400).entries
        s.historyDays = 10_000   // the fixture's dates stay in the window whenever this runs
        s.desktop = true
        s.threads = [thread("t1", "app", status: "running"), thread("t2", "secret")]
        s.live = [TeamDocs.LiveThread(id: "t1", title: "Thread t1", project: "app", startedAt: 1)]
        s.transcripts = [transcript("t1", "app"), transcript("t2", "secret")]
        s.fleets = [TeamDocs.Fleet(engine: "opaque", account: "acct-1", windows: [TeamDocs.Window(label: "5h", pct: 40)])]
        return s
    }

    func header(_ client: TeamClient, _ path: String) throws -> Envelope.Header {
        try XCTUnwrap(try client.readableHeaders().first { $0.entry.path == path }?.header)
    }

    func rows(_ client: TeamClient, _ path: String) throws -> [TeamThreadSources.Row] {
        try String(decoding: try client.read(path).1, as: UTF8.self).split(separator: "\n")
            .map { try CanonicalJSON.decode(TeamThreadSources.Row.self, from: Data($0.utf8)) }
    }

    func testPublishWrapsEachKindToItsAudienceHonoursExclusionsAndRedacts() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        var shares = TeamShares()
        shares.byKind[TeamKinds.stats] = .team
        shares.byKind[TeamKinds.threads] = .members([t.bob.identity.kid])
        try shares.save(teamDir: teamDir)
        try TeamExclusions(projects: ["/r/secret"]).save(paths: t.alicePaths)

        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        let report = try publisher.publish(sources: sources(projects), now: Date(timeIntervalSince1970: 1_788_609_600))
        let me = "m/\(t.alice.identity.kid)/", mine = "t/\(t.alice.identity.kid)/"
        XCTAssertEqual(Set(report.published), [me + "days/2026-09-04.json", me + "threads/index.json", me + "now.json",
                                               mine + "transcripts/t1/1.jsonl"])
        XCTAssertEqual(report.transcriptChunks, 1, "the excluded project's thread is never chunked")
        XCTAssertEqual(report.skipped, 0)

        _ = try t.leader.fetch(); _ = try t.bob.fetch()
        // stats → team (leader + bob), threads → bob only, the rest → leaders.
        XCTAssertEqual(Set(try header(t.leader, me + "days/2026-09-04.json").to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid, t.bob.identity.kid])
        // The sender is always in `to`, so a re-share can read its own copy.
        XCTAssertEqual(Set(try header(t.bob, me + "threads/index.json").to.map(\.kid)), [t.bob.identity.kid, t.alice.identity.kid])
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "threads/index.json"))
        XCTAssertEqual(Set(try header(t.leader, me + "now.json").to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid])
        // The excluded project is out of the stats, the index and the live rows.
        let day = try CanonicalJSON.decode(TeamDocs.DayDoc.self, from: try t.leader.read(me + "days/2026-09-04.json").1)
        XCTAssertEqual(day.stats.inputTokens, 15)
        let index = try CanonicalJSON.decode(TeamDocs.ThreadsIndex.self, from: try t.bob.read(me + "threads/index.json").1)
        XCTAssertEqual(index.threads.map(\.id), ["t1"]); XCTAssertEqual(index.fleets.map(\.engine), ["opaque"])
        let now = try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read(me + "now.json").1)
        XCTAssertEqual(now.machine, "alice-mac"); XCTAssertTrue(now.desktop); XCTAssertEqual(now.live.map(\.id), ["t1"])
        XCTAssertEqual(now.crashesToday, 0, "the team stopped carrying crash reports (#1422)")
        XCTAssertEqual(now.sharesTo[TeamKinds.stats], .team)
        // The transcript rides t/<kid>, fetched on demand, redacted.
        try t.leader.fetchTranscripts(from: t.alice.identity.kid, session: "t1")
        XCTAssertEqual(try rows(t.leader, mine + "transcripts/t1/1.jsonl").map(\.text), ["use [redacted-key] please", "sure"])
        // Plaintext copies for a later re-share, the transcript too.
        XCTAssertTrue(FileManager.default.fileExists(atPath: publisher.copiesDir.appendingPathComponent("transcripts/t1/1.jsonl").path))
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir).transcripts["t1"], TeamPublishState.Cursor(seq: 1, offset: 2))

        // A second pass with nothing new: the day is skipped by hash, the
        // index and now.json go out again, no chunk.
        let again = try publisher.publish(sources: sources(projects), now: Date(timeIntervalSince1970: 1_788_609_700))
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(Set(again.published), [me + "threads/index.json", me + "now.json"])
        XCTAssertEqual(again.transcriptChunks, 0)
    }

    func testNewRowsChunkFromTheCursorAndTheDesktopBeingAwayKeepsTheIndex() throws {
        let t = try team()
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = TeamPublisher.Sources(home: "/h", machine: "m")
        s.desktop = true
        s.threads = [thread("t1", "app")]
        s.transcripts = [transcript("t1", "app", rows: ["a", "b"])]
        XCTAssertEqual(try publisher.publish(sources: s).transcriptChunks, 1)
        s.transcripts = [transcript("t1", "app", rows: ["a", "b", "c"])]
        XCTAssertEqual(try publisher.publish(sources: s).transcriptChunks, 1, "one chunk for the one new row")
        let mine = "t/\(t.alice.identity.kid)/"
        _ = try t.leader.fetch()
        try t.leader.fetchTranscripts(from: t.alice.identity.kid, session: "t1")
        XCTAssertEqual(try rows(t.leader, mine + "transcripts/t1/2.jsonl").map(\.text), ["c"])
        XCTAssertEqual(try publisher.publish(sources: s).transcriptChunks, 0, "the thread handed whole again publishes nothing")

        // The desktop away: the index stays as it was, now.json says so.
        var away = s; away.desktop = false; away.threads = []; away.transcripts = []
        let report = try publisher.publish(sources: away)
        let me = "m/\(t.alice.identity.kid)/"
        XCTAssertEqual(report.published, [me + "now.json"])
        _ = try t.leader.fetch()
        XCTAssertFalse(try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read(me + "now.json").1).desktop)
        XCTAssertTrue(try t.leader.readable().map(\.path).contains(me + "threads/index.json"))
    }

    func testTranscriptChoicesAndTheOffKindKeepTranscriptsOnTheMac() throws {
        let t = try team()
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = TeamPublisher.Sources(home: "/h", machine: "m")
        s.desktop = true
        s.transcripts = [transcript("t1", "app"), transcript("t2", "app")]
        var choices = TeamTranscriptChoices(); choices.mode = .chosen; choices.chosen = ["t2"]
        try choices.save(teamDir: teamDir)
        let report = try publisher.publish(sources: s)
        XCTAssertEqual(report.transcriptChunks, 1)
        XCTAssertEqual(report.published.filter { $0.contains("/transcripts/") }, ["t/\(t.alice.identity.kid)/transcripts/t2/1.jsonl"])

        var shares = TeamShares(); shares.byKind[TeamKinds.transcripts] = .off
        try shares.save(teamDir: teamDir)
        s.transcripts = [transcript("t1", "app"), transcript("t2", "app", rows: ["x", "y", "z"])]
        let off = try publisher.publish(sources: s)
        XCTAssertEqual(off.transcriptChunks, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publisher.copiesDir.appendingPathComponent("transcripts/t2/2.jsonl").path),
                       "an off kind is not copied to published/ either")
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir).transcripts["t2"]?.offset, 2, "the cursor did not move")
        _ = try t.leader.fetch()
        let now = try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read("m/\(t.alice.identity.kid)/now.json").1)
        XCTAssertNil(now.sharesTo[TeamKinds.transcripts], "the hint drops the off kind")
        XCTAssertFalse(try publisher.reshare(days: 10_000).published.contains { $0.contains("/transcripts/") })
        XCTAssertThrowsError(try t.alice.publish(kind: TeamKinds.stats, path: "days/2026-09-04.json", plaintext: Data("{}".utf8), audience: .off)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .audienceOff)
        }
    }

    /// `now` off after a publish would leave this member looking "on"
    /// forever, so the stale now.json is retired once.
    func testNowSharedWithNobodyIsRetiredFromTheStore() throws {
        let t = try team()
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        let s = TeamPublisher.Sources(home: "/h", machine: "m")
        _ = try publisher.publish(sources: s)
        let me = "m/\(t.alice.identity.kid)/"
        _ = try t.leader.fetch()
        XCTAssertTrue(try t.leader.readable().map(\.path).contains(me + "now.json"))
        var shares = TeamShares(); shares.byKind[TeamKinds.now] = .off
        try shares.save(teamDir: teamDir)
        _ = try publisher.publish(sources: s)
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "now.json"))
        XCTAssertNoThrow(try publisher.publish(sources: s), "the second pass has nothing left to delete")
        try publisher.quit()
    }

    func testFleetIsPublishedSkippedWhileUnchangedAndRetiredWhenOff() throws {
        let t = try team()
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = TeamPublisher.Sources(home: "/h", machine: "m")
        let me = "m/\(t.alice.identity.kid)/"
        XCTAssertFalse(try publisher.publish(sources: s).published.contains(me + "fleet.json"), "no rows, no file")
        s.fleetRows = [TeamDocs.FleetDoc.FleetRow(engine: "swapd", active: "ann", next: nil, accounts: [
            TeamDocs.FleetDoc.AccountRow(label: "ann", tier: nil, status: TeamDocs.FleetDoc.ok, active: true, windows: [], models: []),
        ])]
        XCTAssertTrue(try publisher.publish(sources: s, now: Date(timeIntervalSince1970: 5_000)).published.contains(me + "fleet.json"))
        _ = try t.leader.fetch()
        XCTAssertEqual(try CanonicalJSON.decode(TeamDocs.FleetDoc.self, from: try t.leader.read(me + "fleet.json").1).at, 5_000)
        var shares = TeamShares(); shares.byKind[TeamKinds.fleet] = .off
        try shares.save(teamDir: teamDir)
        _ = try publisher.publish(sources: s)
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "fleet.json"))
    }

    /// The crashes kind is retired (#1422): a crashes.json published by an
    /// older build is removed on the next publish, and a lingering
    /// plaintext copy is never re-shared back into the store.
    func testLegacyCrashesFileIsRetiredAndNeverReshared() throws {
        let t = try team()
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        let me = "m/\(t.alice.identity.kid)/"
        let doc = try CanonicalJSON.encode(TeamDocs.Crashes(crashes: ["Mac · crash · SIGSEGV"]))
        // What an older build left behind: the envelope, its state hash,
        // and the plaintext copy under published/.
        try t.alice.publish(kind: TeamKinds.crashes, path: "crashes.json", plaintext: doc, audience: .leaders, now: 1_030)
        var state = TeamPublishState.load(teamDir: teamDir)
        state.hashes["crashes.json"] = TeamPublisher.hex(doc)
        try state.save(teamDir: teamDir)
        let copy = publisher.copiesDir.appendingPathComponent("crashes.json")
        try FileManager.default.createDirectory(at: publisher.copiesDir, withIntermediateDirectories: true)
        try doc.write(to: copy)
        _ = try t.leader.fetch()
        XCTAssertTrue(try t.leader.readable().map(\.path).contains(me + "crashes.json"))

        _ = try publisher.publish(sources: TeamPublisher.Sources(home: "/h", machine: "m"))
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "crashes.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the copy goes with it")
        XCTAssertNil(TeamPublishState.load(teamDir: teamDir).hashes["crashes.json"])

        // A copy that survived anyway (a reshare before the first publish)
        // is skipped like now.json.
        try doc.write(to: copy)
        XCTAssertFalse(try publisher.reshare(days: 10_000).published.contains { $0.hasSuffix("crashes.json") })
    }

    func testReshareRewrapsHistoryToTheCurrentAudienceAfterPromotion() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        _ = try t.bob.fetch()
        XCTAssertFalse(try t.bob.readable().map(\.path).contains(me + "days/2026-09-04.json"), "leaders only, so far")
        try t.leader.promote(kid: t.bob.identity.kid, now: 2_000)
        _ = try t.alice.fetch()
        let report = try publisher.reshare(days: 10_000)
        XCTAssertTrue(report.published.contains(me + "days/2026-09-04.json"))
        XCTAssertTrue(report.published.contains("t/\(t.alice.identity.kid)/transcripts/t1/1.jsonl"))
        XCTAssertFalse(report.published.contains(me + "now.json"), "live state is never re-shared")
        _ = try t.bob.fetch()
        XCTAssertTrue(try t.bob.readable().map(\.path).contains(me + "days/2026-09-04.json"))
    }

    func testDayDigestIsOrderIndependentAndLossless() throws {
        var a = Stats.Day(); a.sessions = ["s1", "s2"]; a.repos = ["r1"]; a.inputTokens = 3
        var b = a; b.sessions = ["s2", "s1"]
        XCTAssertEqual(try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "d", stats: a)), try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "d", stats: b)))
        var c = a; c.sessions = ["s1", "s3"]
        XCTAssertNotEqual(try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "d", stats: a)), try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "d", stats: c)))
    }

    func testPendingMemberCannotPublish() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (pp, ps) = machine("pat")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let pat = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Pat", devices: [], platform: "linux", paths: pp, secrets: ps, now: 1_010)
        XCTAssertThrowsError(try TeamPublisher(client: pat, paths: pp).publish(sources: TeamPublisher.Sources(home: "/h", machine: "m"))) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }

    func testPublishedCopiesArePrunedOldestTranscriptFirst() throws {
        let dir = scratch.appendingPathComponent("copies")
        for (name, at) in [("transcripts/a/1.jsonl", 10.0), ("transcripts/b/1.jsonl", 20.0), ("days/2026-09-04.json", 5.0)] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: at)], ofItemAtPath: url.path)
        }
        XCTAssertEqual(TeamPublisher.pruneCopies(in: dir, cap: 250), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcripts/a/1.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("days/2026-09-04.json").path), "day copies are never pruned")
        XCTAssertEqual(TeamPublisher.pruneCopies(in: dir, cap: 50), 1, "a cap below the day copies still terminates")
    }

    func testProgressStopAndRemainingBytes() throws {
        let t = try team()
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = TeamPublisher.Sources(home: "/h", machine: "m")
        s.desktop = true
        s.transcripts = [transcript("t1", "app"), transcript("t2", "app"), transcript("t3", "app")]
        let seen = OSAllocatedUnfairLockBox<[String]>([])
        s.onProgress = { progress in seen.with { $0.append("\(progress.phase):\(progress.done)/\(progress.total)") } }
        let stops = OSAllocatedUnfairLockBox(0)
        s.shouldStop = { stops.with { $0 += 1; return $0 > 2 } }   // t1 and t2 go, t3 waits
        let report = try publisher.publish(sources: s)
        XCTAssertTrue(report.stopped); XCTAssertEqual(report.transcriptChunks, 2)
        XCTAssertGreaterThan(report.remainingBytes, 0)
        XCTAssertEqual(seen.value, ["scan:0/3", "scan:1/3", "scan:2/3", "push:2/3"], "once per transcript and once per push, never per chunk")
        s.shouldStop = nil
        let rest = try publisher.publish(sources: s)
        XCTAssertFalse(rest.stopped); XCTAssertEqual(rest.transcriptChunks, 1); XCTAssertEqual(rest.remainingBytes, 0)
    }

    func testPackKeepsChunksUnderTheCapAndALongLineWhole() {
        let line = Data(repeating: 0x61, count: 10)
        XCTAssertEqual(TeamPublisher.pack(Array(repeating: line, count: 5), maxBytes: 25).map(\.count), [20, 20, 10])
        XCTAssertEqual(TeamPublisher.pack([Data(repeating: 0x62, count: 40), line], maxBytes: 25).map(\.count), [40, 10])
        XCTAssertEqual(TeamPublisher.pack([], maxBytes: 25), [])
    }
}

/// A tiny lock box for the closures the publisher calls off the test's thread.
final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&stored) }
}
