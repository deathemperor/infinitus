import XCTest
@testable import InfinitusCore

final class TeamControlDriveTests: XCTestCase {
    func testSameSubnetUsesTheMask() {
        let ifs = [TeamControl.Interface(address: "192.168.1.20", mask: "255.255.255.0"),
                   TeamControl.Interface(address: "10.0.5.7", mask: "255.255.0.0")]
        XCTAssertTrue(TeamControl.Deliver.sameSubnet("192.168.1.99", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("192.168.2.99", interfaces: ifs))
        XCTAssertTrue(TeamControl.Deliver.sameSubnet("10.0.200.1", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("10.1.0.1", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("not-an-ip", interfaces: ifs))
        XCTAssertFalse(TeamControl.Deliver.sameSubnet("192.168.1.99", interfaces: []))
    }

    func testLanIsSkippedOffSubnetAndLanesFallThroughInOrder() {
        let calls = Recorder()
        let http: TeamControl.Deliver.HTTP = { m, url, _, _, t in
            calls.add("\(m) \(url.absoluteString) \(Int(t))")
            if url.host == "grantor.example.net" { return (200, Data("ok".utf8)) }
            return (503, Data())
        }
        var d = TeamControl.Deliver(http: http, interfaces: [.init(address: "10.0.0.2", mask: "255.255.255.0")])
        let e = TeamControl.Endpoints(lan: "192.168.7.7:8912", hostname: "grantor.example.net", rendezvous: nil)
        let r = d.exchange(method: "POST", path: "/team/command", body: Data("x".utf8), endpoints: e, kid: "k")
        XCTAssertEqual(r?.lane, .hostname)
        XCTAssertEqual(r?.body, Data("ok".utf8))
        XCTAssertEqual(calls.lines, ["POST https://grantor.example.net/team/command 5"], "off-subnet LAN never dialed")
    }

    func testLanFirstOnSubnetThenHostnameThenRendezvousWithCacheRefresh() throws {
        let calls = Recorder()
        let http: TeamControl.Deliver.HTTP = { _, url, _, _, _ in
            let s = url.absoluteString
            calls.add(s)
            if s.hasPrefix("https://infinitus.run/rendezvous/") {
                return (200, MirrorRendezvous.publishBody(url: "https://new.trycloudflare.com"))
            }
            switch s {
            case "http://10.0.0.9:8912/team/command": return (500, Data())
            case "https://h.example.net/team/command": return (404, Data())
            case "https://old.trycloudflare.com/team/command": throw NSError(domain: "t", code: 1)
            case "https://new.trycloudflare.com/team/command": return (200, Data("ack".utf8))
            default: return (0, Data())
            }
        }
        var d = TeamControl.Deliver(http: http, interfaces: [.init(address: "10.0.0.2", mask: "255.255.255.0")])
        let key = TeamControl.rendezvousKey(team: "t", kid: "k")
        d.rendezvous["k"] = "https://old.trycloudflare.com"          // stale cache
        let e = TeamControl.Endpoints(lan: "10.0.0.9:8912", hostname: "h.example.net", rendezvous: key)
        let r = d.exchange(method: "POST", path: "/team/command", body: Data(), endpoints: e, kid: "k")
        XCTAssertEqual(r?.lane, .rendezvous)
        XCTAssertEqual(r?.body, Data("ack".utf8))
        XCTAssertEqual(Array(calls.lines.prefix(3)), ["http://10.0.0.9:8912/team/command", "https://h.example.net/team/command",
                                                      "https://old.trycloudflare.com/team/command"])
        XCTAssertEqual(calls.lines.filter { $0.hasPrefix("https://infinitus.run/rendezvous/") }.count, 1,
                       "the cached tunnel was tried first, the lookup only after it refused")
        XCTAssertEqual(d.rendezvous["k"], "https://new.trycloudflare.com")
    }

    func testNoEndpointMeansNoNetworkLane() {
        let calls = Recorder()
        var d = TeamControl.Deliver(http: { _, url, _, _, _ in calls.add(url.absoluteString); return (200, Data()) }, interfaces: [])
        XCTAssertNil(d.exchange(method: "POST", path: "/x", body: nil, endpoints: TeamControl.Endpoints(), kid: "k"))
        XCTAssertEqual(calls.lines, [])
    }

    func testCommandIDsFitTheStorePath() {
        let id = TeamControl.newCommandID()
        XCTAssertEqual(id.count, 18)
        XCTAssertTrue(id.hasPrefix("c-"))
        XCTAssertTrue(id.allSatisfy { "abcdef0123456789-".contains($0) })
        XCTAssertNotEqual(id, TeamControl.newCommandID())
        XCTAssertNoThrow(try TeamKinds.check(kind: TeamKinds.command, from: "d", at: TeamControl.commandPath(driver: "d", id: id)))
    }

    func testDriveNetworkOpensTheAckAndReportsTheLane() throws {
        let driver = TeamIdentity.random(), grantor = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: grantor.keys, name: "G", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: driver.keys, name: "D", since: 2)], removed: [], rev: 2)
        let cmd = TeamControl.Command(id: "c-0123456789", to: grantor.kid, session: "s1", action: TeamGrants.send, text: "hi", at: 1_000)
        let lan = [TeamControl.Interface(address: "10.0.0.2", mask: "255.255.255.0")]
        let http: TeamControl.Deliver.HTTP = { _, _, _, body, _ in
            // The grantor opens the command and acks it.
            let (h, c) = try TeamControl.openCommand(body!, as: grantor, senderKey: { $0 == driver.kid ? driver.keys : nil })
            XCTAssertEqual(h.from, driver.kid); XCTAssertEqual(c, cmd)
            let ack = TeamControl.Ack(id: c.id, outcome: TeamControl.Outcome.delivered, detail: nil, at: 1_001)
            return (200, try TeamControl.sealAck(ack, from: grantor, to: driver.keys, at: 1_001))
        }
        var d = TeamControl.Deliver(http: http, interfaces: lan)
        let out = try TeamControl.Drive.network(cmd, identity: driver, roster: roster,
                                                endpoints: TeamControl.Endpoints(lan: "10.0.0.9:8912"), deliver: &d)
        XCTAssertEqual(out, TeamControl.Delivery(id: cmd.id, lane: .lan, outcome: "delivered", detail: nil))
        // An empty 200: the grantor could not answer.
        var e = TeamControl.Deliver(http: { _, _, _, _, _ in (200, Data()) }, interfaces: lan)
        XCTAssertEqual(try TeamControl.Drive.network(cmd, identity: driver, roster: roster,
                                                     endpoints: TeamControl.Endpoints(lan: "10.0.0.9:8912"), deliver: &e)?.outcome, "badRequest")
        // No endpoints: nil, the caller goes to the store.
        XCTAssertNil(try TeamControl.Drive.network(cmd, identity: driver, roster: roster, endpoints: nil, deliver: &d))
        let stranger = TeamControl.Command(id: "c-0123456789", to: "nobody", session: "s", action: "send", text: "x", at: 1)
        XCTAssertThrowsError(try TeamControl.Drive.network(stranger, identity: driver, roster: roster, endpoints: nil, deliver: &d)) {
            XCTAssertEqual($0 as? TeamControl.DriveError, .unknownKid("nobody"))
        }
    }

    func testTailSignsTheHeaderAndUsesGet() throws {
        let driver = TeamIdentity.random()
        let seen = Recorder()
        let http: TeamControl.Deliver.HTTP = { m, url, headers, _, _ in
            seen.add("\(m) \(url.absoluteString)")
            seen.add(headers[TeamControlRoute.tailHeader] ?? "")
            return (200, Data("{}".utf8))
        }
        var d = TeamControl.Deliver(http: http, interfaces: [])
        let r = try TeamControl.Drive.tail(kid: "k", session: "s1", since: "42", identity: driver,
                                           endpoints: TeamControl.Endpoints(hostname: "h.example.net"), deliver: &d,
                                           now: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(r?.lane, .hostname)
        XCTAssertEqual(seen.lines.first, "GET https://h.example.net/team/sessions/s1/tail?since=42")
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: driver.keys, name: "D", since: 1, founder: true)], members: [], removed: [], rev: 1)
        XCTAssertEqual(TeamControlRoute.checkTail(seen.lines[1], sessionId: "s1", roster: roster, now: Date(timeIntervalSince1970: 130)), driver.kid)
        XCTAssertNil(try TeamControl.Drive.tail(kid: "k", session: "s1", since: nil, identity: driver, endpoints: nil, deliver: &d))
    }
}

/// A Sendable scratch list for the @Sendable HTTP fakes.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ s: String) { lock.lock(); stored.append(s); lock.unlock() }
}
