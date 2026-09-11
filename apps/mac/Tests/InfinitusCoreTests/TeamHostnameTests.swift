import XCTest
@testable import InfinitusCore

final class TeamHostnameTests: XCTestCase {
    var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamhostnames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// A recording Cloudflare: every call appended, canned answers by (method, path).
    final class Fake: @unchecked Sendable {
        var calls: [(method: String, path: String, body: [String: Any]?)] = []
        var http: TeamControl.Deliver.HTTP {
            { [self] method, url, headers, body, _ in
                XCTAssertEqual(headers["Authorization"], "Bearer cf-token")
                let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                calls.append((method, url.path + (url.query.map { "?" + $0 } ?? ""), json))
                func ok(_ result: Any) -> (Int, Data) {
                    (200, try! JSONSerialization.data(withJSONObject: ["success": true, "errors": [], "result": result]))
                }
                switch (method, url.path) {
                case ("GET", "/client/v4/zones"): return ok([["id": "zone1", "account": ["id": "acct1"]]])
                case ("POST", "/client/v4/accounts/acct1/cfd_tunnel"): return ok(["id": "tun-\(calls.count)"])
                case ("PUT", _) where url.path.hasSuffix("/configurations"): return ok([String: Any]())
                case ("POST", "/client/v4/zones/zone1/dns_records"): return ok(["id": "dns-\(calls.count)"])
                case ("GET", _) where url.path.hasSuffix("/token"): return ok("tunnel-token-\(calls.count)")
                case ("DELETE", _): return ok([String: Any]())
                default: return (404, Data("{\"success\":false,\"errors\":[{\"code\":1,\"message\":\"no route\"}]}".utf8))
                }
            }
        }
    }

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
    func team() throws -> (leader: TeamClient, bob: TeamClient, dir: URL) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (bp, bs) = machine("bob")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let bob = try TeamClient.request(code: code, name: "Bob Ó", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_010)
        _ = try leader.fetch()
        try leader.approve(kid: bob.identity.kid, now: 1_020)
        _ = try bob.fetch()
        return (leader, bob, lp.teamDir(leader.config.id))
    }

    func testSlugAndHostname() {
        XCTAssertEqual(TeamHostnames.slug("Bob Ó'Neil"), "bob-neil")
        XCTAssertEqual(TeamHostnames.slug("  --  "), "")
        XCTAssertEqual(TeamHostnames.hostname(name: "Ann", kid: "abcdef0123456789", label: "team", zone: "example.com", taken: []), "ann.team.example.com")
        XCTAssertEqual(TeamHostnames.hostname(name: "", kid: "abcdef0123456789", label: "team", zone: "example.com", taken: []), "abcdef01.team.example.com")
        XCTAssertEqual(TeamHostnames.hostname(name: "Ann", kid: "abcdef0123456789", label: "team", zone: "example.com", taken: ["ann.team.example.com"]), "ann-abcd.team.example.com")
        XCTAssertTrue(TeamHostnames.validName("team"))
        XCTAssertFalse(TeamHostnames.validName("te am"))
        XCTAssertFalse(TeamHostnames.validName(""))
    }

    func testGiveMintsInOrderCachesIdsAndSealsToTheMember() throws {
        let (leader, bob, dir) = try team()
        let fake = Fake()
        var ledger = TeamHostnames.Ledger(zone: "example.com", label: "team")
        let cf = TeamHostnames.Cloudflare(token: "cf-token", http: fake.http)
        let record = try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_000)
        XCTAssertEqual(record.hostname, "bob.team.example.com")
        XCTAssertEqual(fake.calls.map(\.method), ["GET", "POST", "PUT", "POST", "GET"])
        XCTAssertEqual(fake.calls[0].path, "/client/v4/zones?name=example.com")
        XCTAssertEqual(fake.calls[1].body?["name"] as? String, "infinitus-\(leader.config.id)-\(bob.identity.kid.prefix(8))")
        XCTAssertEqual(fake.calls[1].body?["config_src"] as? String, "cloudflare")
        let ingress = (fake.calls[2].body?["config"] as? [String: Any])?["ingress"] as? [[String: Any]]
        XCTAssertEqual(ingress?.first?["hostname"] as? String, "bob.team.example.com")
        XCTAssertEqual(ingress?.first?["service"] as? String, "http://localhost:47824")
        XCTAssertEqual(ingress?.last?["service"] as? String, "http_status:404")
        XCTAssertEqual(fake.calls[3].body?["content"] as? String, "\(record.tunnelID).cfargotunnel.com")
        XCTAssertEqual(fake.calls[3].body?["proxied"] as? Bool, true)
        XCTAssertEqual(ledger.zoneID, "zone1"); XCTAssertEqual(ledger.accountID, "acct1")
        XCTAssertEqual(ledger.records[bob.identity.kid]?.dnsID, record.dnsID)
        XCTAssertEqual(TeamHostnames.Ledger.load(teamDir: dir)?.records.count, 1, "saved after every step")

        // The member reads it once; a second pass is silent.
        _ = try bob.fetch()
        var handled = TeamControl.Handled()
        let got = try XCTUnwrap(TeamHostnames.inbox(client: bob, handled: &handled))
        XCTAssertEqual(got.hostname.hostname, "bob.team.example.com")
        XCTAssertTrue(got.hostname.token.hasPrefix("tunnel-token-"))
        XCTAssertEqual(got.from, leader.identity.kid)
        XCTAssertNil(try TeamHostnames.inbox(client: bob, handled: &handled))
        // A scan the caller already ran serves the inbox, the reader and the reap alike (one per load tick).
        let headers = try bob.readableHeaders()
        var again = TeamControl.Handled()
        XCTAssertEqual(try TeamHostnames.inbox(client: bob, handled: &again, headers: headers)?.hostname.hostname, "bob.team.example.com")
        XCTAssertEqual(try TeamReader.load(client: bob, headers: headers).members.count, try TeamReader.load(client: bob).members.count)
        XCTAssertEqual(try TeamControl.Store.driverReap(client: bob, acks: [], headers: headers), 0)

        // A second give (to self) skips the zones lookup and is read back by the giver.
        fake.calls.removeAll()
        let mine = try TeamHostnames.give(client: leader, kid: leader.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_100)
        XCTAssertEqual(mine.hostname, "leader.team.example.com")
        XCTAssertEqual(fake.calls.map(\.method), ["POST", "PUT", "POST", "GET"])
        var mineHandled = TeamControl.Handled()
        _ = try leader.fetch()
        XCTAssertEqual(try TeamHostnames.inbox(client: leader, handled: &mineHandled)?.hostname.hostname, "leader.team.example.com")
    }

    func testForgetDeletesBothRecordsAndUnpublishes() throws {
        let (leader, bob, _) = try team()
        let fake = Fake()
        var ledger = TeamHostnames.Ledger(zone: "example.com", label: "team")
        let cf = TeamHostnames.Cloudflare(token: "cf-token", http: fake.http)
        let record = try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_000)
        fake.calls.removeAll()
        XCTAssertTrue(try TeamHostnames.forget(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger))
        XCTAssertEqual(fake.calls.map(\.path), ["/client/v4/zones/zone1/dns_records/\(record.dnsID!)",
                                                 "/client/v4/accounts/acct1/cfd_tunnel/\(record.tunnelID)?cascade=true"])
        XCTAssertNil(ledger.records[bob.identity.kid])
        _ = try bob.fetch()
        var handled = TeamControl.Handled()
        XCTAssertNil(try TeamHostnames.inbox(client: bob, handled: &handled), "envelope gone from the store")

        // Without a token the record stays and reads as orphaned once Bob is removed.
        _ = try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: cf, ledger: &ledger, now: 2_200)
        XCTAssertFalse(try TeamHostnames.forget(client: leader, kid: bob.identity.kid, cloudflare: nil, ledger: &ledger))
        XCTAssertNotNil(ledger.records[bob.identity.kid])
        try leader.remove(kid: bob.identity.kid, now: 2_300)
        XCTAssertEqual(ledger.orphans(roster: leader.roster!.doc).map(\.kid), [bob.identity.kid])
    }

    func testNewTokenKeepsRecordsUnderTheSameZoneAndRefusesAnother() throws {
        let dir = scratch.appendingPathComponent("team")
        var old = TeamHostnames.Ledger(zone: "example.com", label: "team")
        old.zoneID = "zone1"; old.accountID = "acct1"
        old.records["k1"] = .init(hostname: "ann.team.example.com", tunnelID: "t", dnsID: "d", at: 1)
        try old.save(teamDir: dir)
        let same = try TeamHostnames.ledger(zone: " Example.COM ", label: "Lab", teamDir: dir)
        XCTAssertEqual(same.zone, "example.com"); XCTAssertEqual(same.label, "lab")
        XCTAssertEqual(same.records.count, 1)
        XCTAssertNil(same.zoneID, "ids are re-fetched so the new token gets checked")
        XCTAssertThrowsError(try TeamHostnames.ledger(zone: "other.org", label: "team", teamDir: dir)) { error in
            XCTAssertEqual(error as? TeamHostnames.HostnameError, .zoneInUse("example.com", 1))
        }
        XCTAssertThrowsError(try TeamHostnames.ledger(zone: "bad zone", label: "team", teamDir: dir))
    }

    func testApiErrorsCarryOnlyTheMessage() throws {
        let (leader, bob, _) = try team()
        let http: TeamControl.Deliver.HTTP = { _, _, _, _, _ in
            (403, Data("{\"success\":false,\"errors\":[{\"code\":9109,\"message\":\"Unauthorized to access requested resource\"}],\"result\":null}".utf8))
        }
        var ledger = TeamHostnames.Ledger(zone: "example.com", label: "team")
        XCTAssertThrowsError(try TeamHostnames.give(client: leader, kid: bob.identity.kid, cloudflare: .init(token: "cf-token", http: http),
                                                    ledger: &ledger, now: 1)) { error in
            guard case TeamHostnames.HostnameError.api(let status, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 403); XCTAssertEqual(message, "Unauthorized to access requested resource")
        }
        XCTAssertTrue(ledger.records.isEmpty, "nothing minted, nothing recorded")
    }
}
