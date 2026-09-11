import XCTest
@testable import InfinitusCore

final class TeamMirrorTests: XCTestCase {
    func testPathsSitOutsideTheNearbyPrefixAndUnderTheirOwn() {
        for p in [TeamMirror.aggregatesPath, TeamMirror.memberPath, TeamMirror.transcriptPath,
                  TeamMirror.approvePath, TeamMirror.declinePath, TeamMirror.joinPath, TeamMirror.codePath] {
            XCTAssertTrue(p.hasPrefix(TeamMirror.prefix + "/"), p)
            XCTAssertFalse(p.hasPrefix(TeamNearby.routePrefix), "\(p) would be token-exempt from the LAN")
        }
    }

    func testQueriesRoundTripThroughTheRequestParser() {
        let q = TeamMirror.memberQuery(kid: "abc", period: .month)
        let r = MirrorTransport.Request(method: "GET", target: TeamMirror.memberPath + "?" + q, headers: [:], body: Data())
        XCTAssertEqual(r.path, TeamMirror.memberPath)
        XCTAssertEqual(r.query("kid"), "abc")
        XCTAssertEqual(r.query("period"), "month")
        let t = MirrorTransport.Request(method: "GET", target: TeamMirror.transcriptPath + "?" + TeamMirror.transcriptQuery(kid: "k", session: "s 1"), headers: [:], body: Data())
        XCTAssertEqual(t.query("session"), "s 1", "percent-encoded on the way out, decoded on the way in")
    }

    func testRepliesAreCodable() throws {
        let reply = TeamMirror.ActionReply(ok: false, error: "Turn on biometric unlock first", code: nil)
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.ActionReply.self, from: try JSONEncoder().encode(reply)), reply)
        let m = TeamMirror.MemberReply(kid: "k", name: "Ann", summary: nil, sessions: [], transcripts: ["s1"])
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.MemberReply.self, from: try JSONEncoder().encode(m)), m)
    }

    func testNearbyPathsSitUnderTheTokenGatedPrefix() {
        for p in [TeamMirror.nearbyPath, TeamMirror.nearbyScanPath, TeamMirror.nearbyRequestPath,
                  TeamMirror.nearbyInvitePath, TeamMirror.nearbyPullPath, TeamMirror.nearbyAcceptPath,
                  TeamMirror.nearbyIgnorePath] {
            XCTAssertTrue(p.hasPrefix(TeamMirror.prefix + "/"), p)
            XCTAssertFalse(p.hasPrefix(TeamNearby.routePrefix), "\(p) would be token-exempt from the LAN")
        }
        // The scan path is a sibling of the list path, not a shadow of it.
        XCTAssertNotEqual(TeamMirror.nearbyPath, TeamMirror.nearbyScanPath)
    }

    func testNearbyRepliesTravelAndCarryNothingSecret() throws {
        let reply = TeamMirror.NearbyReply(
            peers: [TeamNearby.Peer(name: "Bo", host: "bo.local", port: 1, kid: "k1",
                                    team: nil, role: "none", discoverable: true)],
            pending: [TeamMirror.PendingRequest(kid: "k2", name: "Ann", platform: "macos", at: 3)],
            invites: [TeamMirror.InviteSummary(fromKid: "k3", fromName: "Loc", teamName: "Papaya")],
            team: "t1")
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.NearbyReply.self, from: try JSONEncoder().encode(reply)), reply)
        let empty = TeamMirror.NearbyReply(peers: [], pending: [], invites: [], team: nil)
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.NearbyReply.self, from: try JSONEncoder().encode(empty)), empty)
        // Spec §10: the phone's Nearby view is names and kids, never a
        // code, a token or a sealed invitation.
        let json = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        for secret in ["envelope", "token", "code", "nonce"] {
            XCTAssertFalse(json.contains(secret), "\(secret) must not travel in NearbyReply")
        }
        let accept = TeamMirror.InviteAccept(fromKid: "k3", name: "Bo")
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.InviteAccept.self, from: try JSONEncoder().encode(accept)), accept)
        let join = TeamMirror.NearbyJoinRequest(kid: "k1", name: "Bo")
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.NearbyJoinRequest.self, from: try JSONEncoder().encode(join)), join)
        XCTAssertEqual(try JSONDecoder().decode(TeamMirror.Empty.self, from: try JSONEncoder().encode(TeamMirror.Empty())),
                       TeamMirror.Empty())
    }
}
