import XCTest
@testable import InfinitusCore

final class TeamSnapshotTests: XCTestCase {
    func testMaskRemoteStripsCredentialsOnly() {
        XCTAssertEqual(TeamSnapshot.maskRemote("https://bob:ghp_secret@github.com/acme/team.git"), "https://github.com/acme/team.git")
        XCTAssertEqual(TeamSnapshot.maskRemote("https://x-access-token:tok@gitlab.com/a/b"), "https://gitlab.com/a/b")
        XCTAssertEqual(TeamSnapshot.maskRemote("https://github.com/acme/team.git"), "https://github.com/acme/team.git")
        XCTAssertEqual(TeamSnapshot.maskRemote("git@github.com:acme/team.git"), "git@github.com:acme/team.git")
        XCTAssertEqual(TeamSnapshot.maskRemote("file:///tmp/x/team.git"), "file:///tmp/x/team.git")
    }

    func testMakeOrdersLeadersFirstAndFoldsReaderRows() throws {
        let l = TeamIdentity.random(), a = TeamIdentity.random(), b = TeamIdentity.random(), p = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "Papaya", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: l.keys, name: "Ann", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: b.keys, name: "Zed", since: 3),
                                          TeamRoster.Member(keys: a.keys, name: "Bo", since: 2)], rev: 3)
        var day = Stats.Day(); day.usd = 1.5; day.humanMessages = 4; day.commits = 2
        var reader = TeamReader()
        reader = TeamReader.fold(headers: [], roster: roster) { _ in Data() }   // members seeded from the roster
        // Enrich Bo through fold's public surface: a stats day + now.json.
        let docs: [String: Data] = [
            "m/\(a.kid)/days/2026-09-05.json": try CanonicalJSON.encode(TeamDocs.DayDoc(day: "2026-09-05", stats: day)),
            "m/\(a.kid)/now.json": try CanonicalJSON.encode(TeamDocs.Now(at: 100, sessions: [TeamDocs.LiveSession(id: "s", project: "app", status: "busy")],
                                                                        fleets: [], blockers: ["AWS login: prod"], crashesToday: 1, sharesTo: [:])),
            "m/\(a.kid)/crashes.json": try CanonicalJSON.encode(TeamDocs.Crashes(crashes: ["Mac · crash · x"])),
        ]
        func entry(_ path: String, _ kind: String, _ from: String, _ at: Int) -> (entry: StoreEntry, header: Envelope.Header) {
            (StoreEntry(path: path, size: 1, version: "v"), Envelope.Header(v: 1, kind: kind, from: from, eph: "", to: [], at: at, nonce: "", sig: nil))
        }
        reader = TeamReader.fold(headers: [entry("m/\(a.kid)/days/2026-09-05.json", "stats", a.kid, 90),
                                           entry("m/\(a.kid)/now.json", "now", a.kid, 100),
                                           entry("m/\(a.kid)/crashes.json", "crashes", a.kid, 80)],
                                 roster: roster) { docs[$0]! }
        let status = TeamStatus(id: "t", name: "Papaya", remote: "https://u:t@h/x", kid: l.kid, role: "leader", rev: 3, leaders: 1, members: 2, requests: 1)
        let request = try Signed.make(TeamRequest(keys: p.keys, name: "Pat", devices: ["mbp"], platform: "macos", at: 50), by: p)
        let snap = TeamSnapshot.make(status: status, roster: roster, reader: reader, requests: [request],
                                     today: "2026-09-05", lastFetch: 200, lastPublish: nil, lastError: nil)
        XCTAssertEqual(snap.remote, "https://h/x")
        XCTAssertEqual(snap.members.map(\.name), ["Ann", "Bo", "Zed"])
        XCTAssertEqual(snap.members[0].role, "leader"); XCTAssertTrue(snap.members[0].founder); XCTAssertTrue(snap.members[0].isMe)
        let bo = snap.members[1]
        XCTAssertEqual(bo.role, "member"); XCTAssertFalse(bo.isMe)
        XCTAssertEqual(bo.since, 2); XCTAssertEqual(snap.members[0].since, 1)   // #219
        XCTAssertEqual(bo.lastPublished, 100)
        XCTAssertEqual(bo.kinds, ["crashes", "now", "stats"])
        XCTAssertEqual(bo.sessionsNow, 1)
        XCTAssertEqual(bo.blockers, ["AWS login: prod"])
        XCTAssertEqual(bo.crashes, 1)
        XCTAssertEqual(bo.todayUSD, 1.5, accuracy: 0.001)
        XCTAssertEqual(bo.todayMessages, 4); XCTAssertEqual(bo.todayCommits, 2)
        XCTAssertEqual(snap.members[2].todayUSD, 0)
        XCTAssertEqual(snap.requests.map(\.name), ["Pat"]); XCTAssertEqual(snap.requests[0].devices, ["mbp"])
        XCTAssertEqual(snap.lastFetch, 200); XCTAssertNil(snap.lastPublish)
        XCTAssertEqual(snap.role, "leader"); XCTAssertEqual(snap.rev, 3)
    }

    func testPendingHasNoRosterAndNoRows() {
        let status = TeamStatus(id: "t", name: "P", remote: "file:///r", kid: "me", role: "pending", rev: nil, leaders: 0, members: 0, requests: 0)
        let snap = TeamSnapshot.make(status: status, roster: nil, reader: nil, requests: [], today: "2026-09-05", lastFetch: nil, lastPublish: nil, lastError: "x")
        XCTAssertEqual(snap.members, []); XCTAssertEqual(snap.role, "pending"); XCTAssertEqual(snap.lastError, "x")
    }

    func testMirrorSnapshotCarriesTeamAsAdditiveOptional() throws {
        let old = MirrorSnapshot(capturedAt: Date(timeIntervalSince1970: 1), machineName: "m", listJSON: Data("{}".utf8), sessions: [])
        let data = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(MirrorSnapshot.self, from: data).team)
        let status = TeamStatus(id: "t", name: "P", remote: "file:///r", kid: "me", role: "leader", rev: 1, leaders: 1, members: 0, requests: 0)
        let team = TeamSnapshot.make(status: status, roster: nil, reader: nil, requests: [], today: "d", lastFetch: nil, lastPublish: nil, lastError: nil)
        let new = MirrorSnapshot(capturedAt: Date(timeIntervalSince1970: 1), machineName: "m", listJSON: Data("{}".utf8), sessions: [], team: team)
        XCTAssertEqual(try JSONDecoder().decode(MirrorSnapshot.self, from: try JSONEncoder().encode(new)).team, team)
    }
}
