import XCTest
@testable import InfinitusCore

final class TeamSnapshotControlsTests: XCTestCase {
    func testControlsAreWhatAMemberLetsMeDo() throws {
        let ann = TeamIdentity.random(), bo = TeamIdentity.random(), cy = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "P", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: ann.keys, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: bo.keys, name: "Bo", since: 2),
                                          TeamRoster.Member(keys: cy.keys, name: "Cy", since: 3)], rev: 1)
        var now = TeamDocs.Now(at: 10, sessions: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: [:])
        now.grantsTo = [TeamDocs.GrantHint(audience: .leaders, sessions: nil, capabilities: ["view", "send"]),
                        TeamDocs.GrantHint(audience: .members([cy.kid]), sessions: ["s1"], capabilities: ["approve"])]
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: ann.kid), ["send", "view"])
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: cy.kid), ["approve"])
        XCTAssertNil(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: bo.kid), "nothing granted reads as nil")
        XCTAssertNil(TeamSnapshot.controls(hints: nil, roster: roster, me: ann.kid))
    }
}
