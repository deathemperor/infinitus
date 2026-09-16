import XCTest
@testable import InfinitusCore

final class TeamControlDriveTests: XCTestCase {
    func testLanesSkipLoopbackAndKeepOrder() {
        let e = TeamControl.Endpoints(httpBaseUrl: "http://127.0.0.1:3773",
                                      lanHttpBaseUrls: ["http://192.168.1.20:3773", "http://10.0.0.5:3773/"],
                                      tunnel: "https://mac.example.net")
        XCTAssertEqual(TeamControl.Deliver.lanes(e).map { "\($0.lane.rawValue) \($0.base)" },
                       ["lan http://192.168.1.20:3773", "lan http://10.0.0.5:3773/", "tunnel https://mac.example.net"])
        let bound = TeamControl.Endpoints(httpBaseUrl: "http://192.168.1.20:3773", lanHttpBaseUrls: ["http://192.168.1.20:3773"])
        XCTAssertEqual(TeamControl.Deliver.lanes(bound).count, 1, "the desktop's own URL is one of its LAN URLs")
        XCTAssertTrue(TeamControl.Deliver.lanes(TeamControl.Endpoints()).isEmpty)
        for loop in ["http://localhost:3773", "http://[::1]:3773", "http://127.0.0.1:3773", "nope"] {
            XCTAssertTrue(TeamControl.Deliver.isLoopback(loop), loop)
        }
        XCTAssertFalse(TeamControl.Deliver.isLoopback("http://192.168.1.20:3773"))
    }

    func testLanesFallThroughInOrderWithTheirTimeouts() {
        let calls = Recorder()
        let http: TeamControl.Deliver.HTTP = { m, url, headers, body, t in
            calls.add("\(m) \(url.absoluteString) \(Int(t)) \(headers["Content-Type"] ?? "")")
            XCTAssertTrue(String(decoding: body ?? Data(), as: UTF8.self).hasPrefix("{\"envelope\":\""))
            if url.host == "mac.example.net" { return (200, Data("{\"ack\":\"AQID\"}".utf8)) }
            if url.host == "10.0.0.9" { throw NSError(domain: "t", code: 1) }
            return (503, Data())
        }
        let d = TeamControl.Deliver(http: http)
        let e = TeamControl.Endpoints(lanHttpBaseUrls: ["http://10.0.0.9:3773", "http://10.0.0.10:3773/"], tunnel: "https://mac.example.net")
        let r = d.exchange(sealed: Data([9]), endpoints: e)
        XCTAssertEqual(r?.lane, .tunnel)
        XCTAssertEqual(r?.ack, Data([1, 2, 3]))
        XCTAssertEqual(calls.lines, ["POST http://10.0.0.9:3773/api/infinitus/team/command 2 application/json",
                                     "POST http://10.0.0.10:3773/api/infinitus/team/command 2 application/json",
                                     "POST https://mac.example.net/api/infinitus/team/command 5 application/json"])
        // `{ack: null}`: the lane answered, the grantor had nobody to answer to.
        let refused = TeamControl.Deliver(http: { _, _, _, _, _ in (200, Data("{\"ack\":null}".utf8)) })
        let none = refused.exchange(sealed: Data(), endpoints: e)
        XCTAssertEqual(none?.lane, .lan); XCTAssertNil(none?.ack)
    }

    func testNoEndpointMeansNoNetworkLane() {
        let calls = Recorder()
        let d = TeamControl.Deliver(http: { _, url, _, _, _ in calls.add(url.absoluteString); return (200, Data()) })
        XCTAssertNil(d.exchange(sealed: Data(), endpoints: TeamControl.Endpoints()))
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
        let cmd = TeamControl.Command(id: "c-0123456789", to: grantor.kid, thread: "t1", action: TeamGrants.send, text: "hi", at: 1_000)
        let http: TeamControl.Deliver.HTTP = { _, _, _, body, _ in
            // The grantor's desktop hands the envelope to the Mac, which opens the command and acks it.
            let envelope = try XCTUnwrap(try JSONDecoder().decode([String: String].self, from: body!)["envelope"].flatMap { Data(base64Encoded: $0) })
            let (h, c) = try TeamControl.openCommand(envelope, as: grantor, senderKey: { $0 == driver.kid ? driver.keys : nil })
            XCTAssertEqual(h.from, driver.kid); XCTAssertEqual(c, cmd)
            let ack = TeamControl.Ack(id: c.id, outcome: TeamControl.Outcome.delivered, detail: nil, at: 1_001)
            let sealed = try TeamControl.sealAck(ack, from: grantor, to: driver.keys, at: 1_001)
            return (200, try JSONEncoder().encode(["ack": sealed.base64EncodedString()]))
        }
        let d = TeamControl.Deliver(http: http)
        let lan = TeamControl.Endpoints(lanHttpBaseUrls: ["http://10.0.0.9:3773"])
        let out = try TeamControl.Drive.network(cmd, identity: driver, roster: roster, endpoints: lan, deliver: d)
        XCTAssertEqual(out, TeamControl.Delivery(id: cmd.id, lane: .lan, outcome: "delivered", detail: nil))
        // `{ack: null}`: the grantor could not answer.
        let e = TeamControl.Deliver(http: { _, _, _, _, _ in (200, Data("{\"ack\":null}".utf8)) })
        XCTAssertEqual(try TeamControl.Drive.network(cmd, identity: driver, roster: roster, endpoints: lan, deliver: e)?.outcome, "badRequest")
        // No endpoints: nil, the caller goes to the store.
        XCTAssertNil(try TeamControl.Drive.network(cmd, identity: driver, roster: roster, endpoints: nil, deliver: d))
        let stranger = TeamControl.Command(id: "c-0123456789", to: "nobody", thread: "s", action: "send", text: "x", at: 1)
        XCTAssertThrowsError(try TeamControl.Drive.network(stranger, identity: driver, roster: roster, endpoints: nil, deliver: d)) {
            XCTAssertEqual($0 as? TeamControl.DriveError, .unknownKid("nobody"))
        }
    }
}

/// A Sendable scratch list for the @Sendable HTTP fakes.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ s: String) { lock.lock(); stored.append(s); lock.unlock() }
}
