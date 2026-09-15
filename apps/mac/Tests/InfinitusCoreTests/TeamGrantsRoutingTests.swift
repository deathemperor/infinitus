import XCTest
@testable import InfinitusCore

final class TeamGrantsRoutingTests: XCTestCase {
    func testGrantRoutesItsFlagsAndOptions() {
        let request = TeamGrantsRouting.request(
            sub: "grant", positional: ["leaders"],
            options: ["threads": "a,b", "pre": "interrupt", "expires": "600"],
            flags: ["send", "interrupt", "json"])
        XCTAssertEqual(request?.command, "team-grant")
        XCTAssertEqual(request?.args, ["leaders"])
        XCTAssertEqual(request?.options, ["cap": "interrupt,send", "threads": "a,b", "pre": "interrupt", "expires": "600"])
    }

    func testTheOthersRoute() {
        XCTAssertEqual(TeamGrantsRouting.request(sub: "grants", positional: [], options: [:], flags: []),
                       ControlRequest(command: "team-grants"))
        XCTAssertEqual(TeamGrantsRouting.request(sub: "revoke", positional: ["g1"], options: [:], flags: []),
                       ControlRequest(command: "team-revoke", args: ["g1"]))
        XCTAssertEqual(TeamGrantsRouting.request(sub: "acks", positional: [], options: [:], flags: []),
                       ControlRequest(command: "team-acks"))
        XCTAssertEqual(TeamGrantsRouting.request(sub: "pending", positional: [], options: [:], flags: []),
                       ControlRequest(command: "team-pending"))
        XCTAssertEqual(TeamGrantsRouting.request(sub: "allow", positional: ["c-1"], options: [:], flags: []),
                       ControlRequest(command: "team-allow", args: ["c-1"]))
        XCTAssertEqual(TeamGrantsRouting.request(sub: "drive", positional: ["k", "-", "new", "Fix", "it"], options: ["project": "p", "x": "y"], flags: []),
                       ControlRequest(command: "team-drive", args: ["k", "-", "new", "Fix", "it"], options: ["project": "p"]))
    }

    func testNothingRoutesWithTeamOrWithoutACapability() {
        XCTAssertNil(TeamGrantsRouting.request(sub: "grants", positional: [], options: ["team": "x"], flags: []))
        XCTAssertNil(TeamGrantsRouting.request(sub: "grant", positional: ["leaders"], options: [:], flags: ["json"]))
        XCTAssertNil(TeamGrantsRouting.request(sub: "revoke", positional: [], options: [:], flags: []))
        XCTAssertNil(TeamGrantsRouting.request(sub: "drive", positional: ["k", "t"], options: [:], flags: []))
        XCTAssertNil(TeamGrantsRouting.request(sub: "status", positional: [], options: [:], flags: []))
    }

    func testAppAnswersOnlyWithEveryVerb() {
        func manifest(_ names: [String]) -> JSONValue {
            .object(["commands": .array(names.map { .object(["name": .string($0)]) })])
        }
        XCTAssertTrue(TeamGrantsRouting.appAnswers(manifest: manifest(TeamGrantsRouting.verbs + ["status"])))
        XCTAssertFalse(TeamGrantsRouting.appAnswers(manifest: manifest(["team-grants", "team-grant"])))
        XCTAssertFalse(TeamGrantsRouting.appAnswers(manifest: nil))
    }
}
