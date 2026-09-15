import XCTest
@testable import InfinitusCore

final class TeamSnapshotControlsTests: XCTestCase {
    func testControlsAreWhatAMemberLetsMeDo() throws {
        let ann = TeamIdentity.random(), bo = TeamIdentity.random(), cy = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "P", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: ann.keys, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: bo.keys, name: "Bo", since: 2),
                                          TeamRoster.Member(keys: cy.keys, name: "Cy", since: 3)], rev: 1)
        var now = TeamDocs.Now(at: 10, machine: "bo", live: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: [:], desktop: true)
        now.grantsTo = [TeamDocs.GrantHint(audience: .leaders, threads: nil, capabilities: ["view", "send"]),
                        TeamDocs.GrantHint(audience: .members([cy.kid]), threads: ["t1"], capabilities: ["interrupt"])]
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: ann.kid), ["send", "view"])
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: cy.kid), ["interrupt"])
        XCTAssertNil(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: bo.kid), "nothing granted reads as nil")
        XCTAssertNil(TeamSnapshot.controls(hints: nil, roster: roster, me: ann.kid))
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: cy.kid, thread: "t1"), ["interrupt"])
        XCTAssertNil(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: cy.kid, thread: "t2"), "a thread the grant does not name")
        XCTAssertEqual(TeamSnapshot.controls(hints: now.grantsTo, roster: roster, me: ann.kid, thread: "t2"), ["send", "view"], "no thread list = every thread")
    }
}
