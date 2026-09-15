import XCTest
@testable import InfinitusCore

final class TeamGrantsTests: XCTestCase {
    let leader = TeamIdentity.random()
    let member = TeamIdentity.random()
    let other = TeamIdentity.random()
    let stranger = TeamIdentity.random()

    func roster(leaders: [TeamIdentity], members: [TeamIdentity]) -> TeamRoster {
        TeamRoster(id: "team-1", name: "Papaya", createdAt: 100,
                   leaders: leaders.map { TeamRoster.Member(keys: $0.keys, name: "L", since: 100, founder: true) },
                   members: members.map { TeamRoster.Member(keys: $0.keys, name: "M", since: 200) },
                   rev: 1)
    }

    func testAudienceFollowsTheRosterAndStrangersNeverMatch() {
        var grants = TeamGrants()
        grants.add(audience: .leaders, threads: .all, capabilities: [TeamGrants.send], now: 300)
        let r = roster(leaders: [leader], members: [member])
        XCTAssertNotNil(grants.permits(kid: leader.kid, thread: "t1", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, thread: "t1", capability: TeamGrants.send, roster: r), "not a leader")
        // The roster moves: a promoted member now matches "leaders" without touching the grant.
        let promoted = roster(leaders: [leader, member], members: [])
        XCTAssertNotNil(grants.permits(kid: member.kid, thread: "t1", capability: TeamGrants.send, roster: promoted))
        XCTAssertNil(grants.permits(kid: stranger.kid, thread: "t1", capability: TeamGrants.send, roster: promoted))
        // Named kids: only those, whatever their role; a kid no longer in the roster never matches.
        var named = TeamGrants()
        named.add(audience: .members([other.kid]), threads: .all, capabilities: [TeamGrants.view], now: 300)
        XCTAssertNil(named.permits(kid: other.kid, thread: "t1", capability: TeamGrants.view, roster: r), "other is not in this roster")
        XCTAssertNotNil(named.permits(kid: other.kid, thread: "t1", capability: TeamGrants.view,
                                      roster: roster(leaders: [leader], members: [member, other])))
        XCTAssertNil(named.permits(kid: leader.kid, thread: "t1", capability: TeamGrants.view, roster: r), "leaders only when named")
    }

    func testThreadsAndCapabilitiesAreExactSubsets() {
        var grants = TeamGrants()
        grants.add(audience: .team, threads: .some(["t1", "t2"]), capabilities: [TeamGrants.send, TeamGrants.view], now: 300)
        let r = roster(leaders: [leader], members: [member])
        XCTAssertNotNil(grants.permits(kid: member.kid, thread: "t2", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, thread: "t3", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, thread: "t1", capability: TeamGrants.interrupt, roster: r), "send does not imply interrupt")
        XCTAssertNil(grants.permits(kid: member.kid, thread: "t1", capability: "reboot", roster: r), "unknown capability never matches")
        // Two grants: the first that permits wins; removing it falls through to none.
        let g = grants.add(audience: .members([member.kid]), threads: .all, capabilities: [TeamGrants.interrupt], now: 301)
        XCTAssertEqual(grants.permits(kid: member.kid, thread: "t9", capability: TeamGrants.interrupt, roster: r)?.id, g.id)
        XCTAssertTrue(grants.remove(id: g.id))
        XCTAssertFalse(grants.remove(id: g.id))
        XCTAssertNil(grants.permits(kid: member.kid, thread: "t9", capability: TeamGrants.interrupt, roster: r))
    }

    func testFileRoundTripAndEmptyDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(TeamGrants.load(teamDir: dir).grants, [], "missing file is no grants")
        var grants = TeamGrants()
        grants.add(audience: .members([member.kid]), threads: .some(["t1"]), capabilities: [TeamGrants.send], now: 300)
        try grants.save(teamDir: dir)
        XCTAssertEqual(TeamGrants.load(teamDir: dir), grants)
        let json = String(decoding: try Data(contentsOf: TeamGrants.file(teamDir: dir)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"threads\":[\"t1\"]"), json)
        XCTAssertTrue(json.contains("\"audience\":[\"\(member.kid)\"]"), json)
        var all = TeamGrants()
        all.add(audience: .team, threads: .all, capabilities: [TeamGrants.view], now: 1)
        let allJSON = String(decoding: try CanonicalJSON.encode(all), as: UTF8.self)
        XCTAssertTrue(allJSON.contains("\"threads\":\"all\""), allJSON)
        XCTAssertEqual(try CanonicalJSON.decode(TeamGrants.self, from: Data(allJSON.utf8)), all)
        // Garbage on disk reads as empty, never throws.
        try Data("{".utf8).write(to: TeamGrants.file(teamDir: dir))
        XCTAssertEqual(TeamGrants.load(teamDir: dir).grants, [])
    }

    func testHintsCarryNoIdsAndKeepOrder() {
        var grants = TeamGrants()
        grants.add(audience: .leaders, threads: .all, capabilities: [TeamGrants.view, TeamGrants.send], now: 1)
        grants.add(audience: .members(["k1"]), threads: .some(["t1"]), capabilities: [TeamGrants.interrupt], now: 2)
        let hints = grants.hints
        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(hints[0].audience, .leaders)
        XCTAssertEqual(hints[0].capabilities, ["send", "view"], "sorted for a stable now.json")
        XCTAssertEqual(hints[1].threads, ["t1"])
        XCTAssertNil(hints[0].threads, "all is nil in the hint")
    }

    func testTheDriveSetNeverAsksAndTheRestAsksUnlessPreauthorised() throws {
        var grants = TeamGrants()
        grants.add(audience: .team, threads: .all, capabilities: [TeamGrants.send, TeamGrants.interrupt], now: 5)
        let plain = String(decoding: try CanonicalJSON.encode(grants), as: UTF8.self)
        XCTAssertFalse(plain.contains("preauthorized"), plain)
        XCTAssertFalse(plain.contains("expires"), plain)
        let read = try CanonicalJSON.decode(TeamGrants.self, from: Data(plain.utf8))
        XCTAssertEqual(read, grants)
        let g = try XCTUnwrap(read.grants.first)
        XCTAssertEqual(g.preauthorized, [])
        XCTAssertNil(g.expires)
        XCTAssertTrue(g.requiresApproval(TeamGrants.interrupt))
        XCTAssertFalse(g.requiresApproval(TeamGrants.send))
        XCTAssertFalse(g.requiresApproval(TeamGrants.view))
        // Pre-authorisation: only what was granted, never the drive set (implicit), unknown names dropped.
        var pre = TeamGrants()
        let p = pre.add(audience: .team, threads: .all, capabilities: [TeamGrants.send, TeamGrants.interrupt, TeamGrants.new],
                        preauthorized: [TeamGrants.send, TeamGrants.interrupt, "reboot"], expires: 1_000, now: 300)
        XCTAssertEqual(p.preauthorized, [TeamGrants.interrupt])
        XCTAssertFalse(p.requiresApproval(TeamGrants.interrupt))
        XCTAssertTrue(p.requiresApproval(TeamGrants.new))
        let bytes = String(decoding: try CanonicalJSON.encode(pre), as: UTF8.self)
        XCTAssertTrue(bytes.contains("\"preauthorized\":[\"interrupt\"]"), bytes)
        XCTAssertTrue(bytes.contains("\"expires\":1000"), bytes)
        XCTAssertEqual(try CanonicalJSON.decode(TeamGrants.self, from: Data(bytes.utf8)), pre)
    }

    func testExpiryMachineScopeAndHints() {
        let r = roster(leaders: [leader], members: [member])
        var grants = TeamGrants()
        grants.add(audience: .team, threads: .all, capabilities: [TeamGrants.interrupt, TeamGrants.new],
                   preauthorized: [TeamGrants.interrupt], expires: 1_000, now: 300)
        XCTAssertNotNil(grants.permits(kid: member.kid, thread: "t1", capability: TeamGrants.interrupt, roster: r, now: 999))
        XCTAssertNil(grants.permits(kid: member.kid, thread: "t1", capability: TeamGrants.interrupt, roster: r, now: 1_000), "expired at its instant")
        // Machine-scoped: the grant's threads are not consulted; a thread action still is.
        var some = TeamGrants()
        some.add(audience: .team, threads: .some(["t1"]), capabilities: [TeamGrants.new, TeamGrants.interrupt], now: 1)
        XCTAssertNotNil(some.permits(kid: member.kid, thread: TeamControl.machineThread, capability: TeamGrants.new, roster: r))
        XCTAssertNil(some.permits(kid: member.kid, thread: TeamControl.machineThread, capability: TeamGrants.interrupt, roster: r))
        // Hints: what asks, sorted, and when it ends; absent when nothing asks.
        XCTAssertEqual(grants.hints[0].approval, ["new"])
        XCTAssertEqual(grants.hints[0].expires, 1_000)
        XCTAssertEqual(some.hints[0].approval, ["interrupt", "new"])
        XCTAssertNil(some.hints[0].expires)
        var drive = TeamGrants()
        drive.add(audience: .team, threads: .all, capabilities: [TeamGrants.send, TeamGrants.view], now: 1)
        XCTAssertNil(drive.hints[0].approval)
        let bytes = String(decoding: (try? CanonicalJSON.encode(drive.hints)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(bytes.contains("approval"), "a drive-only hint carries no approval key")
    }
}
