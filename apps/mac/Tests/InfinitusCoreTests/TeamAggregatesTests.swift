import XCTest
@testable import InfinitusCore

final class TeamAggregatesTests: XCTestCase {
    var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aggr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }
    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name)); return (paths, FileSecrets(dir: paths.secretsDir))
    }
    func team() throws -> (leader: TeamClient, member: TeamClient) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (mp, ms) = machine("member")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let member = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Bo", devices: [], platform: "linux", paths: mp, secrets: ms, now: 1_010)
        _ = try leader.fetch(); try leader.approve(kid: member.identity.kid, now: 1_020); _ = try member.fetch()
        return (leader, member)
    }

    func testAggregatesDocumentRespectsThePolicy() throws {
        let l = TeamIdentity.random(), a = TeamIdentity.random()
        var roster = TeamRoster(id: "t", name: "T", createdAt: 1, leaders: [TeamRoster.Member(keys: l.keys, name: "Lee", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: a.keys, name: "Ann", since: 2)], rev: 1)
        let now = Date(timeIntervalSince1970: 1_788_609_600)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var day = Stats.Day(); day.usd = 2; day.commits = 1; day.hours[5] = 3
        let doc = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-05", stats: day))
        let reader = TeamReader.fold(headers: [(StoreEntry(path: "m/\(a.kid)/days/2026-09-05.json", size: 1, version: "v"),
                                                Envelope.Header(v: 1, kind: "stats", from: a.kid, eph: "", to: [], at: 5, nonce: "", sig: nil))],
                                     roster: roster) { _ in doc }
        let closed = TeamInsights.aggregates(reader, roster: roster, period: .week, now: now, calendar: cal)
        XCTAssertEqual(closed.schema, 1); XCTAssertEqual(closed.period, "week"); XCTAssertEqual(closed.members, 2)
        XCTAssertEqual(closed.total.usd, 2, accuracy: 0.001); XCTAssertEqual(closed.total.commits, 1); XCTAssertEqual(closed.hours[5], 3)
        XCTAssertNil(closed.perMember, "membersSeeEachOther is off")
        XCTAssertEqual(closed.total.sessions, [], "compacted: sets emptied")
        roster.policy.membersSeeEachOther = true
        let open = TeamInsights.aggregates(reader, roster: roster, period: .week, now: now, calendar: cal)
        XCTAssertEqual(open.perMember?.map(\.name), ["Lee", "Ann"])
        XCTAssertEqual(open.perMember?[1].usd ?? 0, 2, accuracy: 0.001)
    }

    func testAggregatesNeverRepublishRemovedSenders() throws {
        let l = TeamIdentity.random(), a = TeamIdentity.random(), gone = TeamIdentity.random()
        var roster = TeamRoster(id: "t", name: "T", createdAt: 1, leaders: [TeamRoster.Member(keys: l.keys, name: "Lee", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: a.keys, name: "Ann", since: 2)], rev: 1)
        roster.policy.membersSeeEachOther = true
        var day = Stats.Day(); day.usd = 2
        let doc = try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-05", stats: day))
        let headers = [a.kid, gone.kid].map { kid in
            (StoreEntry(path: "m/\(kid)/days/2026-09-05.json", size: 1, version: "v"),
             Envelope.Header(v: 1, kind: "stats", from: kid, eph: "", to: [], at: 5, nonce: "", sig: nil))
        }
        let reader = TeamReader.fold(headers: headers, roster: roster) { _ in doc }
        XCTAssertEqual(reader.members[gone.kid]?.role, "removed", "pre-removal history still folds")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let open = TeamInsights.aggregates(reader, roster: roster, period: .week, now: Date(timeIntervalSince1970: 1_788_609_600), calendar: cal)
        XCTAssertEqual(open.perMember?.map(\.name), ["Lee", "Ann"])
        XCTAssertEqual(open.perMember?.count, open.members)
    }

    func testLeaderPublishesAndMemberReadsAggregates() throws {
        let (leader, member) = try team()
        let now = Date(timeIntervalSince1970: 1_788_609_600)
        let roster = leader.roster!.doc
        let doc = TeamInsights.aggregates(try TeamReader.load(client: leader), roster: roster, period: .week, now: now)
        let paths = try leader.publishAggregates(["week": try CanonicalJSON.encode(doc)], now: 2_000)
        XCTAssertEqual(paths, ["roster/aggregates/week.json"])
        _ = try member.fetch()
        let reader = try TeamReader.load(client: member)
        XCTAssertEqual(reader.aggregates["week"]?.period, "week")
        XCTAssertEqual(reader.aggregates["week"]?.members, 2)
        XCTAssertThrowsError(try member.publishAggregates(["week": Data("{}".utf8)], now: 2_001)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader)
        }
    }

    func testAggregatesFromANonLeaderAreIgnored() throws {
        let (leader, member) = try team()
        // A member with store access writes an envelope under the leaders' path.
        let forged = try Envelope.seal(Data("{\"schema\":1}".utf8), kind: TeamKinds.aggregates, from: member.identity,
                                       to: member.roster!.doc.recipients(for: .team), at: 2_000)
        try member.store.put("roster/aggregates/week.json", forged)
        _ = try leader.fetch()
        XCTAssertNil(try TeamReader.load(client: leader).aggregates["week"])
        XCTAssertNil(try TeamReader.load(client: leader).members[member.identity.kid]?.kinds.first { $0 == TeamKinds.aggregates }, "not counted as the member's kind either")
    }

    func testPolicyOffHidesRequestsAndTheCode() throws {
        let (leader, member) = try team()
        XCTAssertNoThrow(try leader.code(expiresIn: 60, now: 3_000))
        try leader.setPolicy(TeamRoster.Policy(requests: "off", membersSeeEachOther: true))
        XCTAssertEqual(leader.roster?.doc.policy.requests, "off")
        XCTAssertEqual(leader.roster?.doc.rev, 3)
        XCTAssertThrowsError(try leader.code(expiresIn: 60, now: 3_001)) { XCTAssertEqual($0 as? TeamClient.ClientError, .requestsOff) }
        XCTAssertEqual(try leader.requests(), [])
        _ = try member.fetch()
        XCTAssertEqual(member.roster?.doc.policy.membersSeeEachOther, true)
        XCTAssertThrowsError(try member.setPolicy(TeamRoster.Policy())) { XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader) }
    }
}
