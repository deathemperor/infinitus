import XCTest
@testable import InfinitusCore

final class TeamControlRouteTests: XCTestCase {
    let grantor = TeamIdentity.random()
    let driver = TeamIdentity.random()
    let eve = TeamIdentity.random()

    var roster: TeamRoster {
        TeamRoster(id: "team-1", name: "P", createdAt: 1,
                   leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                   members: [TeamRoster.Member(keys: driver.keys, name: "D", since: 2)], rev: 1)
    }

    func endpoint(_ capabilities: Set<String>) -> TeamControl.Endpoint {
        var grants = TeamGrants()
        if !capabilities.isEmpty { grants.add(audience: .members([driver.kid]), sessions: .some(["s1"]), capabilities: capabilities, now: 1) }
        let r = roster
        return TeamControl.Endpoint(identity: grantor, roster: { r }, grants: { grants }, liveSessions: { ["s1": 7] },
                                    execute: { _, _, _, _ in .init(outcome: "delivered", channel: "pty") },
                                    seen: .init(), limit: .init(), now: { Date(timeIntervalSince1970: 1_000) })
    }

    func request(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data()) -> MirrorTransport.Request {
        MirrorTransport.Request(method: method, target: path, headers: headers, body: body)
    }

    let tail = TeamControlRoute.Tail { id, since in id == "s1" ? Data("{\"line\":1,\"since\":\"\(since ?? "")\"}\n".utf8) : nil }

    func status(_ response: Data?) -> Int? {
        response.flatMap { String(decoding: $0.prefix(12), as: UTF8.self).split(separator: " ").dropFirst().first }.flatMap { Int($0) }
    }
    func body(_ response: Data) -> Data {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: marker) else { return Data() }
        return response[range.upperBound...]
    }

    func testNonControlRoutesKeepRoutingAndNoGrantsMeans404() throws {
        var ep: TeamControl.Endpoint? = endpoint([TeamGrants.send])
        XCTAssertNil(TeamControlRoute.respond(request("GET", "/snapshot"), endpoint: &ep, tail: tail))
        XCTAssertNil(TeamControlRoute.respond(request("GET", "/team/key"), endpoint: &ep, tail: tail), "Nearby's route, not ours")
        var none: TeamControl.Endpoint? = endpoint([])
        XCTAssertEqual(status(TeamControlRoute.respond(request("POST", "/team/command", body: Data("x".utf8)), endpoint: &none, tail: tail)), 404)
        var absent: TeamControl.Endpoint? = nil
        XCTAssertEqual(status(TeamControlRoute.respond(request("POST", "/team/command", body: Data("x".utf8)), endpoint: &absent, tail: tail)), 404)
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", "/team/command"), endpoint: &ep, tail: tail)), 404, "wrong method")
    }

    func testACommandComesBackAsASealedAck() throws {
        var ep: TeamControl.Endpoint? = endpoint([TeamGrants.send])
        let cmd = TeamControl.Command(id: "c-0123456789", to: grantor.kid, session: "s1", action: "send", text: "hi", at: 1_000)
        let file = try TeamControl.sealCommand(cmd, from: driver, to: grantor.keys, at: 1_000)
        let response = TeamControlRoute.respond(request("POST", "/team/command", body: file), endpoint: &ep, tail: tail)
        XCTAssertEqual(status(response), 200)
        let (_, ack) = try TeamControl.openAck(body(response!), as: driver, senderKey: { kid in [self.grantor, self.driver].first { $0.kid == kid }?.keys })
        XCTAssertEqual(ack.outcome, "delivered")
        XCTAssertEqual(ep?.lastAudit, TeamControl.Audit(driver: driver.kid, session: "s1", action: "send", outcome: "delivered", detail: nil))
        // Empty body: 400. A stranger's command: 200 with nothing to read (no ack can be sealed), audit says unknownSender.
        XCTAssertEqual(status(TeamControlRoute.respond(request("POST", "/team/command"), endpoint: &ep, tail: tail)), 400)
        let strangers = try TeamControl.sealCommand(cmd, from: eve, to: grantor.keys, at: 1_000)
        let dropped = TeamControlRoute.respond(request("POST", "/team/command", body: strangers), endpoint: &ep, tail: tail)
        XCTAssertEqual(status(dropped), 200)
        XCTAssertTrue(body(dropped!).isEmpty)
        XCTAssertEqual(ep?.lastAudit?.outcome, "unknownSender")
    }

    func testTailNeedsASignedHeaderAndAViewGrant() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var ep: TeamControl.Endpoint? = endpoint([TeamGrants.view])
        let path = TeamControlRoute.tailPath(sessionId: "s1")
        XCTAssertEqual(path, "/team/sessions/s1/tail")
        XCTAssertEqual(TeamControlRoute.tailSessionId(path), "s1")
        XCTAssertNil(TeamControlRoute.tailSessionId("/team/sessions/s1/images"))
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", path), endpoint: &ep, tail: tail)), 403, "no header")
        let header = try TeamControlRoute.signTail(sessionId: "s1", by: driver, now: now)
        XCTAssertEqual(TeamControlRoute.checkTail(header, sessionId: "s1", roster: roster, now: now), driver.kid)
        XCTAssertEqual(TeamControlRoute.checkTail(header, sessionId: "s1", roster: roster, now: now.addingTimeInterval(59)), driver.kid, "the previous minute still counts")
        XCTAssertNil(TeamControlRoute.checkTail(header, sessionId: "s1", roster: roster, now: now.addingTimeInterval(121)), "two minutes on it is stale")
        XCTAssertNil(TeamControlRoute.checkTail(header, sessionId: "s2", roster: roster, now: now), "bound to the session")
        XCTAssertNil(TeamControlRoute.checkTail(try TeamControlRoute.signTail(sessionId: "s1", by: eve, now: now), sessionId: "s1", roster: roster, now: now), "not a member")
        let ok = TeamControlRoute.respond(request("GET", path + "?since=12", headers: [TeamControlRoute.tailHeader: header]), endpoint: &ep, tail: tail)
        XCTAssertEqual(status(ok), 200)
        XCTAssertEqual(String(decoding: body(ok!), as: UTF8.self), "{\"line\":1,\"since\":\"12\"}\n")
        // view on s1 only: s2 is 403 even though the header verifies.
        var all: TeamControl.Endpoint? = endpoint([TeamGrants.view])
        let h2 = try TeamControlRoute.signTail(sessionId: "s2", by: driver, now: now)
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", TeamControlRoute.tailPath(sessionId: "s2"), headers: [TeamControlRoute.tailHeader: h2]), endpoint: &all, tail: tail)), 403)
        var sendOnly: TeamControl.Endpoint? = endpoint([TeamGrants.send])
        XCTAssertEqual(status(TeamControlRoute.respond(request("GET", path, headers: [TeamControlRoute.tailHeader: header]), endpoint: &sendOnly, tail: tail)), 403, "send does not include view")
    }
}
