import XCTest
@testable import InfinitusCore

final class TeamInvitesTests: XCTestCase {
    func testNonceIsRandomBase32() {
        let a = TeamInvites.newNonce(), b = TeamInvites.newNonce()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 26)
        XCTAssertTrue(a.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
    }

    func testMatchesOnlyUnexpiredIssuedNoncesBoundToTheRequester() {
        var book = TeamInvites()
        book.add(nonce: "n1", expires: 1_000)
        book.add(nonce: "n2", expires: 2_000)
        let ann = TeamIdentity.random().keys, eve = TeamIdentity.random().keys
        func req(_ keys: TeamKeys, _ nonce: String?) -> TeamRequest {
            TeamRequest(keys: keys, name: "x", devices: [], platform: "macos", at: 1,
                        proof: nonce.map { TeamRequest.proof(nonce: $0, kid: keys.kid) })
        }
        XCTAssertEqual(book.matches(req(ann, "n1"), now: 999), "n1")
        XCTAssertNil(book.matches(req(ann, "n1"), now: 1_001), "expired")
        XCTAssertNil(book.matches(req(ann, "n3"), now: 1), "never issued")
        XCTAssertNil(book.matches(req(ann, nil), now: 1), "a team code has no proof")
        // #161: Eve copies Ann's pending request's proof into her own request.
        var stolen = req(eve, nil); stolen.proof = req(ann, "n1").proof
        XCTAssertNil(book.matches(stolen, now: 1), "a proof is bound to the kid that made it")
        book.consume("n2")
        XCTAssertNil(book.matches(req(ann, "n2"), now: 1), "one-time")
        book.add(nonce: "n4", expires: 5)
        book.prune(now: 10)
        XCTAssertEqual(book.nonces, ["n1": 1_000])
    }

    func testProofIsDeterministicAndKidBound() {
        let a = TeamRequest.proof(nonce: "n", kid: "k1")
        XCTAssertEqual(a, TeamRequest.proof(nonce: "n", kid: "k1"))
        XCTAssertNotEqual(a, TeamRequest.proof(nonce: "n", kid: "k2"))
        XCTAssertNotEqual(a, TeamRequest.proof(nonce: "m", kid: "k1"))
        XCTAssertEqual(Data(base64Encoded: a)?.count, 32)
    }

    func testRoundTripsThroughTheTeamDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("invites-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = TeamInvites(); book.add(nonce: "n", expires: 9)
        try book.save(teamDir: dir)
        XCTAssertEqual(TeamInvites.load(teamDir: dir), book)
        XCTAssertEqual(TeamInvites.load(teamDir: dir.appendingPathComponent("missing")), TeamInvites())
    }

    func testCodeCarriesTheNonceAndAutoApprovalIsTheLeadersDecision() throws {
        let leader = TeamIdentity.random()
        let paths = TeamPaths(base: FileManager.default.temporaryDirectory.appendingPathComponent("inv-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let secrets = FileSecrets(dir: paths.secretsDir)
        try secrets.write(TeamClient.identitySecretName, leader.secret)
        // A bare remote is needed for create; reuse the membership tests' helper shape.
        let bare = paths.base.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        let client = try TeamClient.create(name: "T", remote: "file://" + bare.path, token: nil, paths: paths, secrets: secrets, now: 100)
        let nonce = TeamInvites.newNonce()
        let text = try client.code(expiresIn: 600, nonce: nonce, now: 100)
        XCTAssertEqual(try TeamCode.decode(text, now: 101).nonce, nonce)
        XCTAssertNil(try TeamCode.decode(try client.code(expiresIn: 600, now: 100), now: 101).nonce)
        // The joiner's request carries the proof, never the nonce (#161).
        let joinerPaths = TeamPaths(base: paths.base.appendingPathComponent("joiner"))
        let joinerSecrets = FileSecrets(dir: joinerPaths.secretsDir)
        let joiner = try TeamClient.request(code: text, name: "Bo", devices: [], platform: "linux", paths: joinerPaths, secrets: joinerSecrets, now: 102)
        _ = try client.fetch()
        let pending = try XCTUnwrap(try client.requests().first)
        XCTAssertEqual(pending.doc.proof, TeamRequest.proof(nonce: nonce, kid: joiner.identity.kid))
        var book = TeamInvites(); book.add(nonce: nonce, expires: 700)
        XCTAssertEqual(book.matches(pending.doc, now: 103), nonce)
        XCTAssertFalse(String(decoding: try CanonicalJSON.encode(pending.doc), as: UTF8.self).contains(nonce), "nonce not in the stored request")
    }

    func testMintAddsOneNonceToTheBookAndTheLinkCarriesIt() throws {
        let paths = TeamPaths(base: FileManager.default.temporaryDirectory.appendingPathComponent("mint-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let secrets = FileSecrets(dir: paths.secretsDir)
        let bare = paths.base.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        let client = try TeamClient.create(name: "T", remote: "file://" + bare.path, token: nil, paths: paths, secrets: secrets, now: 100)
        let dir = paths.teamDir(client.config.id)
        // A nonce that expired before this mint is pruned by the same call.
        var stale = TeamInvites(); stale.add(nonce: "old", expires: 50)
        try stale.save(teamDir: dir)

        let (link, nonce) = try TeamInvites.mint(client: client, teamDir: dir, days: 7, now: 100)
        let code = try TeamCode.decode(link, now: 101)
        XCTAssertEqual(code.nonce, nonce)
        XCTAssertEqual(code.team, client.config.id)
        XCTAssertEqual(code.expires, 100 + 7 * 86_400)
        XCTAssertEqual(TeamInvites.load(teamDir: dir).nonces, [nonce: 100 + 7 * 86_400])
        // A second mint keeps the first: two invites can be outstanding.
        let (second, secondNonce) = try TeamInvites.mint(client: client, teamDir: dir, days: 1, now: 200)
        XCTAssertEqual(try TeamCode.decode(second, now: 201).nonce, secondNonce)
        XCTAssertEqual(Set(TeamInvites.load(teamDir: dir).nonces.keys), [nonce, secondNonce])
    }

    /// Finding 5: `mint` asks `client.code` for the link BEFORE touching
    /// the book, so a leader who can't mint right now (closed requests)
    /// doesn't leave a dangling nonce nobody will ever redeem.
    func testMintLeavesTheBookUntouchedWhenTheClientRefuses() throws {
        let paths = TeamPaths(base: FileManager.default.temporaryDirectory.appendingPathComponent("mint-fail-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.base) }
        let secrets = FileSecrets(dir: paths.secretsDir)
        let bare = paths.base.appendingPathComponent("remote.git")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        let client = try TeamClient.create(name: "T", remote: "file://" + bare.path, token: nil, paths: paths, secrets: secrets, now: 100)
        var closed = try XCTUnwrap(client.roster).doc
        closed.policy.requests = "off"
        closed.rev += 1
        let signedRoster = try Signed.make(closed, by: client.identity)
        try CanonicalJSON.encode(signedRoster).write(to: paths.rosterFile(client.config.id))
        // Reopen so `roster` comes from the closed file on disk, the same
        // shape `TeamNearby.Local.load` uses — `fetch()` would instead
        // pull the still-open roster back from the git remote.
        let reopened = try TeamClient.open(id: client.config.id, paths: paths, secrets: secrets)

        let dir = paths.teamDir(reopened.config.id)
        XCTAssertThrowsError(try TeamInvites.mint(client: reopened, teamDir: dir, days: 7, now: 100) as (link: String, nonce: String)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .requestsOff)
        }
        XCTAssertEqual(TeamInvites.load(teamDir: dir), TeamInvites())
    }

    /// `drop` undoes a `mint` whose link never made it to the peer —
    /// the leader's own nonce book forgets it again.
    func testDropRemovesANonceTheBookAlreadyHas() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = TeamInvites(); book.add(nonce: "n1", expires: 1_000); book.add(nonce: "n2", expires: 1_000)
        try book.save(teamDir: dir)
        TeamInvites.drop(nonce: "n1", teamDir: dir)
        XCTAssertEqual(TeamInvites.load(teamDir: dir).nonces, ["n2": 1_000])
    }
}
