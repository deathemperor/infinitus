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

    /// Same fixture as TeamCollectTests.TeamFixture (repeated: each test
    /// file stands alone). s1 in /r/app (10 tokens) + agent-a1 (5), s2 in
    /// /r/secret (10); the user prompt carries an `sk-ant-…` key.
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

    func sources(_ projects: URL) -> TeamPublisher.Sources {
        var s = TeamPublisher.Sources(projectsDir: projects, home: "/Users/alice")
        s.historyDays = 10_000   // the fixture's dates stay in the window whenever this runs
        s.transcriptDays = 10_000
        s.liveSessions = [ClaudeSessionRecord(pid: 1, sessionId: "s1", cwd: "/r/app", status: "busy"),
                          ClaudeSessionRecord(pid: 2, sessionId: "s2", cwd: "/r/secret", status: "idle")]
        s.crashes = [CrashReport(platform: "mac", device: "Mac", appVersion: "1", osVersion: "26", at: Date(), kind: "crash", reason: "SIGSEGV")]
        s.fleets = [TeamDocs.Fleet(engine: "opaque", account: "acct-1", windows: [TeamDocs.Window(label: "5h", pct: 40)])]
        return s
    }

    func header(_ client: TeamClient, _ path: String) throws -> Envelope.Header {
        try XCTUnwrap(try client.readableHeaders().first { $0.entry.path == path }?.header)
    }

    func testPublishWrapsEachKindToItsAudienceHonoursExclusionsAndRedacts() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        var shares = TeamShares()
        shares.byKind["stats"] = .team
        shares.byKind["sessions"] = .members([t.bob.identity.kid])
        try shares.save(teamDir: teamDir)
        var ex = TeamExclusions(); ex.set("/r/secret", excluded: true); try ex.save(paths: t.alicePaths)

        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var src = sources(projects)
        src.endpoints = TeamControl.Endpoints(lan: "10.0.0.2:47824")
        src.grantsTo = [TeamDocs.GrantHint(audience: .leaders, sessions: nil, capabilities: ["send"])]
        let report = try publisher.publish(sources: src)
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        XCTAssertEqual(Set(report.published), [
            me + "days/2026-09-04.json", me + "sessions/index.json", me + "now.json", me + "crashes.json",
            mine + "transcripts/s1/1.jsonl", mine + "transcripts/s1/subagents/agent-a1/1.jsonl",
        ])
        XCTAssertEqual(report.transcriptChunks, 2)

        _ = try t.leader.fetch(); _ = try t.bob.fetch()
        // stats → team: leader and bob read it; sessions → bob only; the rest → leaders.
        let dayHeader = try header(t.leader, me + "days/2026-09-04.json")
        XCTAssertEqual(Set(dayHeader.to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid, t.bob.identity.kid])
        XCTAssertEqual(Set(try t.bob.readable().map(\.path)), [me + "days/2026-09-04.json", me + "sessions/index.json"])
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "sessions/index.json"))
        let chunkHeader = try header(t.leader, mine + "transcripts/s1/1.jsonl")
        XCTAssertEqual(Set(chunkHeader.to.map(\.kid)), [t.leader.identity.kid, t.alice.identity.kid])

        // Excluded project: no day contribution, no session row, no transcript, no live session.
        let day = try CanonicalJSON.decode(TeamDocs.DayDoc.self, from: try t.leader.read(me + "days/2026-09-04.json").1)
        XCTAssertEqual(day.day, "2026-09-04")
        XCTAssertEqual(day.stats.inputTokens, 15)
        let index = try CanonicalJSON.decode(TeamDocs.SessionsIndex.self, from: try t.bob.read(me + "sessions/index.json").1)
        XCTAssertEqual(index.sessions.map(\.id), ["s1"])
        XCTAssertEqual(index.fleets.first?.account, "acct-1")
        let now = try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read(me + "now.json").1)
        XCTAssertEqual(now.sessions.map(\.id), ["s1"])
        XCTAssertEqual(now.sessions.first?.project, "app")
        XCTAssertEqual(now.crashesToday, 1)
        XCTAssertEqual(now.sharesTo["stats"], .team)
        XCTAssertEqual(now.endpoints?.lan, "10.0.0.2:47824")
        XCTAssertEqual(now.grantsTo?.first?.capabilities, ["send"])
        let crashes = try CanonicalJSON.decode(TeamDocs.Crashes.self, from: try t.leader.read(me + "crashes.json").1)
        XCTAssertEqual(crashes.crashes, ["Mac · crash · SIGSEGV"])
        XCTAssertFalse(try t.leader.readable().map(\.path).contains { $0.contains("/s2/") })

        // Redacted before sealing; the local copy is the redacted text too.
        let chunk = String(decoding: try t.leader.read(mine + "transcripts/s1/1.jsonl").1, as: UTF8.self)
        XCTAssertFalse(chunk.contains("sk-ant"))
        XCTAssertTrue(chunk.contains("[redacted-key]"))
        let copy = try String(contentsOf: publisher.copiesDir.appendingPathComponent("transcripts/s1/1.jsonl"), encoding: .utf8)
        XCTAssertEqual(copy, chunk)

        // Nothing changed: only the every-push files go out again, no chunks.
        let second = try publisher.publish(sources: sources(projects))
        XCTAssertEqual(Set(second.published), [me + "sessions/index.json", me + "now.json"])
        XCTAssertEqual(second.transcriptChunks, 0)
        XCTAssertEqual(second.skipped, 2)   // the day and the crash list

        // New lines → the next chunk, seq 2, and the day changes with them.
        let s1 = projects.appendingPathComponent("-r-app/s1.jsonl")
        let handle = try FileHandle(forWritingTo: s1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","timestamp":"2026-09-04T12:00:09.000Z","message":{"id":"a9","model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":1},"content":[{"type":"text","text":"more"}]}}"#.utf8 + [UInt8(ascii: "\n")]))
        try handle.close()
        let third = try publisher.publish(sources: sources(projects))
        XCTAssertTrue(third.published.contains(mine + "transcripts/s1/2.jsonl"))
        XCTAssertTrue(third.published.contains(me + "days/2026-09-04.json"))
        XCTAssertEqual(third.transcriptChunks, 1)
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir).transcripts["s1"]?.seq, 2)

        // quit deletes now.json.
        try publisher.quit()
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "now.json"))
    }

    func commits(_ remote: URL) throws -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", remote.path, "rev-list", "--count", "--all"]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return Int(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    func testTranscriptWindowIsNarrowerThanTheStatsWindow() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        var s = sources(projects)
        s.transcriptDays = 1
        // Ten days after the fixture's 2026-09-04 lines: the day still travels, no chunk does.
        let later = Date(timeIntervalSince1970: 1_789_000_000)
        let report = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: s, now: later)
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        XCTAssertEqual(report.transcriptChunks, 0)
        XCTAssertTrue(report.published.contains(me + "days/2026-09-04.json"))
        XCTAssertFalse(report.published.contains { $0.contains("/transcripts/") })
        // Same session index either way: the row is not the transcript.
        let index = try CanonicalJSON.decode(TeamDocs.SessionsIndex.self, from: try t.alice.read(me + "sessions/index.json").1)
        XCTAssertEqual(index.sessions.map(\.id), ["s1", "s2"])
    }

    func testBatchesPushSeparatelyAndSaveStateBetweenThem() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        var s = sources(projects)
        s.batchBytes = 1   // every transcript source flushes on its own
        let remote = scratch.appendingPathComponent("remote.git")
        let before = try commits(remote)
        let report = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: s)
        XCTAssertEqual(report.transcriptChunks, 3)   // s1, its sub-agent, s2
        // Three transcript batches → three commits on t/, plus one on m/ for
        // the whole-object files riding the first batch (#321: one commit
        // per branch a batch touches) — not one commit for everything.
        XCTAssertEqual(try commits(remote) - before, 4)
        XCTAssertEqual(Set(report.published).count, report.published.count)
        XCTAssertEqual(TeamPublishState.load(teamDir: t.alicePaths.teamDir(t.alice.config.id)).transcripts.count, 3)
    }

    func testHeaderScanRemembersHeadersByBlobVersion() throws {
        let t = try team()
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        try t.alice.publish(kind: "now", path: "now.json", plaintext: Data("{}".utf8), audience: .leaders, now: 5_000)
        _ = try t.leader.fetch()
        let first = try XCTUnwrap(try t.leader.readableHeaders().first { $0.entry.path == me + "now.json" })
        XCTAssertEqual(first.header.at, 5_000)
        // The leader's cache holds that header under the blob's version…
        let cacheURL = t.leader.teamDirForTests.appendingPathComponent("headers.json")
        var cache = try JSONDecoder().decode(TeamClient.HeaderCache.self, from: try Data(contentsOf: cacheURL))
        XCTAssertEqual(cache.entries[me + "now.json"]?.version, first.entry.version)
        // …and a second scan answers from it (a doctored `at` proves no blob was read).
        cache.entries[me + "now.json"]!.header.at = 5_001
        try cache.save(cacheURL)
        XCTAssertEqual(try t.leader.readableHeaders().first { $0.entry.path == me + "now.json" }?.header.at, 5_001)
        // A republish (new blob version) is read fresh and replaces the cached header.
        try t.alice.publish(kind: "now", path: "now.json", plaintext: Data("{ }".utf8), audience: .leaders, now: 6_000)
        _ = try t.leader.fetch()
        XCTAssertEqual(try t.leader.readableHeaders().first { $0.entry.path == me + "now.json" }?.header.at, 6_000)
        XCTAssertEqual(TeamClient.HeaderCache.load(cacheURL).entries[me + "now.json"]?.header.at, 6_000)
    }

    func testReshareRewrapsHistoryToTheCurrentAudienceAfterPromotion() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        var ex = TeamExclusions(); ex.set("/r/secret", excluded: true); try ex.save(paths: t.alicePaths)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        _ = try t.leader.fetch()
        XCTAssertFalse(try header(t.leader, mine + "transcripts/s1/1.jsonl").to.contains { $0.kid == t.bob.identity.kid })

        try t.leader.promote(kid: t.bob.identity.kid, now: 2_000)
        _ = try t.alice.fetch()
        let report = try publisher.reshare(days: 10_000)
        XCTAssertEqual(Set(report.published), [
            me + "days/2026-09-04.json", me + "sessions/index.json", me + "crashes.json",
            mine + "transcripts/s1/1.jsonl", mine + "transcripts/s1/subagents/agent-a1/1.jsonl",
        ])   // never now.json: live state is stale by definition and is gone after quit
        _ = try t.bob.fetch()
        // Alice's `now.json` hint was sealed before Bob led, so his routine
        // fetch skips her transcript branch until her next publish; a
        // transcript view pulls it on demand meanwhile (#321).
        try t.bob.fetchTranscripts(from: t.alice.identity.kid)
        XCTAssertTrue(try header(t.bob, mine + "transcripts/s1/1.jsonl").to.contains { $0.kid == t.bob.identity.kid })
        XCTAssertFalse(String(decoding: try t.bob.read(mine + "transcripts/s1/1.jsonl").1, as: UTF8.self).contains("sk-ant"))
        // A zero-day window re-shares nothing.
        XCTAssertEqual(try publisher.reshare(days: 0, now: Date(timeIntervalSince1970: 4_000_000_000)).published, [])
    }

    /// The change check must not follow `Set` iteration order (finding 1
    /// of the final review): the sets ride as sorted arrays, and nothing
    /// is dropped, so a change confined to them still republishes.
    func testDayDigestIsOrderIndependentAndLossless() throws {
        var a = Stats.Day(); a.inputTokens = 3
        for s in ["s3", "s1", "s2"] { a.sessions.insert(s) }
        for r in ["zeta", "alpha"] { a.repos.insert(r) }
        a.minuteTokens = [5: 9, 7: 9]; a.peakTokensPerMinute = 9; a.peakMinute = 5
        var b = Stats.Day(); b.inputTokens = 3
        for s in ["s1", "s2", "s3"] { b.sessions.insert(s) }
        for r in ["alpha", "zeta"] { b.repos.insert(r) }
        b.minuteTokens = [7: 9, 5: 9]; b.peakTokensPerMinute = 9; b.peakMinute = 7   // the other side of the tie
        let bytes = String(decoding: try TeamPublisher.dayDigestBytes(TeamDocs.DayDoc(day: "2026-09-04", stats: a)), as: UTF8.self)
        XCTAssertTrue(bytes.contains(#""sessions":["s1","s2","s3"]"#), bytes)
        XCTAssertTrue(bytes.contains(#""repos":["alpha","zeta"]"#), bytes)
        XCTAssertTrue(bytes.contains(#""minuteTokens":{"5":9,"7":9}"#), bytes)
        XCTAssertFalse(bytes.contains("peakMinute"), bytes)
        XCTAssertEqual(try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: a)),
                       try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: b)))
        var c = b; c.sessions.insert("s4")
        XCTAssertNotEqual(try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: b)),
                          try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: c)))
        var d = b; d.repos.insert("omega")
        XCTAssertNotEqual(try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: b)),
                          try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: d)))
        var e = b; e.minuteTokens[8] = 1
        XCTAssertNotEqual(try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: b)),
                          try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: e)))
        XCTAssertNotEqual(try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-04", stats: b)),
                          try TeamPublisher.dayDigest(TeamDocs.DayDoc(day: "2026-09-05", stats: b)))
    }

    func testPendingMemberCannotPublish() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (pp, ps) = machine("pending")
        let leader = try TeamClient.create(name: "P", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let pending = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "X", devices: [],
                                             platform: "linux", paths: pp, secrets: ps, now: 1_001)
        let projects = try writeProjects(scratch)
        XCTAssertThrowsError(try TeamPublisher(client: pending, paths: pp).publish(sources: sources(projects))) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }

    /// Spec §7: a kind shared with Nobody is not chunked, not sealed, not
    /// copied and not hinted at on the store.
    func testAKindSharedWithNobodyNeverLeavesTheMac() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))   // one pass with everything on
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)

        var shares = TeamShares()
        shares.byKind[TeamKinds.stats] = .team
        shares.byKind[TeamKinds.transcripts] = .off
        try shares.save(teamDir: teamDir)
        // New lines that WOULD chunk if transcripts were still shared.
        let s1 = projects.appendingPathComponent("-r-app/s1.jsonl")
        let handle = try FileHandle(forWritingTo: s1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","timestamp":"2026-09-04T12:00:11.000Z","message":{"id":"a8","model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":1},"content":[{"type":"text","text":"nope"}]}}"#.utf8 + [UInt8(ascii: "\n")]))
        try handle.close()

        let report = try publisher.publish(sources: sources(projects))
        XCTAssertEqual(report.transcriptChunks, 0)
        XCTAssertFalse(report.published.contains { $0.contains("/transcripts/") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: publisher.copiesDir.appendingPathComponent("transcripts/s1/2.jsonl").path),
                       "an off kind is not copied to published/ either")
        // The cursor did not move: turning transcripts back on resumes where it stopped.
        XCTAssertEqual(TeamPublishState.load(teamDir: teamDir).transcripts["s1"]?.seq, 1)

        // The hint on now.json keeps the real audiences and drops the off one:
        // an older client's decoder would throw on an unknown "off".
        _ = try t.leader.fetch()
        let now = try CanonicalJSON.decode(TeamDocs.Now.self, from: try t.leader.read(me + "now.json").1)
        XCTAssertEqual(now.sharesTo["stats"], .team)
        XCTAssertNil(now.sharesTo["transcripts"])
        // Re-share does not resurrect it from the copies either.
        XCTAssertFalse(try publisher.reshare(days: 10_000).published.contains { $0.contains("/transcripts/") })
        // Defensive: nothing may seal to nobody.
        XCTAssertThrowsError(try t.alice.publish(kind: TeamKinds.stats, path: "days/2026-09-04.json",
                                                 plaintext: Data("{}".utf8), audience: .off)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .audienceOff)
        }
    }

    /// `now` off after a publish would leave this member looking "on"
    /// forever, so the stale now.json is retired once.
    func testNowSharedWithNobodyIsRetiredFromTheStore() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        _ = try publisher.publish(sources: sources(projects))
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        _ = try t.leader.fetch()
        XCTAssertTrue(try t.leader.readable().map(\.path).contains(me + "now.json"))

        var shares = TeamShares()
        shares.byKind[TeamKinds.now] = .off
        try shares.save(teamDir: teamDir)
        _ = try publisher.publish(sources: sources(projects))
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "now.json"))
        // Idempotent: the second pass has nothing left to delete and must not throw.
        XCTAssertNoThrow(try publisher.publish(sources: sources(projects)))
    }

    /// #221: the fleet doc travels to its audience, is written every
    /// pass like now.json so `at` stays truthful, and is retired once
    /// when the share row goes to Nobody.
    func testFleetIsPublishedSkippedWhileUnchangedAndRetiredWhenOff() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = sources(projects)
        let row = TeamDocs.FleetDoc.FleetRow(engine: "opaque", active: "acct-1", next: nil, tokensPerMinute: 12, accounts: [
            .init(label: "acct-1", tier: "Max", status: "ok", active: true, windows: [.init(label: "5h", pct: 40)], models: [])])
        s.fleetRows = [row]
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        let first = try publisher.publish(sources: s, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(first.published.contains(me + "fleet.json"))
        _ = try t.leader.fetch()
        let doc = try CanonicalJSON.decode(TeamDocs.FleetDoc.self, from: try t.leader.read(me + "fleet.json").1)
        XCTAssertEqual(doc.fleets, [row])
        XCTAssertEqual(doc.at, 1_000)

        let second = try publisher.publish(sources: s, now: Date(timeIntervalSince1970: 2_000))
        XCTAssertTrue(second.published.contains(me + "fleet.json"), "state: republished every pass")
        _ = try t.leader.fetch()
        XCTAssertEqual(try CanonicalJSON.decode(TeamDocs.FleetDoc.self, from: try t.leader.read(me + "fleet.json").1).at, 2_000)

        var shares = TeamShares()
        shares.byKind[TeamKinds.fleet] = .off
        try shares.save(teamDir: teamDir)
        _ = try publisher.publish(sources: s)
        _ = try t.leader.fetch()
        XCTAssertFalse(try t.leader.readable().map(\.path).contains(me + "fleet.json"))
        XCTAssertNoThrow(try publisher.publish(sources: s))
    }

    /// Spec §7: the member picks which sessions' transcripts travel; a
    /// session's sub-agents ride its choice.
    func testOnlyChosenSessionsAreChunkedAndThePickerListsTheRecentOnes() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let teamDir = t.alicePaths.teamDir(t.alice.config.id)
        var choices = TeamTranscriptChoices()
        choices.mode = .chosen
        choices.chosen = ["s1"]
        try choices.save(teamDir: teamDir)

        var s = sources(projects)
        let cacheURL = teamDir.appendingPathComponent("scan-cache.json")
        s.cacheURL = cacheURL   // the picker reads what this publish writes
        let report = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: s)
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        XCTAssertEqual(Set(report.published.filter { $0.contains("/transcripts/") }),
                       [mine + "transcripts/s1/1.jsonl", mine + "transcripts/s1/subagents/agent-a1/1.jsonl"])
        XCTAssertEqual(report.transcriptChunks, 2, "s2 was not picked; s1's sub-agent rides s1's choice")
        // The unchosen session still contributes its day and its row.
        let index = try CanonicalJSON.decode(TeamDocs.SessionsIndex.self, from: try t.alice.read(me + "sessions/index.json").1)
        XCTAssertEqual(index.sessions.map(\.id).sorted(), ["s1", "s2"])

        // What the pane's picker offers, off the same cache.
        let recent = TeamPublisher.recentTranscriptSessions(cacheURL: cacheURL, days: 10_000)
        XCTAssertEqual(recent.map(\.id).sorted(), ["s1", "s2"])
        let one = try XCTUnwrap(recent.first { $0.id == "s1" })
        XCTAssertEqual(one.project, "app")
        XCTAssertEqual(one.lastDay, "2026-09-04")
        XCTAssertGreaterThan(one.bytes, 0)
        // The day floor: nothing is recent long after the fixture's day.
        XCTAssertEqual(TeamPublisher.recentTranscriptSessions(cacheURL: cacheURL, days: 1,
                                                              now: Date(timeIntervalSince1970: 2_000_000_000)), [])
        // An excluded project is not even offered.
        var ex = TeamExclusions(); ex.set("/r/secret", excluded: true)
        XCTAssertEqual(TeamPublisher.recentTranscriptSessions(cacheURL: cacheURL, days: 10_000, exclusions: ex).map(\.id), ["s1"])
        // No cache yet (a team that never published): an empty list, not a crash.
        XCTAssertEqual(TeamPublisher.recentTranscriptSessions(cacheURL: scratch.appendingPathComponent("nope.json"), days: 10_000), [])
    }

    /// The app hands the publisher its own StatsModel scan (#251): the
    /// publisher then scans nothing — a projects dir that does not
    /// exist publishes the same set — and writes no cache of its own.
    func testAScanHandedInSkipsTheScannerAndItsCache() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let scanned = StatsScanner.scan(projectsDir: projects, cacheURL: nil).entries
        var s = sources(scratch.appendingPathComponent("nonexistent"))
        s.entries = scanned
        s.cacheURL = scratch.appendingPathComponent("never.json")
        let report = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: s)
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        XCTAssertEqual(Set(report.published), [
            me + "days/2026-09-04.json", me + "sessions/index.json", me + "now.json", me + "crashes.json",
            mine + "transcripts/s1/1.jsonl", mine + "transcripts/s1/subagents/agent-a1/1.jsonl", mine + "transcripts/s2/1.jsonl",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.cacheURL!.path))
        // The picker lists the same sessions off the same entries.
        XCTAssertEqual(TeamPublisher.recentTranscriptSessions(entries: scanned, days: 10_000).map(\.id).sorted(), ["s1", "s2"])

        // `historyDays` still bounds what goes out: ten days on with a
        // one-day window, the fixture's day is not published.
        var narrow = s
        narrow.historyDays = 1
        let later = Date(timeIntervalSince1970: 1_789_000_000)
        let second = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: narrow, now: later)
        XCTAssertFalse(second.published.contains { $0.contains("/days/") || $0.contains("/transcripts/") })
        let index = try CanonicalJSON.decode(TeamDocs.SessionsIndex.self, from: try t.alice.read(me + "sessions/index.json").1)
        XCTAssertEqual(index.sessions, [])
    }

    /// `published/` is the only part of a team dir that grows without
    /// bound (a month of transcripts was 9 GB): the oldest transcript
    /// copies go, and only those.
    func testPublishedCopiesArePrunedOldestTranscriptFirst() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = sources(projects)
        _ = try publisher.publish(sources: s)
        let copies = publisher.copiesDir
        let s1 = copies.appendingPathComponent("transcripts/s1/1.jsonl")
        let agent = copies.appendingPathComponent("transcripts/s1/subagents/agent-a1/1.jsonl")
        let s2 = copies.appendingPathComponent("transcripts/s2/1.jsonl")
        let day = copies.appendingPathComponent("days/2026-09-04.json")
        for url in [s1, agent, s2, day] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path) }
        for (url, at) in [(s1, 1_000.0), (agent, 2_000.0), (s2, 3_000.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: at)], ofItemAtPath: url.path)
        }

        s.copiesCapBytes = 1   // everything is over the cap
        let report = try publisher.publish(sources: s)
        XCTAssertEqual(report.prunedCopies, 3)
        for url in [s1, agent, s2] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: day.path), "stats copies stay — reshare needs them")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("sessions/index.json").path))
        // A cap nothing exceeds prunes nothing, and the pass still reports it.
        s.copiesCapBytes = 1 << 30
        XCTAssertEqual(try publisher.publish(sources: s).prunedCopies, 0)
    }

    /// Progress is per SOURCE and per BATCH, never per chunk: a 9 GB
    /// corpus is thousands of chunks and every main-actor hop is a CA
    /// transaction (the pop-out must idle at ~0%).
    func testProgressFiresPerSourceAndPerBatchOnly() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        // `publish` is synchronous on this thread and so is the callback,
        // but the closure is @Sendable: a captured `var` will not compile.
        final class Box: @unchecked Sendable { var seen: [TeamPublisher.Progress] = [] }
        let box = Box()
        var s = sources(projects)
        s.batchBytes = 1        // one push per source — the most callbacks this can make
        s.onProgress = { box.seen.append($0) }
        let report = try TeamPublisher(client: t.alice, paths: t.alicePaths).publish(sources: s)
        XCTAssertEqual(report.transcriptChunks, 3)
        XCTAssertFalse(report.stopped)
        XCTAssertLessThanOrEqual(box.seen.count, 3 + 3 + 1, "3 sources + 3 batches + the opening call")
        XCTAssertEqual(box.seen.first, TeamPublisher.Progress(phase: "scan", done: 0, total: 3))
        XCTAssertEqual(box.seen.last?.done, 3)
        XCTAssertEqual(Set(box.seen.map(\.phase)), ["scan", "push"])
        XCTAssertEqual(box.seen.map(\.total), Array(repeating: 3, count: box.seen.count))
        XCTAssertEqual(box.seen.map(\.done), box.seen.map(\.done).sorted(), "the counter only moves forward")
    }

    /// Quit asks the publisher to stop; what it had pushed stays pushed
    /// and the cursor is saved, so the next pass resumes.
    func testStopBetweenSourcesSavesTheCursorAndLeavesTheRestForNextTime() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        final class Box: @unchecked Sendable { var chunked = 0 }
        let box = Box()
        var s = sources(projects)
        s.batchBytes = 1
        s.onProgress = { if $0.phase == "scan" { box.chunked = $0.done } }
        s.shouldStop = { box.chunked >= 1 }      // stop once the first source is done
        let report = try publisher.publish(sources: s)
        XCTAssertTrue(report.stopped)
        XCTAssertEqual(report.transcriptChunks, 1)
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        XCTAssertTrue(report.published.contains(mine + "transcripts/s1/1.jsonl"))
        XCTAssertFalse(report.published.contains { $0.contains("/s2/") })
        let state = TeamPublishState.load(teamDir: t.alicePaths.teamDir(t.alice.config.id))
        XCTAssertEqual(state.transcripts.count, 1)
        XCTAssertEqual(state.transcripts["s1"]?.seq, 1)
        XCTAssertGreaterThan(report.remainingBytes, 0, "the sources the stop never reached count whole")
        _ = try t.leader.fetch()
        XCTAssertEqual(try t.leader.readable().map(\.path).filter { $0.contains("/transcripts/") },
                       [mine + "transcripts/s1/1.jsonl"])
        // No stop: the rest goes out, nothing is re-chunked.
        var again = sources(projects)
        again.batchBytes = 1
        let second = try publisher.publish(sources: again)
        XCTAssertFalse(second.stopped)
        XCTAssertEqual(second.transcriptChunks, 2)
    }

    /// Spec §7 catch-up: a session bigger than one pass's read slice is
    /// drained over several passes, and the report says how much is
    /// still to go (the pane shows "catching up, N MB to go").
    func testRemainingBytesCountsTheTailAndDrainsOverPasses() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = sources(projects)
        // Above the longest fixture line (~200 B, or the chunker never
        // advances) and below a whole file (~400 B).
        s.readCapBytes = 256
        let first = try publisher.publish(sources: s)
        XCTAssertGreaterThan(first.transcriptChunks, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publisher.spoolDir.path),
                       "the spool is cleared when the pass ends")

        let state = TeamPublishState.load(teamDir: t.alicePaths.teamDir(t.alice.config.id))
        var expected = 0
        for (file, key) in [("-r-app/s1.jsonl", "s1"), ("-r-secret/s2.jsonl", "s2"),
                            ("-r-app/s1/subagents/agent-a1.jsonl", "s1/subagents/agent-a1")] {
            let attrs = try FileManager.default.attributesOfItem(atPath: projects.appendingPathComponent(file).path)
            let size = try XCTUnwrap((attrs[.size] as? NSNumber)?.intValue)
            expected += size - (state.transcripts[key]?.offset ?? 0)
        }
        XCTAssertGreaterThan(expected, 0, "one 256-byte slice cannot drain a two-line transcript")
        XCTAssertEqual(first.remainingBytes, expected)

        // Later passes drain it; nothing is re-chunked and it settles at 0.
        var again = sources(projects)
        again.readCapBytes = 256
        var report = try publisher.publish(sources: again)
        var passes = 1
        while report.remainingBytes > 0, passes < 10 {
            report = try publisher.publish(sources: again)
            passes += 1
        }
        XCTAssertEqual(report.remainingBytes, 0, "the tail is published after \(passes) passes")
        XCTAssertEqual(try publisher.publish(sources: again).transcriptChunks, 0, "and nothing is left to chunk")
    }

    /// The batch never sits in the heap: every staged item is sealed to
    /// `<teamDir>/spool/<n>.bin` and git hashes the file itself.
    func testEveryStagedItemIsSealedToTheSpoolAndPushedFromThere() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = sources(projects)
        s.batchBytes = 1   // one push per source
        // A leftover from a killed pass must not be pushed as if it were ours.
        try FileManager.default.createDirectory(at: publisher.spoolDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: publisher.spoolDir.appendingPathComponent("7.bin"))

        let report = try publisher.publish(sources: s)
        XCTAssertEqual(report.transcriptChunks, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publisher.spoolDir.path))
        // The store has exactly what a pass has always had, byte for byte.
        _ = try t.leader.fetch()
        let me = "m/\(t.alice.identity.kid)/"
        let mine = "t/\(t.alice.identity.kid)/"   // transcripts live on their own branch (#321)
        XCTAssertTrue(try t.leader.readable().map(\.path).contains(mine + "transcripts/s1/1.jsonl"))
        let chunk = try t.leader.read(mine + "transcripts/s1/1.jsonl").1
        XCTAssertTrue(String(decoding: chunk, as: UTF8.self).contains("[redacted-key]"))
        XCTAssertEqual(try t.leader.read(me + "now.json").0.kind, TeamKinds.now)
    }

    /// The spool holds sealed envelopes about to reach a shared remote;
    /// it is created 0700, not the umask default.
    func testSpoolDirIsCreatedPrivate() throws {
        let t = try team()
        let projects = try writeProjects(scratch)
        let publisher = TeamPublisher(client: t.alice, paths: t.alicePaths)
        var s = sources(projects)
        s.batchBytes = 1   // forces at least one push while the spool dir still exists
        let spoolDir = publisher.spoolDir
        final class Box: @unchecked Sendable { var checked = false }
        let box = Box()
        s.onProgress = { progress in
            guard progress.phase == "push", !box.checked else { return }
            box.checked = true
            let attrs = try? FileManager.default.attributesOfItem(atPath: spoolDir.path)
            let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, 0o700, "spool dir must be private")
        }
        _ = try publisher.publish(sources: s)
        XCTAssertTrue(box.checked, "the push phase must fire while the spool dir exists")
    }
}
