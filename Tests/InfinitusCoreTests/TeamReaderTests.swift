import XCTest
@testable import InfinitusCore

final class TeamReaderTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    // MARK: pure folding

    func entry(_ path: String, kind: String, from: String, at: Int) -> (entry: StoreEntry, header: Envelope.Header) {
        (StoreEntry(path: path, size: 1, version: "v"),
         Envelope.Header(v: 1, kind: kind, from: from, eph: "", to: [], at: at, nonce: "", sig: nil))
    }

    func testFoldGroupsPerMemberSumsDaysAndOrdersChunks() throws {
        let l = TeamIdentity.random(), a = TeamIdentity.random(), b = TeamIdentity.random(), gone = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: l.keys, name: "L", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: a.keys, name: "A", since: 2), TeamRoster.Member(keys: b.keys, name: "B", since: 3)],
                                removed: [TeamRoster.Removed(kid: gone.kid, at: 900, keys: gone.keys)], rev: 4)
        var d1 = Stats.Day(); d1.inputTokens = 10; d1.commits = 1
        var d2 = Stats.Day(); d2.inputTokens = 5
        var docs: [String: Data] = [:]
        docs["m/\(a.kid)/days/2026-09-04.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-04", stats: d1))
        docs["m/\(b.kid)/days/2026-09-04.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-04", stats: d2))
        docs["m/\(b.kid)/days/2026-09-03.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-03", stats: d2))
        docs["m/\(a.kid)/now.json"] = try CanonicalJSON.encode(TeamDocs.Now(at: 50, sessions: [], fleets: [], blockers: ["aws"], crashesToday: 0, sharesTo: [:]))
        docs["m/\(a.kid)/crashes.json"] = try CanonicalJSON.encode(TeamDocs.Crashes(crashes: ["Mac · crash · x"]))
        docs["m/\(a.kid)/sessions/index.json"] = try CanonicalJSON.encode(TeamDocs.SessionsIndex(at: 50, sessions: [TeamDocs.SessionRow(id: "s1", project: "app", engine: "claude")], fleets: []))
        docs["m/\(b.kid)/days/2026-09-02.json"] = Data("{\"schema\":9}".utf8)      // unknown schema: skipped
        docs["m/\(gone.kid)/days/2026-09-01.json"] = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-01", stats: d2))
        let headers = [
            entry("m/\(a.kid)/days/2026-09-04.json", kind: "stats", from: a.kid, at: 40),
            entry("m/\(b.kid)/days/2026-09-04.json", kind: "stats", from: b.kid, at: 41),
            entry("m/\(b.kid)/days/2026-09-03.json", kind: "stats", from: b.kid, at: 42),
            entry("m/\(b.kid)/days/2026-09-02.json", kind: "stats", from: b.kid, at: 43),
            entry("m/\(a.kid)/now.json", kind: "now", from: a.kid, at: 50),
            entry("m/\(a.kid)/crashes.json", kind: "crashes", from: a.kid, at: 30),
            entry("m/\(a.kid)/sessions/index.json", kind: "sessions", from: a.kid, at: 50),
            entry("t/\(a.kid)/transcripts/s1/10.jsonl", kind: "transcripts", from: a.kid, at: 60),   // after the split (#321)
            entry("m/\(a.kid)/transcripts/s1/2.jsonl", kind: "transcripts", from: a.kid, at: 55),
            entry("m/\(a.kid)/transcripts/s1/subagents/agent-a/1.jsonl", kind: "transcripts", from: a.kid, at: 56),
            entry("m/\(gone.kid)/days/2026-09-01.json", kind: "stats", from: gone.kid, at: 800),
        ]
        var reads: [String] = []
        let reader = TeamReader.fold(headers: headers, roster: roster) { path in
            reads.append(path)
            guard let d = docs[path] else { throw Envelope.EnvelopeError.malformed }
            return d
        }
        XCTAssertEqual(Set(reader.members.keys), [l.kid, a.kid, b.kid, gone.kid])
        XCTAssertEqual(reader.members[l.kid]?.role, "leader")
        XCTAssertEqual(reader.members[a.kid]?.role, "member")
        XCTAssertEqual(reader.members[gone.kid]?.role, "removed")
        XCTAssertEqual(reader.members[a.kid]?.since, 2)
        XCTAssertEqual(reader.members[gone.kid]?.removedAt, 900)   // #219: the roster's removal instant
        XCTAssertNil(reader.members[gone.kid]?.since)
        XCTAssertEqual(reader.members[a.kid]?.name, "A")
        XCTAssertEqual(reader.members[a.kid]?.days["2026-09-04"]?.inputTokens, 10)
        XCTAssertEqual(reader.members[b.kid]?.days.count, 2)
        XCTAssertEqual(reader.members[a.kid]?.now?.blockers, ["aws"])
        XCTAssertEqual(reader.members[a.kid]?.crashes, ["Mac · crash · x"])
        XCTAssertEqual(reader.members[a.kid]?.sessions.map(\.id), ["s1"])
        XCTAssertEqual(reader.members[a.kid]?.transcripts["s1"],
                       ["m/\(a.kid)/transcripts/s1/2.jsonl", "t/\(a.kid)/transcripts/s1/10.jsonl"])   // numeric seq order, across both branches
        XCTAssertEqual(reader.members[a.kid]?.transcripts["s1/subagents/agent-a"]?.count, 1)
        XCTAssertEqual(reader.members[a.kid]?.lastPublished, 60)
        XCTAssertEqual(reader.members[a.kid]?.kinds, ["stats", "now", "crashes", "sessions", "transcripts"])
        XCTAssertEqual(reader.members[l.kid]?.kinds, [])
        XCTAssertNil(reader.members[l.kid]?.lastPublished)
        XCTAssertFalse(reads.contains { $0.contains("transcripts/") })   // chunks are read on demand
        XCTAssertEqual(reader.teamDays()["2026-09-04"]?.inputTokens, 15)
        XCTAssertEqual(reader.teamDays()["2026-09-01"]?.inputTokens, 5)   // pre-removal history counts

        let noon = Stats.date(fromDayKey: "2026-09-04")!.addingTimeInterval(12 * 3600)
        let summary = try XCTUnwrap(reader.summary(kid: b.kid, period: .day, now: noon))
        XCTAssertEqual(summary.total.inputTokens, 5)
        XCTAssertEqual(summary.previous.inputTokens, 5)
        XCTAssertNil(reader.summary(kid: "stranger", period: .day, now: noon))
    }

    // MARK: the spec §11 integration flow

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

    /// One project, one session (10 input tokens) whose prompt carries a key.
    func writeProjects(_ root: URL, name: String) throws -> URL {
        let projects = root.appendingPathComponent("\(name)-projects")
        let app = projects.appendingPathComponent("-r-app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let text = #"{"type":"user","cwd":"/r/app","timestamp":"2026-09-04T12:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"use sk-ant-api03-abcdefghijklmnopqrstuvwxyz please"}}"# + "\n"
            + #"{"type":"assistant","timestamp":"2026-09-04T12:00:05.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1},"content":[{"type":"text","text":"sure"}]}}"# + "\n"
        try text.write(to: app.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        return projects
    }

    func testFoldKeepsCommandPathsAndDecodesAcks() throws {
        let g = TeamIdentity.random(), d = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: g.keys, name: "G", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: d.keys, name: "D", since: 2)], removed: [], rev: 2)
        let ack = TeamControl.Ack(id: "c-0123456789", outcome: "delivered", detail: nil, at: 5)
        let docs = ["m/\(g.kid)/control/acks/c-0123456789.json": try CanonicalJSON.encode(ack)]
        let headers = [entry("m/\(d.kid)/control/commands/c-0123456789.json", kind: TeamKinds.command, from: d.kid, at: 4),
                       entry("m/\(g.kid)/control/acks/c-0123456789.json", kind: TeamKinds.ack, from: g.kid, at: 5)]
        let reader = TeamReader.fold(headers: headers, roster: roster) { docs[$0] ?? Data() }
        XCTAssertEqual(reader.members[d.kid]?.commands, ["m/\(d.kid)/control/commands/c-0123456789.json"])
        XCTAssertEqual(reader.members[g.kid]?.acks["c-0123456789"], ack)
        XCTAssertEqual(reader.ackIDs, ["c-0123456789"])
    }

    func testCreateCodeRequestApprovePublishFetchReadThenRemove() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (ap, asec) = machine("alice"), (bp, bs) = machine("bob")
        // create → code → request → approve
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let alice = try TeamClient.request(code: code, name: "Alice", devices: ["Mac"], platform: "macos", paths: ap, secrets: asec, now: 1_010)
        let bob = try TeamClient.request(code: code, name: "Bob", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_011)
        _ = try leader.fetch()
        try leader.approve(kid: alice.identity.kid, now: 1_020)
        try leader.approve(kid: bob.identity.kid, now: 1_021)
        _ = try alice.fetch(); _ = try bob.fetch()

        // publish (two members, same day) → fetch → read
        var s = TeamPublisher.Sources(projectsDir: try writeProjects(scratch, name: "alice"), home: "/Users/alice")
        // The fixture is stamped 2026-09-04; both windows are widened so
        // the test does not go red the day the transcript floor passes it.
        s.historyDays = 10_000; s.transcriptDays = 10_000
        _ = try TeamPublisher(client: alice, paths: ap).publish(sources: s)
        var sb = TeamPublisher.Sources(projectsDir: try writeProjects(scratch, name: "bob"), home: "/home/bob")
        sb.historyDays = 10_000; sb.transcriptDays = 10_000
        _ = try TeamPublisher(client: bob, paths: bp).publish(sources: sb)
        _ = try leader.fetch()
        let reader = try TeamReader.load(client: leader)
        XCTAssertEqual(reader.members[alice.identity.kid]?.days["2026-09-04"]?.inputTokens, 10)
        XCTAssertEqual(reader.members[bob.identity.kid]?.days["2026-09-04"]?.inputTokens, 10)
        XCTAssertEqual(reader.teamDays()["2026-09-04"]?.inputTokens, 20)
        XCTAssertEqual(reader.members[alice.identity.kid]?.sessions.map(\.project), ["app"])
        let items = try reader.transcript(kid: alice.identity.kid, session: "s1", client: leader)
        XCTAssertEqual(items.map(\.kind), [.user, .result])
        // Optional lookups: a regression fails here instead of trapping
        // the whole test process on `items[0]`.
        XCTAssertEqual(items.first?.text, "use [redacted-key] please")
        XCTAssertEqual(items.dropFirst().first?.text, "sure")
        XCTAssertEqual(try reader.transcript(kid: alice.identity.kid, session: "nope", client: leader), [])

        // Members see nothing of each other by default (leaders audience).
        _ = try bob.fetch()
        XCTAssertEqual(try TeamReader.load(client: bob).members[alice.identity.kid]?.kinds, [])

        // remove → a later publish is ignored; what came before stays.
        // Times are real-clock relative: the envelopes above were sealed
        // at Date(), so the removal instant must sit after them.
        let removedAt = Int(Date().timeIntervalSince1970) + 10
        try leader.remove(kid: bob.identity.kid, now: removedAt)
        _ = try TeamPublisher(client: bob, paths: bp).publish(sources: sb,
                                                              now: Date(timeIntervalSince1970: Double(removedAt + 10)))   // bob still holds rev 3
        _ = try leader.fetch()
        let after = try TeamReader.load(client: leader)
        XCTAssertEqual(after.members[bob.identity.kid]?.role, "removed")
        XCTAssertEqual(after.members[bob.identity.kid]?.removedAt, removedAt)
        XCTAssertEqual(after.members[bob.identity.kid]?.days["2026-09-04"]?.inputTokens, 10)   // sealed before removal
        XCTAssertNil(after.members[bob.identity.kid]?.now)                                    // now.json was re-sealed after removal
        _ = try bob.fetch()
        XCTAssertThrowsError(try TeamPublisher(client: bob, paths: bp).publish(sources: sb)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }
}
