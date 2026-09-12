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

    // MARK: Phase 2 (#220): tiers, pre-authorization, expiry

    func testAPhaseOneFileAsksForEverythingBeyondDriveAndResavesByteIdentical() throws {
        var grants = TeamGrants()
        grants.add(audience: .team, sessions: .all, capabilities: [TeamGrants.send, TeamGrants.stop], now: 5)
        let phaseOne = String(decoding: try CanonicalJSON.encode(grants), as: UTF8.self)
        XCTAssertFalse(phaseOne.contains("preauthorized"), phaseOne)
        XCTAssertFalse(phaseOne.contains("expires"), phaseOne)
        let read = try CanonicalJSON.decode(TeamGrants.self, from: Data(phaseOne.utf8))
        XCTAssertEqual(read, grants)
        let g = try XCTUnwrap(read.grants.first)
        XCTAssertEqual(g.preauthorized, [])
        XCTAssertNil(g.expires)
        XCTAssertTrue(g.requiresApproval(TeamGrants.stop))
        XCTAssertFalse(g.requiresApproval(TeamGrants.send))
        XCTAssertFalse(g.requiresApproval(TeamGrants.view))
    }

    func testDeleteNeverRunsUnasked() {
        var grants = TeamGrants()
        let g = grants.add(audience: .team, sessions: .all,
                           capabilities: [TeamGrants.send, TeamGrants.stop, TeamGrants.delete, TeamGrants.swap],
                           preauthorized: [TeamGrants.send, TeamGrants.stop, TeamGrants.delete, TeamGrants.hold, "reboot"],
                           expires: 1_000, now: 300)
        XCTAssertEqual(g.preauthorized, [TeamGrants.stop], "drive is implicit, delete never, hold/reboot were not granted")
        XCTAssertFalse(g.requiresApproval(TeamGrants.stop))
        XCTAssertTrue(g.requiresApproval(TeamGrants.delete))
        XCTAssertTrue(g.requiresApproval(TeamGrants.swap))
        // A hand-edited file cannot pre-authorize it either.
        let hand = TeamGrants.Grant(id: "g-1", audience: .team, sessions: .all, capabilities: [TeamGrants.delete, TeamGrants.swap],
                                    since: 1, preauthorized: [TeamGrants.delete, TeamGrants.swap])
        XCTAssertTrue(hand.requiresApproval(TeamGrants.delete))
        XCTAssertFalse(hand.requiresApproval(TeamGrants.swap))
        let json = #"{"grants":[{"audience":"team","capabilities":["delete"],"id":"g-00000001","preauthorized":["delete"],"sessions":"all","since":5}],"schema":1}"#
        let edited = try? CanonicalJSON.decode(TeamGrants.self, from: Data(json.utf8))
        XCTAssertEqual(edited?.grants.first?.preauthorized, [])
        // The file carries them sorted, and the round trip holds.
        let bytes = String(decoding: (try? CanonicalJSON.encode(grants)) ?? Data(), as: UTF8.self)
        XCTAssertTrue(bytes.contains("\"preauthorized\":[\"stop\"]"), bytes)
        XCTAssertTrue(bytes.contains("\"expires\":1000"), bytes)
        XCTAssertEqual(try? CanonicalJSON.decode(TeamGrants.self, from: Data(bytes.utf8)), grants)
    }

    func testExpiryMachineScopeAndHints() {
        let r = roster(leaders: [leader], members: [member])
        var grants = TeamGrants()
        grants.add(audience: .team, sessions: .all, capabilities: [TeamGrants.stop, TeamGrants.delete, TeamGrants.swap],
                   preauthorized: [TeamGrants.stop], expires: 1_000, now: 300)
        XCTAssertNotNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.stop, roster: r, now: 999))
        XCTAssertNil(grants.permits(kid: member.kid, session: "s1", capability: TeamGrants.stop, roster: r, now: 1_000), "expired at its instant")
        // Machine-scoped: the grant's sessions are not consulted; a session action still is.
        var some = TeamGrants()
        some.add(audience: .team, sessions: .some(["s1"]), capabilities: [TeamGrants.swap, TeamGrants.stop], now: 1)
        XCTAssertNotNil(some.permits(kid: member.kid, session: TeamControl.machineSession, capability: TeamGrants.swap, roster: r))
        XCTAssertNil(some.permits(kid: member.kid, session: TeamControl.machineSession, capability: TeamGrants.stop, roster: r))
        // Hints: what asks, sorted, and when it ends; absent when nothing asks.
        XCTAssertEqual(grants.hints[0].approval, ["delete", "swap"])
        XCTAssertEqual(grants.hints[0].expires, 1_000)
        XCTAssertEqual(some.hints[0].approval, ["stop", "swap"])
        XCTAssertNil(some.hints[0].expires)
        var drive = TeamGrants()
        drive.add(audience: .team, sessions: .all, capabilities: [TeamGrants.send, TeamGrants.view], now: 1)
        XCTAssertNil(drive.hints[0].approval)
        let bytes = String(decoding: (try? CanonicalJSON.encode(drive.hints)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(bytes.contains("approval"), "a drive-only hint is byte-identical to Phase 1's")
    }

    func testTiersCoverEveryCapabilityOnce() {
        let fromTiers = TeamGrants.tiers.flatMap { $0.capabilities }
        XCTAssertEqual(Set(fromTiers), Set(TeamGrants.capabilities))
        XCTAssertEqual(fromTiers.count, Set(fromTiers).count, "no duplicates across tiers")
        for cap in TeamGrants.capabilities {
            XCTAssertNotNil(TeamGrants.meanings[cap], "\(cap) has no meaning")
        }
    }

    func testExpiryAndCapabilityLabels() {
        let now = 10_000
        let untilRevoked = TeamGrants.Grant(id: "g-1", audience: .team, sessions: .all, capabilities: [TeamGrants.send], since: 1)
        XCTAssertEqual(untilRevoked.expiryLabel(now: now), "until revoked")
        func withExpiry(_ expires: Int) -> TeamGrants.Grant {
            TeamGrants.Grant(id: "g-1", audience: .team, sessions: .all, capabilities: [TeamGrants.send], since: 1, expires: expires)
        }
        XCTAssertEqual(withExpiry(now + 90).expiryLabel(now: now), "expires in 1 m")
        XCTAssertEqual(withExpiry(now + 7_500).expiryLabel(now: now), "expires in 2 h 05 m")
        XCTAssertEqual(withExpiry(now + 3 * 86_400).expiryLabel(now: now), "expires in 3 d")
        XCTAssertEqual(withExpiry(now - 1).expiryLabel(now: now), "expired")
        let g = TeamGrants.Grant(id: "g-1", audience: .team, sessions: .all,
                                 capabilities: [TeamGrants.send, TeamGrants.stop, TeamGrants.hold], since: 1,
                                 preauthorized: [TeamGrants.hold])
        XCTAssertEqual(g.capabilitiesLabel(), "hold (no ask), send, stop (asks)")
    }
}
