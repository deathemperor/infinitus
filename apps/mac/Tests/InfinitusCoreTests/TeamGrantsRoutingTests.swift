import XCTest
@testable import InfinitusCore

final class TeamGrantsRoutingTests: XCTestCase {
    func testGrantRoutesItsFlagsAndOptions() {
        let request = TeamGrantsRouting.request(
            sub: "grant", positional: ["leaders"],
            options: ["sessions": "a,b", "pre": "stop", "expires": "600"],
            flags: ["send", "stop", "json"])
        XCTAssertEqual(request?.command, "team-grant")
        XCTAssertEqual(request?.args, ["leaders"])
        XCTAssertEqual(request?.options, ["cap": "send,stop", "sessions": "a,b", "pre": "stop", "expires": "600"])
    }

    func testGrantsAndRevokeRoute() {
        let grants = TeamGrantsRouting.request(sub: "grants", positional: [], options: [:], flags: [])
        XCTAssertEqual(grants, ControlRequest(command: "team-grants"))

        let revoke = TeamGrantsRouting.request(sub: "revoke", positional: ["g1"], options: [:], flags: [])
        XCTAssertEqual(revoke, ControlRequest(command: "team-revoke", args: ["g1"]))
    }

    func testNothingRoutesWithTeamOrWithoutACapability() {
        XCTAssertNil(TeamGrantsRouting.request(sub: "grants", positional: [], options: ["team": "x"], flags: []))
        XCTAssertNil(TeamGrantsRouting.request(sub: "grant", positional: ["leaders"], options: [:], flags: ["json"]))
        XCTAssertNil(TeamGrantsRouting.request(sub: "revoke", positional: [], options: [:], flags: []))
        XCTAssertNil(TeamGrantsRouting.request(sub: "send", positional: ["k", "s"], options: [:], flags: []))
    }

    func testAppAnswersOnlyWithAllThreeVerbs() {
        func manifest(_ names: [String]) -> JSONValue {
            .object(["commands": .array(names.map { .object(["name": .string($0)]) })])
        }
        XCTAssertTrue(TeamGrantsRouting.appAnswers(manifest: manifest(["team-grants", "team-grant", "team-revoke", "status"])))
        XCTAssertFalse(TeamGrantsRouting.appAnswers(manifest: manifest(["team-grants", "team-grant"])))
        XCTAssertFalse(TeamGrantsRouting.appAnswers(manifest: nil))
    }
}
