import XCTest
@testable import InfinitusCore

final class TeamControlStoreTests: XCTestCase {
    var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamcontrolstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }
    func machine(_ name: String) -> (TeamPaths, TeamSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// Leader = grantor, Bob = driver; a grant to Bob on session s1 for send.
    func team() throws -> (grantor: TeamClient, driver: TeamClient, grantorDir: URL) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (bp, bs) = machine("bob")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let bob = try TeamClient.request(code: code, name: "Bob", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_010)
        _ = try leader.fetch()
        try leader.approve(kid: bob.identity.kid, now: 1_020)
        _ = try bob.fetch()
        let dir = lp.teamDir(leader.config.id)
        var grants = TeamGrants()
        _ = grants.add(audience: .members([bob.identity.kid]), sessions: .some(["s1"]), capabilities: [TeamGrants.send], now: 1_030)
        try grants.save(teamDir: dir)
        return (leader, bob, dir)
    }

    func endpoint(_ client: TeamClient, dir: URL, now: Int, executed: @escaping (String, String?) -> Void) -> TeamControl.Endpoint {
        TeamControl.Endpoint(identity: client.identity, roster: { client.roster?.doc }, grants: { TeamGrants.load(teamDir: dir) },
                             liveSessions: { ["s1": 4242] },
                             execute: { action, text, _ in executed(action, text); return SessionInput.Reply(outcome: "delivered", detail: nil) },
                             seen: TeamControl.SeenIDs(), limit: TeamControl.RateLimit(),
                             now: { Date(timeIntervalSince1970: TimeInterval(now)) })
    }

    func testStoreLaneRoundTripsAndAcksOnce() throws {
        let (grantor, driver, dir) = try team()
        let now = 2_000
        let cmd = TeamControl.Command(id: "c-0123456789", to: grantor.identity.kid, session: "s1", action: TeamGrants.send, text: "hello", at: now)
        var d = TeamControl.Deliver(http: { _, _, _, _, _ in XCTFail("no endpoints, no dial"); return (0, Data()) }, interfaces: [])
        let delivery = try TeamControl.Drive.send(cmd, client: driver, endpoints: nil, deliver: &d)
        XCTAssertEqual(delivery, TeamControl.Delivery(id: cmd.id, lane: .store, outcome: "queued", detail: "next fetch"))

        _ = try grantor.fetch()
        var executed: [(String, String?)] = []
        var ep = endpoint(grantor, dir: dir, now: now + 10) { executed.append(($0, $1)) }
        var handled = TeamControl.Handled.load(teamDir: dir)
        let audits = try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 10)
        XCTAssertEqual(audits.map(\.outcome), ["delivered"])
        XCTAssertEqual(audits.first?.driver, driver.identity.kid)
        XCTAssertEqual(executed.map(\.0), ["send"]); XCTAssertEqual(executed.first?.1, "hello")
        XCTAssertTrue(ep.seen.expiry.keys.contains(cmd.id), "an executed store command spends its id like an HTTP one")
        // A second pass over the same store is a no-op: handled remembers the blob.
        XCTAssertEqual(try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 20).count, 0)
        XCTAssertEqual(executed.count, 1)
        try handled.save(teamDir: dir)
        XCTAssertEqual(TeamControl.Handled.load(teamDir: dir), handled)

        // The driver's next fetch shows the ack, then reaps its command.
        _ = try driver.fetch()
        let reader = try TeamReader.load(client: driver)
        XCTAssertEqual(reader.members[grantor.identity.kid]?.acks[cmd.id]?.outcome, "delivered")
        XCTAssertEqual(try TeamControl.Store.driverReap(client: driver, acks: reader.ackIDs, now: now + 30), 1)
        XCTAssertEqual(try driver.readableHeaders().filter { $0.header.kind == TeamKinds.command }.count, 0)
        // ...and the grantor reaps its ack once it is old.
        _ = try grantor.fetch()
        XCTAssertEqual(try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 3 * TeamControl.storeTTL).count, 0)
        XCTAssertEqual(try grantor.readableHeaders().filter { $0.header.kind == TeamKinds.ack }.count, 0)
        XCTAssertTrue(handled.versions.isEmpty, "pruned with the file")
    }

    func testRefusedStoreCommandIsAckedWithTheRefusal() throws {
        let (grantor, driver, dir) = try team()
        let now = 2_000
        let cmd = TeamControl.Command(id: "c-0123456780", to: grantor.identity.kid, session: "s1", action: TeamGrants.mode, text: "acceptEdits", at: now)
        _ = try TeamControl.Drive.store(cmd, client: driver)
        _ = try grantor.fetch()
        var ep = endpoint(grantor, dir: dir, now: now + 10) { _, _ in XCTFail("not granted") }
        var handled = TeamControl.Handled()
        let audits = try TeamControl.Store.grantorPass(client: grantor, endpoint: &ep, handled: &handled, now: now + 10)
        XCTAssertEqual(audits.map(\.outcome), ["noGrant"])
        _ = try driver.fetch()
        XCTAssertEqual(try TeamReader.load(client: driver).members[grantor.identity.kid]?.acks[cmd.id]?.outcome, "noGrant")
    }
}
