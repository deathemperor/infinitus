import XCTest
@testable import InfinitusCore

final class TeamNearbyTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamnearby-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote(_ name: String = "remote.git") throws -> String {
        let bare = scratch.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    /// One "machine": its own paths and secrets.
    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    func http(_ method: String, _ path: String, body: Data = Data()) -> MirrorTransport.Request {
        MirrorTransport.Request(method: method, target: path, headers: [:], body: body)
    }

    func status(_ data: Data?) -> Int? { data.flatMap(MirrorTransport.parseResponse)?.status }

    func body<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
        try CanonicalJSON.decode(type, from: try XCTUnwrap(data.flatMap(MirrorTransport.parseResponse)).body)
    }

    func testLocalStandingFollowsTheRosterAndTheSwitch() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let on = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        XCTAssertEqual(on.record, NearbyRecord(name: "Loc", kid: leader.identity.kid, team: leader.config.id,
                                               role: "leader", discoverable: true))
        XCTAssertEqual(on.keys, leader.identity.keys)
        XCTAssertEqual(TeamNearby.Local.load(name: "Loc", discoverable: false, paths: lp, secrets: ls), .hidden)
        // No team yet: role none, and an identity is minted so an invite has a kid to target.
        let (jp, js) = machine("joiner")
        let joiner = TeamNearby.Local.load(name: "Bo", discoverable: true, paths: jp, secrets: js)
        XCTAssertEqual(joiner.record.role, "none")
        XCTAssertNil(joiner.record.team)
        XCTAssertEqual(joiner.keys, try TeamClient.identity(paths: jp, secrets: js).keys)
        // Hidden never mints one.
        let (hp, hs) = machine("hidden")
        _ = TeamNearby.Local.load(name: "H", discoverable: false, paths: hp, secrets: hs)
        XCTAssertNil(hs.read(TeamClient.identitySecretName))
    }

    func testRoutesAnswerOnlyWhenDiscoverable() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let local = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        let endpoint = TeamNearby.Endpoint(local: local) { _ in "branch" }
        // Not ours: the caller keeps routing.
        XCTAssertNil(TeamNearby.respond(http("GET", "/snapshot"), endpoint: endpoint))
        let key = TeamNearby.respond(http("GET", TeamNearby.keyPath), endpoint: endpoint)
        XCTAssertEqual(status(key), 200)
        XCTAssertEqual(try body(TeamNearby.KeyReply.self, key),
                       TeamNearby.KeyReply(name: "Loc", keys: leader.identity.keys, team: leader.config.id, role: "leader"))
        // Hidden or absent: 404 on every team route, nothing about the team leaks.
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.keyPath), endpoint: nil)), 404)
        let hidden = TeamNearby.Endpoint(local: .hidden) { _ in "branch" }
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.keyPath), endpoint: hidden)), 404)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath), endpoint: hidden)), 404)
        // Wrong method on a real route.
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.requestPath), endpoint: endpoint)), 404)
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.invitePath), endpoint: endpoint)), 404)
        // The invite route exists now: a body that isn't one is a 400, not a 404.
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath), endpoint: endpoint)), 400)
    }

    func testRequestOverTheLanLandsInTheRequestsBranch() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let signed = try Signed.make(TeamRequest(keys: joiner.keys, name: "Bo", devices: ["Linux"], platform: "linux", at: 1_010),
                                     by: joiner)
        let request = try CanonicalJSON.encode(TeamNearby.Request(team: leader.config.id, request: signed))
        let local = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        let endpoint = TeamNearby.Endpoint(local: local) { try TeamNearby.Store.save($0, paths: lp, secrets: ls) }

        let response = TeamNearby.respond(http("POST", TeamNearby.requestPath, body: request), endpoint: endpoint)
        XCTAssertEqual(status(response), 200)
        XCTAssertEqual(try body(TeamNearby.RequestReply.self, response), TeamNearby.RequestReply(ok: true, stored: "branch"))
        XCTAssertEqual(TeamNearby.Store.pending(team: leader.config.id, paths: lp), [])
        // The leader's ordinary path sees it and approves it.
        _ = try leader.fetch()
        XCTAssertEqual(try leader.requests().map(\.doc.name), ["Bo"])
        try leader.approve(kid: joiner.kid, now: 1_020)
        XCTAssertEqual(leader.roster?.doc.members.map(\.name), ["Bo"])

        // Wrong team → 404; a tampered document → 400; not JSON → 400.
        let elsewhere = try CanonicalJSON.encode(TeamNearby.Request(team: "other", request: signed))
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: elsewhere), endpoint: endpoint)), 404)
        var forged = signed
        forged.doc.name = "Eve"
        let forgedBody = try CanonicalJSON.encode(TeamNearby.Request(team: leader.config.id, request: forged))
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: forgedBody), endpoint: endpoint)), 400)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: Data("nope".utf8)), endpoint: endpoint)), 400)
        // The store refusing is a 503, not a crash.
        let broken = TeamNearby.Endpoint(local: local) { _ in throw TeamNearby.StoreError.full }
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: request), endpoint: broken)), 503)
    }

    func testRequestStaysPendingWhenTheStoreIsUnreachable() throws {
        let (lp, ls) = machine("leader")
        // A team whose remote doesn't exist: config on disk, store never cloned.
        let me = try TeamClient.identity(paths: lp, secrets: ls)
        let config = TeamConfig(id: "t-offline", name: "Ghost", remote: "file:///nonexistent/ghost.git",
                                kid: me.kid, joinedAt: 1, leaderKid: me.kid)
        try FileManager.default.createDirectory(at: lp.teamDir("t-offline"), withIntermediateDirectories: true)
        try CanonicalJSON.encode(config).write(to: lp.configFile("t-offline"))
        let joiner = TeamIdentity.random()
        let signed = try Signed.make(TeamRequest(keys: joiner.keys, name: "Bo", devices: [], platform: "linux", at: 5), by: joiner)
        let incoming = TeamNearby.Request(team: "t-offline", request: signed)
        XCTAssertEqual(try TeamNearby.Store.save(incoming, paths: lp, secrets: ls), "pending")
        XCTAssertEqual(TeamNearby.Store.pending(team: "t-offline", paths: lp), [signed])
        // The same kid again replaces, never duplicates.
        XCTAssertEqual(try TeamNearby.Store.save(incoming, paths: lp, secrets: ls), "pending")
        XCTAssertEqual(TeamNearby.Store.pending(team: "t-offline", paths: lp).count, 1)
        // An unknown team is refused.
        XCTAssertThrowsError(try TeamNearby.Store.save(TeamNearby.Request(team: "nope", request: signed), paths: lp, secrets: ls)) {
            XCTAssertEqual($0 as? TeamNearby.StoreError, .unknownTeam)
        }
        // A garbled pending file is skipped, not fatal.
        try Data("junk".utf8).write(to: TeamNearby.Store.pendingDir(team: "t-offline", paths: lp).appendingPathComponent("zzz.json"))
        XCTAssertEqual(TeamNearby.Store.pending(team: "t-offline", paths: lp), [signed])
    }

    /// Stream ruling: a leader who has closed requests (`policy.requests
    /// == "off"`, spec §6.3/§6.4) refuses `POST /team/request` outright —
    /// 403, and the store is never touched (nothing pending, nothing on
    /// the branch).
    func testRequestRefusedWhenLeaderHasClosedRequests() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        var closed = try XCTUnwrap(leader.roster).doc
        closed.policy.requests = "off"
        closed.rev += 1
        let signedRoster = try Signed.make(closed, by: leader.identity)
        try CanonicalJSON.encode(signedRoster).write(to: lp.rosterFile(leader.config.id))

        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let signed = try Signed.make(TeamRequest(keys: joiner.keys, name: "Bo", devices: [], platform: "linux", at: 1_010),
                                     by: joiner)
        let request = try CanonicalJSON.encode(TeamNearby.Request(team: leader.config.id, request: signed))

        let local = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        XCTAssertFalse(local.requestsOpen)
        let endpoint = TeamNearby.Endpoint(local: local) { _ in
            XCTFail("closed requests must never reach storage")
            return "branch"
        }
        let response = TeamNearby.respond(http("POST", TeamNearby.requestPath, body: request), endpoint: endpoint)
        XCTAssertEqual(status(response), 403)
        XCTAssertEqual(TeamNearby.Store.pending(team: leader.config.id, paths: lp), [])
    }

    /// The same ruling, checked on a *member* machine: the local roster
    /// is the same signed document with the same closed policy, and a
    /// member's Mac holds the team's write credential too, so the check
    /// must not be leader-only.
    func testRequestRefusedWhenMemberHasClosedRequests() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (mp, ms) = machine("member")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 60, now: 1_000)
        let member = try TeamClient.request(code: code, name: "Han", devices: ["Mac"], platform: "macos",
                                            paths: mp, secrets: ms, now: 1_005)
        _ = try leader.fetch()
        try leader.approve(kid: member.identity.kid, now: 1_010)
        _ = try member.fetch()

        var closed = try XCTUnwrap(member.roster).doc
        closed.policy.requests = "off"
        closed.rev += 1
        let signedRoster = try Signed.make(closed, by: leader.identity)
        try CanonicalJSON.encode(signedRoster).write(to: mp.rosterFile(member.config.id))

        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let signed = try Signed.make(TeamRequest(keys: joiner.keys, name: "Bo", devices: [], platform: "linux", at: 1_020),
                                     by: joiner)
        let request = try CanonicalJSON.encode(TeamNearby.Request(team: member.config.id, request: signed))

        let local = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: mp, secrets: ms)
        XCTAssertEqual(local.record.role, "member")
        XCTAssertFalse(local.requestsOpen)
        let endpoint = TeamNearby.Endpoint(local: local) { _ in
            XCTFail("closed requests must never reach storage")
            return "branch"
        }
        let response = TeamNearby.respond(http("POST", TeamNearby.requestPath, body: request), endpoint: endpoint)
        XCTAssertEqual(status(response), 403)
        XCTAssertEqual(TeamNearby.Store.pending(team: member.config.id, paths: mp), [])
    }

    func testClientVerifiesTheLeaderKeyBeforeSendingAndWritesTheBranchWhenItHoldsTheCredential() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let local = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        let endpoint = TeamNearby.Endpoint(local: local) { try TeamNearby.Store.save($0, paths: lp, secrets: ls) }
        let peer = TeamNearby.Peer(name: "Loc", host: "leader.local", port: 1, kid: leader.identity.kid,
                                   team: leader.config.id, role: "leader", discoverable: true)
        // An HTTP function that routes into TeamNearby.respond — no sockets.
        var posted = 0
        let http: TeamNearby.Client.HTTP = { method, _, _, path, body in
            if method == "POST" { posted += 1 }
            let reply = TeamNearby.respond(MirrorTransport.Request(method: method, target: path, headers: [:], body: body ?? Data()), endpoint: endpoint)
            let parsed = try XCTUnwrap(reply.flatMap(MirrorTransport.parseResponse))
            return (parsed.status, parsed.body)
        }
        let out = try TeamNearby.Client.request(to: peer, name: "Bo", devices: ["Linux"], platform: "linux", paths: jp, secrets: js, http: http, now: 1_010)
        XCTAssertEqual(out.stored, "branch")
        XCTAssertEqual(posted, 1)
        _ = try leader.fetch()
        XCTAssertEqual(try leader.requests().map(\.doc.name), ["Bo"])

        // A peer whose TXT kid is not what /team/key answers: nothing is posted.
        var liar = peer; liar.kid = TeamIdentity.random().kid
        posted = 0
        XCTAssertThrowsError(try TeamNearby.Client.request(to: liar, name: "Bo", devices: [], platform: "linux", paths: jp, secrets: js, http: http)) {
            guard case TeamNearby.Client.ClientError.keyMismatch = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(posted, 0)
        // A member peer leads no team.
        var member = peer; member.role = "member"
        XCTAssertThrowsError(try TeamNearby.Client.request(to: member, name: "Bo", devices: [], platform: "linux", paths: jp, secrets: js, http: http))
    }

    func testInviteRouteKeepsASealedInviteAndRefusesAnythingItCannotOpen() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let local = TeamNearby.Local.load(name: "Bo", discoverable: true, paths: jp, secrets: js)
        let endpoint = TeamNearby.Endpoint(local: local, store: { _ in "branch" },
                                           storeInvite: { try TeamNearby.Store.saveInvite($0, paths: jp) })
        let link = try leader.code(expiresIn: 7 * 86_400, nonce: TeamInvites.newNonce(), now: 1_000)
        let sealed = try Envelope.seal(Data(link.utf8), kind: "invite", from: leader.identity, to: [joiner.keys], at: 1_001)
        let invite = TeamNearby.Invite(from: leader.identity.keys, fromName: "Loc", teamName: "Papaya", envelope: sealed)

        let ok = TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(invite)), endpoint: endpoint)
        XCTAssertEqual(status(ok), 200)
        XCTAssertEqual(try body(TeamNearby.InviteReply.self, ok), TeamNearby.InviteReply(ok: true))
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp, now: 1_002), [invite])
        XCTAssertEqual(invite.at, 1_001)

        // The envelope's sender must be the `from` the body claims.
        var lying = invite; lying.from = TeamIdentity.random().keys
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(lying)), endpoint: endpoint)), 400)
        // Sealed to someone else: this machine is not among the recipients.
        let elsewhere = try Envelope.seal(Data(link.utf8), kind: "invite", from: leader.identity,
                                          to: [TeamIdentity.random().keys], at: 1_001)
        let notMine = TeamNearby.Invite(from: leader.identity.keys, fromName: "Loc", teamName: "Papaya", envelope: elsewhere)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(notMine)), endpoint: endpoint)), 400)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: Data("nope".utf8)), endpoint: endpoint)), 400)
        // A hidden machine says nothing at all.
        let hidden = TeamNearby.Endpoint(local: .hidden, store: { _ in "branch" })
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(invite)), endpoint: hidden)), 404)
        // A store that refuses is a 503, not a crash — and an endpoint with
        // no invite store wired refuses the same way.
        let unwired = TeamNearby.Endpoint(local: local, store: { _ in "branch" })
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(invite)), endpoint: unwired)), 503)

        // A forged envelope — same `from`, same header shape, but a
        // signature nobody but the leader could have made — is refused
        // outright, never parked under the leader's kid where it would
        // silently replace the genuine invitation.
        var corruptHeader = try Envelope.header(of: sealed)
        var sigBytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(corruptHeader.sig)))
        sigBytes[0] ^= 0xFF
        corruptHeader.sig = sigBytes.base64EncodedString()
        let split = try XCTUnwrap(sealed.firstIndex(of: UInt8(ascii: "\n")))
        let corrupted = try CanonicalJSON.encode(corruptHeader) + Data([UInt8(ascii: "\n")]) + sealed[(split + 1)...]
        let forged = TeamNearby.Invite(from: leader.identity.keys, fromName: "Mallory", teamName: "Papaya", envelope: corrupted)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.invitePath, body: try CanonicalJSON.encode(forged)), endpoint: endpoint)), 400)
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp, now: 1_002), [invite])

        // Opening gives the link back verbatim and the code it decodes to.
        let opened = try TeamNearby.openInvite(invite, identity: joiner, now: 1_002)
        XCTAssertEqual(opened.text, link)
        XCTAssertEqual(opened.code.team, leader.config.id)
        XCTAssertNotNil(opened.code.nonce)
        // A forged sender key never opens it, and neither does the wrong identity.
        var wrongSender = invite; wrongSender.from = TeamIdentity.random().keys
        XCTAssertThrowsError(try TeamNearby.openInvite(wrongSender, identity: joiner, now: 1_002))
        XCTAssertThrowsError(try TeamNearby.openInvite(invite, identity: TeamIdentity.random(), now: 1_002))
        // An expired code is refused at open time, not at accept time.
        XCTAssertThrowsError(try TeamNearby.openInvite(invite, identity: joiner, now: 1_000 + 8 * 86_400)) {
            XCTAssertEqual($0 as? TeamCode.CodeError, .expired)
        }

        // Ignoring removes it; twice is an error, never a silent success.
        try TeamNearby.Store.removeInvite(from: leader.identity.kid, paths: jp)
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp), [])
        XCTAssertThrowsError(try TeamNearby.Store.removeInvite(from: leader.identity.kid, paths: jp)) {
            XCTAssertEqual($0 as? TeamNearby.StoreError, .noInvite)
        }
    }

    /// Important finding (final review): `openInvite` must pin the sealed
    /// code to what the `Invite` body CLAIMS, not just to who sealed it —
    /// `fromName`/`teamName` are plain attacker-chosen strings, and a
    /// stranger who signs their own valid code (or relays someone
    /// else's) could otherwise present a genuine-looking "Loc invites
    /// you to Papaya".
    func testOpenInviteRejectsACodeThatDoesNotMatchTheInvitesClaims() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let joiner = try TeamClient.identity(paths: jp, secrets: js)

        // A genuine invite still opens.
        let genuineLink = try leader.code(expiresIn: 7 * 86_400, nonce: TeamInvites.newNonce(), now: 1_000)
        let genuineSealed = try Envelope.seal(Data(genuineLink.utf8), kind: "invite", from: leader.identity, to: [joiner.keys], at: 1_001)
        let genuine = TeamNearby.Invite(from: leader.identity.keys, fromName: "Loc", teamName: "Papaya", envelope: genuineSealed)
        XCTAssertNoThrow(try TeamNearby.openInvite(genuine, identity: joiner, now: 1_002))

        // Attack 1: a stranger mints a valid code for THEIR OWN team,
        // seals it as themselves (the envelope's signature ties `from`
        // to them), and labels the body with the victim's team name.
        // Its own repository: `create` refuses a remote with content.
        let attackerRemote = try makeRemote("attacker.git")
        let (atp, ats) = machine("attacker")
        let attacker = try TeamClient.create(name: "Evil", remote: attackerRemote, token: nil, paths: atp, secrets: ats, now: 1_000)
        let attackerLink = try attacker.code(expiresIn: 7 * 86_400, nonce: TeamInvites.newNonce(), now: 1_000)
        let attackerSealed = try Envelope.seal(Data(attackerLink.utf8), kind: "invite", from: attacker.identity, to: [joiner.keys], at: 1_001)
        let spoofedTeamName = TeamNearby.Invite(from: attacker.identity.keys, fromName: "Loc", teamName: "Papaya", envelope: attackerSealed)
        XCTAssertThrowsError(try TeamNearby.openInvite(spoofedTeamName, identity: joiner, now: 1_002)) {
            XCTAssertEqual($0 as? TeamNearby.StoreError, .mismatchedInvite)
        }

        // Attack 2: a stranger relays a genuine leaked code (correct
        // team name) but under their own sealing identity — the code's
        // OWN `leader` then disagrees with the envelope's `from`.
        let relayedSealed = try Envelope.seal(Data(genuineLink.utf8), kind: "invite", from: attacker.identity, to: [joiner.keys], at: 1_001)
        let relayed = TeamNearby.Invite(from: attacker.identity.keys, fromName: "Loc", teamName: "Papaya", envelope: relayedSealed)
        XCTAssertThrowsError(try TeamNearby.openInvite(relayed, identity: joiner, now: 1_002)) {
            XCTAssertEqual($0 as? TeamNearby.StoreError, .mismatchedInvite)
        }
    }

    func testInvitesLiveBesideTheTeamsAndAreCapped() throws {
        let (jp, _) = machine("joiner")
        let dir = TeamNearby.Store.invitesDir(paths: jp)
        func invite(_ from: TeamIdentity, team: String = "T", at: Int = 1) throws -> TeamNearby.Invite {
            TeamNearby.Invite(from: from.keys, fromName: "L", teamName: team,
                              envelope: try Envelope.seal(Data("x".utf8), kind: "invite", from: from, to: [], at: at))
        }
        func stamp(_ kid: String, _ mtime: Int) throws {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))],
                                                  ofItemAtPath: dir.appendingPathComponent("\(kid).json").path)
        }
        var oldest: TeamIdentity!
        for i in 0..<TeamNearby.inviteCap {
            let id = TeamIdentity.random()
            if i == 0 { oldest = id }
            // The oldest file's signed `at` is a decoy far in the future —
            // eviction must order by the file's own mtime (the receiver's
            // clock), set explicitly below, not by this (remaining finding A).
            let at = i == 0 ? 99_999_999 : 1
            try TeamNearby.Store.saveInvite(try invite(id, at: at), paths: jp)
            try stamp(id.kid, 1_000 + i)
        }
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp, now: 6_000).count, TeamNearby.inviteCap)
        // The invites dir is beside the team dirs, never inside one, and is
        // not mistaken for a team (no config.json).
        XCTAssertEqual(TeamNearby.Store.invitesDir(paths: jp), jp.base.appendingPathComponent("invites"))
        XCTAssertEqual(jp.teamIDs(), [])
        // Sanity: `oldest`'s signed `at` really is the far-future decoy,
        // not accidentally the smallest — if eviction still keyed on
        // `at`, `oldest` would never be picked as the victim below.
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp, now: 6_000).first { $0.from.kid == oldest.kid }?.at, 99_999_999)
        // Full: a new sender evicts the OLDEST invite by the receiver's
        // own clock (mtime), not the sender-chosen `at`, rather than
        // being refused — a stranger who fills every slot can no longer
        // lock a genuine leader's invite out forever, and `oldest`'s
        // far-future `at` gains it nothing: mtime says it's still oldest.
        let newcomer = TeamIdentity.random()
        XCTAssertNoThrow(try TeamNearby.Store.saveInvite(try invite(newcomer, at: 5_000), paths: jp))
        var after = TeamNearby.Store.invites(paths: jp, now: 6_000)
        XCTAssertEqual(after.count, TeamNearby.inviteCap)
        XCTAssertFalse(after.contains { $0.from.kid == oldest.kid })
        XCTAssertTrue(after.contains { $0.from.kid == newcomer.kid })
        // …but a sender already in the book may replace its own invite,
        // without evicting anyone.
        let first = try XCTUnwrap(after.first)
        var again = first; again.teamName = "T2"
        XCTAssertNoThrow(try TeamNearby.Store.saveInvite(again, paths: jp))
        after = TeamNearby.Store.invites(paths: jp, now: 6_000)
        XCTAssertEqual(after.count, TeamNearby.inviteCap)
        XCTAssertEqual(after.first(where: { $0.from.kid == first.from.kid })?.teamName, "T2")
        // A garbled or misnamed file is skipped, not fatal.
        try Data("junk".utf8).write(to: dir.appendingPathComponent("zzz.json"))
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp, now: 6_000).count, TeamNearby.inviteCap)
    }

    /// Finding 4: an invitation older than 30 days is dropped on load —
    /// and the stale file is deleted, so it also frees its cap slot.
    func testInvitesOlderThanThirtyDaysAreDroppedOnLoad() throws {
        let (jp, _) = machine("joiner")
        let stale = TeamIdentity.random()
        // The signed `at` is a decoy far in the future — the prune must
        // key on the file's own mtime (the receiver's clock), set
        // explicitly below, or a sender that forward-dates `at` would
        // dodge the prune forever (remaining finding A).
        let staleInvite = TeamNearby.Invite(from: stale.keys, fromName: "L", teamName: "T",
                                            envelope: try Envelope.seal(Data("x".utf8), kind: "invite", from: stale, to: [], at: 99_999_999))
        try TeamNearby.Store.saveInvite(staleInvite, paths: jp)
        let file = TeamNearby.Store.invitesDir(paths: jp).appendingPathComponent("\(stale.kid).json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
        // Just under the line: still there.
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp, now: 1_000 + 30 * 86_400 - 1).map(\.id), [stale.kid])
        // At/over the line: dropped, and the file itself is gone.
        XCTAssertEqual(TeamNearby.Store.invites(paths: jp, now: 1_000 + 30 * 86_400), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLeaderInvitesAPeerAndTheOpenedLinkJoinsAndAutoApproves() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let peerLocal = TeamNearby.Local.load(name: "Bo", discoverable: true, paths: jp, secrets: js)
        let peerEndpoint = TeamNearby.Endpoint(local: peerLocal, store: { _ in "branch" },
                                               storeInvite: { try TeamNearby.Store.saveInvite($0, paths: jp) })
        // An HTTP function that routes into the peer's own `respond` — no sockets.
        let http: TeamNearby.Client.HTTP = { method, _, _, path, body in
            let reply = TeamNearby.respond(MirrorTransport.Request(method: method, target: path, headers: [:],
                                                                   body: body ?? Data()), endpoint: peerEndpoint)
            let parsed = try XCTUnwrap(reply.flatMap(MirrorTransport.parseResponse))
            return (parsed.status, parsed.body)
        }
        let peer = TeamNearby.Peer(name: "Bo", host: "bo.local", port: 1, kid: joiner.kid,
                                   team: nil, role: "none", discoverable: true)

        let out = try TeamNearby.Client.invite(to: peer, fromName: "Loc", days: 7,
                                               paths: lp, secrets: ls, http: http, now: 1_010)
        XCTAssertEqual(out, TeamNearby.Client.InviteOutcome(team: leader.config.id, teamName: "Papaya",
                                                            to: joiner.kid, ok: true))
        let stored = try XCTUnwrap(TeamNearby.Store.invites(paths: jp, now: 1_011).first)
        XCTAssertEqual(stored.from, leader.identity.keys)
        XCTAssertEqual(stored.fromName, "Loc")
        XCTAssertEqual(stored.teamName, "Papaya")

        // The nonce is in the leader's own book with the link's expiry.
        let opened = try TeamNearby.openInvite(stored, identity: joiner, now: 1_011)
        let nonce = try XCTUnwrap(opened.code.nonce)
        XCTAssertEqual(TeamInvites.load(teamDir: lp.teamDir(leader.config.id)).nonces[nonce], 1_010 + 7 * 86_400)

        // Accepting with the opened text lands a request the leader's
        // auto-approve recognises (#161's proof).
        let member = try TeamClient.request(code: opened.text, name: "Bo", devices: ["Linux"], platform: "linux",
                                            paths: jp, secrets: js, now: 1_012)
        XCTAssertEqual(member.config.id, leader.config.id)
        _ = try leader.fetch()
        let pending = try XCTUnwrap(try leader.requests().first)
        XCTAssertEqual(TeamInvites.load(teamDir: lp.teamDir(leader.config.id)).matches(pending.doc, now: 1_013), nonce)

        // A peer whose TXT kid is not what /team/key answers: nothing sealed, nothing sent.
        var liar = peer; liar.kid = TeamIdentity.random().kid
        XCTAssertThrowsError(try TeamNearby.Client.invite(to: liar, fromName: "Loc", paths: lp, secrets: ls, http: http)) {
            guard case TeamNearby.Client.ClientError.keyMismatch = $0 else { return XCTFail("\($0)") }
        }
        // A machine that leads no team cannot invite (the joiner is a member at best).
        XCTAssertThrowsError(try TeamNearby.Client.invite(to: peer, fromName: "Bo", paths: jp, secrets: js, http: http)) {
            XCTAssertEqual($0 as? TeamNearby.Client.ClientError, .notALeader)
        }
    }

    /// Finding 5: `Client.invite` mints before it knows the peer
    /// accepted, so a refused POST must drop the nonce it already
    /// committed rather than leave it dangling in the leader's book.
    func testClientInviteDropsTheNonceWhenThePeerRefuses() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let peerIdentity = TeamIdentity.random()
        let peer = TeamNearby.Peer(name: "Bo", host: "bo.local", port: 1, kid: peerIdentity.kid,
                                   team: nil, role: "none", discoverable: true)
        // The peer answers /team/key genuinely, then refuses the invite.
        let http: TeamNearby.Client.HTTP = { method, _, _, path, body in
            if path == TeamNearby.keyPath {
                let reply = TeamNearby.KeyReply(name: "Bo", keys: peerIdentity.keys, team: nil, role: "none")
                return (200, try CanonicalJSON.encode(reply))
            }
            return (403, Data())
        }
        XCTAssertThrowsError(try TeamNearby.Client.invite(to: peer, fromName: "Loc", paths: lp, secrets: ls, http: http, now: 1_010)) {
            guard case TeamNearby.Client.ClientError.refused = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(TeamInvites.load(teamDir: lp.teamDir(leader.config.id)).nonces, [:])
    }

    func testPeerByAddressComesFromTheKeyReply() throws {
        let keys = TeamIdentity.random().keys
        let http: TeamNearby.Client.HTTP = { method, host, port, path, _ in
            XCTAssertEqual(method, "GET"); XCTAssertEqual(host, "10.0.0.5"); XCTAssertEqual(port, 4711)
            guard path == TeamNearby.keyPath else { return (404, Data()) }
            return (200, try CanonicalJSON.encode(TeamNearby.KeyReply(name: "Loc", keys: keys, team: "team-1", role: "leader")))
        }
        let peer = try TeamNearby.Client.peer(host: "10.0.0.5", port: 4711, http: http)
        XCTAssertEqual(peer, TeamNearby.Peer(name: "Loc", host: "10.0.0.5", port: 4711, kid: keys.kid, team: "team-1",
                                             role: "leader", discoverable: true))
        XCTAssertThrowsError(try TeamNearby.Client.peer(host: "10.0.0.5", port: 4711, http: { _, _, _, _, _ in (404, Data()) })) {
            guard case TeamNearby.Client.ClientError.keyMismatch(404) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testParseAddress() {
        let p = MirrorTransport.defaultPort
        XCTAssertEqual(TeamNearby.Client.parseAddress("10.0.0.5")?.port, p)
        XCTAssertEqual(TeamNearby.Client.parseAddress("elgnas.local:4711").map { "\($0.host) \($0.port)" }, "elgnas.local 4711")
        XCTAssertEqual(TeamNearby.Client.parseAddress(" http://10.0.0.5/ ").map { "\($0.host) \($0.port)" }, "10.0.0.5 \(p)")
        XCTAssertEqual(TeamNearby.Client.parseAddress("[fe80::1]:4711").map { "\($0.host) \($0.port)" }, "fe80::1 4711")
        XCTAssertEqual(TeamNearby.Client.parseAddress("fe80::1")?.host, "fe80::1")
        XCTAssertNil(TeamNearby.Client.parseAddress(""))
        XCTAssertNil(TeamNearby.Client.parseAddress("host:notaport"))
    }
}
