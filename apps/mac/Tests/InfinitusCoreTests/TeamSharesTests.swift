import XCTest
@testable import InfinitusCore

/// The "Nobody" audience (spec §1 audiences, §7 per-kind choice).
final class TeamSharesTests: XCTestCase {
    func testOffRoundTripsAsAStringAndParsesFromTheCLISpelling() throws {
        XCTAssertEqual(String(decoding: try CanonicalJSON.encode(TeamRoster.ShareTarget.off), as: UTF8.self), "\"off\"")
        XCTAssertEqual(try CanonicalJSON.decode(TeamRoster.ShareTarget.self, from: Data("\"off\"".utf8)), .off)
        XCTAssertEqual(TeamShares.parseTarget(["off"]), .off)
        XCTAssertEqual(TeamShares.parseTarget(["nobody"]), .off)
        // The other spellings are untouched.
        XCTAssertEqual(TeamShares.parseTarget(["leaders"]), .leaders)
        XCTAssertEqual(TeamShares.parseTarget(["team"]), .team)
        XCTAssertEqual(TeamShares.parseTarget(["k1,k2"]), .members(["k1", "k2"]))
        XCTAssertNil(TeamShares.parseTarget([]))
    }

    func testNobodyIsNobodyEvenWithAFullRoster() {
        let leader = TeamIdentity.random().keys, member = TeamIdentity.random().keys
        let roster = TeamRoster(id: "t", name: "Papaya", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: leader, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: member, name: "Bo", since: 2)], rev: 1)
        XCTAssertEqual(roster.recipients(for: .off), [])
        XCTAssertEqual(roster.recipients(for: .leaders).map(\.kid), [leader.kid])
        XCTAssertEqual(Set(roster.recipients(for: .team).map(\.kid)), [leader.kid, member.kid])
    }

    /// An unset kind still means "leaders" — `.off` is a choice, never a default.
    func testTheDefaultIsStillLeaders() {
        XCTAssertEqual(TeamShares().target(for: TeamKinds.transcripts), .leaders)
    }
}
