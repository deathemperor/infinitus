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
        grants.add(audience: .leaders, sessions: .all, capabilities: [TeamGrants.send], now: 300)
        let r = roster(leaders: [leader], members: [member])
        XCTAssertNotNil(grants.permits(kid: leader.kid, session: "s1", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.send, roster: r), "not a leader")
        // The roster moves: a promoted member now matches "leaders" without touching the grant.
        let promoted = roster(leaders: [leader, member], members: [])
        XCTAssertNotNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.send, roster: promoted))
        XCTAssertNil(grants.permits(kid: stranger.kid, session: "s1", capability: TeamGrants.send, roster: promoted))
        // Named kids: only those, whatever their role; a kid no longer in the roster never matches.
        var named = TeamGrants()
        named.add(audience: .members([other.kid]), sessions: .all, capabilities: [TeamGrants.view], now: 300)
        XCTAssertNil(named.permits(kid: other.kid, session: "s1", capability: TeamGrants.view, roster: r), "other is not in this roster")
        XCTAssertNotNil(named.permits(kid: other.kid, session: "s1", capability: TeamGrants.view,
                                      roster: roster(leaders: [leader], members: [member, other])))
        XCTAssertNil(named.permits(kid: leader.kid, session: "s1", capability: TeamGrants.view, roster: r), "leaders only when named")
    }

    func testSessionsAndCapabilitiesAreExactSubsets() {
        var grants = TeamGrants()
        grants.add(audience: .team, sessions: .some(["s1", "s2"]), capabilities: [TeamGrants.send, TeamGrants.view], now: 300)
        let r = roster(leaders: [leader], members: [member])
        XCTAssertNotNil(grants.permits(kid: member.kid, session: "s2", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s3", capability: TeamGrants.send, roster: r))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.approve, roster: r), "send does not imply approve")
        XCTAssertNil(grants.permits(kid: member.kid, session: "s1", capability: "reboot", roster: r), "unknown capability never matches")
        // Two grants: the first that permits wins; removing it falls through to none.
        let g = grants.add(audience: .members([member.kid]), sessions: .all, capabilities: [TeamGrants.approve], now: 301)
        XCTAssertEqual(grants.permits(kid: member.kid, session: "s9", capability: TeamGrants.approve, roster: r)?.id, g.id)
        XCTAssertTrue(grants.remove(id: g.id))
        XCTAssertFalse(grants.remove(id: g.id))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s9", capability: TeamGrants.approve, roster: r))
    }

    func testFileRoundTripAndEmptyDefault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(TeamGrants.load(teamDir: dir).grants, [], "missing file is no grants")
        var grants = TeamGrants()
        grants.add(audience: .members([member.kid]), sessions: .some(["s1"]), capabilities: [TeamGrants.send], now: 300)
        try grants.save(teamDir: dir)
        XCTAssertEqual(TeamGrants.load(teamDir: dir), grants)
        let json = String(decoding: try Data(contentsOf: TeamGrants.file(teamDir: dir)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"sessions\":[\"s1\"]"), json)
        XCTAssertTrue(json.contains("\"audience\":[\"\(member.kid)\"]"), json)
        var all = TeamGrants()
        all.add(audience: .team, sessions: .all, capabilities: [TeamGrants.view], now: 1)
        let allJSON = String(decoding: try CanonicalJSON.encode(all), as: UTF8.self)
        XCTAssertTrue(allJSON.contains("\"sessions\":\"all\""), allJSON)
        XCTAssertEqual(try CanonicalJSON.decode(TeamGrants.self, from: Data(allJSON.utf8)), all)
        // Garbage on disk reads as empty, never throws.
        try Data("{".utf8).write(to: TeamGrants.file(teamDir: dir))
        XCTAssertEqual(TeamGrants.load(teamDir: dir).grants, [])
    }

    func testHintsCarryNoIdsAndKeepOrder() {
        var grants = TeamGrants()
        grants.add(audience: .leaders, sessions: .all, capabilities: [TeamGrants.view, TeamGrants.send], now: 1)
        grants.add(audience: .members(["k1"]), sessions: .some(["s1"]), capabilities: [TeamGrants.key], now: 2)
        let hints = grants.hints
        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(hints[0].audience, .leaders)
        XCTAssertEqual(hints[0].capabilities, ["send", "view"], "sorted for a stable now.json")
        XCTAssertEqual(hints[1].sessions, ["s1"])
        XCTAssertNil(hints[0].sessions, "all is nil in the hint")
    }
}
