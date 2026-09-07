import XCTest
@testable import InfinitusCore

final class TeamClientTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamclient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    /// One "machine": its own paths and secrets.
    /// `refs/remotes/origin/*` of a store dir, sorted.
    func remoteBranches(in storeDir: URL) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--git-dir", storeDir.appendingPathComponent("store.git").path,
                       "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/"]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).sorted()
    }

    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// A create that dies on the remote used to leave `<base>/<id>/store/`
    /// behind — a config-less directory `teamIDs()` ignores but the user's
    /// disk keeps (one was still on the 2026-09-06 machine).
    func testAFailedCreateLeavesNoHalfMadeTeamBehind() throws {
        let (paths, secrets) = machine("solo")
        XCTAssertThrowsError(try TeamClient.create(name: "Papaya", remote: "file:///nonexistent/nope.git", token: "t0ken",
                                                   paths: paths, secrets: secrets, now: 1_000))
        XCTAssertEqual(paths.teamIDs(), [])
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: paths.base.path)) ?? []).filter { $0 != "secrets" }
        XCTAssertEqual(left, [], "no team directory survives a failed create")
        // The identity is this machine's, not the team's: it stays.
        XCTAssertEqual(secrets.read(TeamClient.identitySecretName)?.count, 32)
    }

    /// Spec §6.1: "an empty private repo". Creating on a remote that
    /// already holds something would push a roster into someone else's
    /// history — and a member joining later would fetch a store nobody
    /// meant to share.
    func testCreateRefusesARemoteThatAlreadyHasContent() throws {
        let remote = try makeRemote()
        // Seed the bare repo through the store adapter itself: one commit
        // on the `roster` branch is all "not empty" takes.
        let seed = TeamGit(dir: scratch.appendingPathComponent("seed"), remote: remote, token: nil, author: "seed")
        try seed.open()
        try seed.put("roster/team.json", Data("{}".utf8))

        let (paths, secrets) = machine("late")
        XCTAssertThrowsError(try TeamClient.create(name: "Papaya", remote: remote, token: "t0ken",
                                                   paths: paths, secrets: secrets, now: 1_000)) {
            guard case TeamGit.GitError.notEmpty = $0 else { return XCTFail("expected notEmpty, got \($0)") }
            XCTAssertEqual("\($0)", "That remote already has content — use an empty repository",
                           "the pane and the CLI both print the interpolated error")
        }
        // The refusal runs `create`'s own cleanup: no dir, no token.
        XCTAssertEqual(paths.teamIDs(), [])
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: paths.base.path)) ?? []).filter { $0 != "secrets" }
        XCTAssertEqual(left, [], "no team directory survives a refused create")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.secretsDir.path)) ?? []
        XCTAssertEqual(names.filter { $0.hasPrefix("team.") }, [], "no store token is left behind either")
    }

    func testIdentityIsCreatedOnceAndReloaded() throws {
        let (paths, secrets) = machine("a")
        let first = try TeamClient.identity(paths: paths, secrets: secrets)
        let again = try TeamClient.identity(paths: paths, secrets: secrets)
        XCTAssertEqual(first.keys, again.keys)
        XCTAssertEqual(secrets.read("identity")?.count, 32)
    }

    func testCreateRequestApprovePublishRead() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (mp, ms) = machine("member")
        let (sp, ss) = machine("stranger")

        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        XCTAssertTrue(leader.isLeader)
        XCTAssertEqual(try leader.status().role, "leader")
        XCTAssertEqual(lp.teamIDs(), [leader.config.id])

        // The leader's own branch exists before anyone joins: it is what a
        // join must NOT fetch (#321 — it carries the transcripts).
        let seed = try leader.publish(kind: "aggregates", path: "aggregates/seed.json", plaintext: Data("s".utf8),
                                      audience: .team, now: 1_005)
        let leaderBranch = "origin/m/\(leader.identity.kid)"
        let code = try leader.code(expiresIn: 60, now: 1_000)
        let member = try TeamClient.request(code: code, name: "Bo", devices: ["Mac"], platform: "macos",
                                            paths: mp, secrets: ms, now: 1_010)
        XCTAssertFalse(member.isMember)
        XCTAssertEqual(remoteBranches(in: mp.storeDir(leader.config.id)), ["origin/requests", "origin/roster"])
        // A pending member keeps to those two on every fetch, too.
        _ = try member.fetch(branches: TeamClient.joinBranches)
        XCTAssertEqual(remoteBranches(in: mp.storeDir(leader.config.id)), ["origin/requests", "origin/roster"])
        XCTAssertEqual(try member.status().role, "pending")
        XCTAssertEqual(member.config.leaderKid, leader.identity.kid)
        XCTAssertThrowsError(try member.code()) { XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader) }
        XCTAssertThrowsError(try member.publish(kind: "now", path: "now.json", plaintext: Data(), audience: .leaders)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
        // Expired code.
        XCTAssertThrowsError(try TeamClient.request(code: code, name: "Late", devices: [], platform: "linux",
                                                    paths: sp, secrets: ss, now: 2_000))

        // A code signed by someone who doesn't lead the store it points at.
        let impostor = TeamIdentity.random()
        let fake = try TeamCode(team: leader.config.id, name: "Papaya", remote: remote, token: nil,
                                leader: impostor.keys, expires: 5_000).encoded(by: impostor)
        let (ip, isec) = machine("impostor-joiner")
        XCTAssertThrowsError(try TeamClient.request(code: fake, name: "X", devices: [], platform: "linux",
                                                    paths: ip, secrets: isec, now: 1_005)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .badCode)
        }

        _ = try leader.fetch()
        let pending = try leader.requests()
        XCTAssertEqual(pending.map(\.doc.name), ["Bo"])
        XCTAssertThrowsError(try leader.approve(kid: "nobody")) { XCTAssertEqual($0 as? TeamClient.ClientError, .unknownRequest) }
        try leader.approve(kid: member.identity.kid, now: 1_020)
        XCTAssertEqual(try leader.requests(), [])
        XCTAssertEqual(leader.roster?.doc.rev, 2)
        XCTAssertEqual(leader.roster?.doc.members.map(\.name), ["Bo"])

        let roster = try member.fetch()
        XCTAssertTrue(member.isMember)
        XCTAssertEqual(roster.rev, 2)
        XCTAssertEqual(try member.status().role, "member")

        // Member publishes to leaders; the leader reads it; a stranger with the code can't.
        let path = try member.publish(kind: "now", path: "now.json", plaintext: Data("{\"busy\":1}".utf8),
                                      audience: .leaders, now: 1_030)
        XCTAssertEqual(path, "m/\(member.identity.kid)/now.json")
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path).sorted(), [path, seed].sorted())
        let (header, plain) = try leader.read(path)
        XCTAssertEqual(header.kind, "now")
        XCTAssertEqual(header.from, member.identity.kid)
        XCTAssertEqual(plain, Data("{\"busy\":1}".utf8))
        XCTAssertEqual(try member.read(path).1, plain)   // own file

        let stranger = try TeamClient.request(code: try leader.code(expiresIn: 60, now: 1_040), name: "Eve",
                                              devices: [], platform: "linux", paths: sp, secrets: ss, now: 1_041)
        XCTAssertEqual(try stranger.readable(), [])
        XCTAssertThrowsError(try stranger.read(path))

        // Leader publishes to the team; the member reads it after a fetch.
        let team = try leader.publish(kind: "aggregates", path: "aggregates/week.json", plaintext: Data("w".utf8),
                                      audience: .team, now: 1_050)
        _ = try member.fetch()
        XCTAssertEqual(try member.read(team).1, Data("w".utf8))
        // An admitted member's full fetch brings the leader's branch along.
        XCTAssertTrue(remoteBranches(in: mp.storeDir(leader.config.id)).contains(leaderBranch))

        // Reopen from disk keeps identity, roster and role.
        let reopened = try TeamClient.open(id: member.config.id, paths: mp, secrets: ms)
        XCTAssertEqual(reopened.identity.keys, member.identity.keys)
        XCTAssertEqual(reopened.roster?.doc.rev, 2)
        XCTAssertTrue(reopened.isMember)

        // A tampered roster on the remote is refused and the last good one kept.
        let raw = TeamGit(dir: sp.storeDir(leader.config.id), remote: remote, token: nil, author: "eve")
        try raw.open(); try raw.sync()   // the stranger's mirror already exists, so open() no longer fetches
        var bogus = leader.roster!.doc; bogus.rev = 3; bogus.leaders.append(TeamRoster.Member(keys: stranger.identity.keys, name: "Eve", since: 1))
        try raw.put("roster/team.json", try CanonicalJSON.encode(try Signed.make(bogus, by: stranger.identity)))
        XCTAssertThrowsError(try member.fetch())
        XCTAssertEqual(member.roster?.doc.rev, 2)
    }

    /// C1: anyone holding the team code can write to the store, so the
    /// roster a joiner accepts first must carry the code leader's own
    /// signature — not merely list them.
    func testAForgedFirstRosterIsRefusedAndNothingIsPersisted() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let (ep, es) = machine("eve")

        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)

        // Eve holds the code, so she can write: rev 1, leaders [real, eve],
        // signed by eve.
        let eve = try TeamClient.identity(paths: ep, secrets: es)
        var forged = try XCTUnwrap(leader.roster).doc
        forged.leaders.append(TeamRoster.Member(keys: eve.keys, name: "Eve", since: 1_001))
        let raw = TeamGit(dir: ep.storeDir(leader.config.id), remote: remote, token: nil, author: eve.kid)
        try raw.open(); try raw.sync()
        try raw.put("roster/team.json", try CanonicalJSON.encode(try Signed.make(forged, by: eve)))

        XCTAssertThrowsError(try TeamClient.request(code: code, name: "Bo", devices: [], platform: "linux",
                                                    paths: jp, secrets: js, now: 1_010)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .badCode)
        }
        XCTAssertEqual(jp.teamIDs(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: jp.rosterFile(leader.config.id).path))
    }

    /// C2: a kid names exactly one encryption key, so nobody can plant a
    /// request under someone else's kid, and a leader's kid is never
    /// re-approved as a member.
    func testAnImpostorRequestUnderAnotherKidIsIgnored() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (ep, es) = machine("eve")

        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let eve = try TeamClient.identity(paths: ep, secrets: es)

        // Eve holds the code, so she can write requests/<founder kid>.json:
        // the founder's kid over her own keys, signed by her.
        let claim = TeamRequest(keys: TeamKeys(kid: leader.identity.kid, enc: eve.keys.enc, sig: eve.keys.sig),
                                name: "Eve", devices: [], platform: "linux", at: 1_001)
        let forged = Signed(doc: claim, by: leader.identity.kid,
                            sig: try eve.sign(try CanonicalJSON.encode(claim)).base64EncodedString())
        let raw = TeamGit(dir: ep.storeDir(leader.config.id), remote: remote, token: nil, author: eve.kid)
        try raw.open(); try raw.sync()
        try raw.put("requests/\(leader.identity.kid).json", try CanonicalJSON.encode(forged))

        _ = try leader.fetch()
        XCTAssertEqual(try leader.requests(), [])
        XCTAssertThrowsError(try leader.approve(kid: leader.identity.kid, now: 1_002)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .alreadyLeader)
        }
        XCTAssertEqual(leader.roster?.doc.rev, 1)
        XCTAssertEqual(leader.roster?.doc.members, [])
        // A kid that is not one path segment never reaches the store.
        XCTAssertThrowsError(try leader.approve(kid: "../../x", now: 1_003)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .unknownRequest)
        }
        XCTAssertThrowsError(try leader.decline(kid: "")) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .unknownRequest)
        }
        // Declining something that was never requested says so.
        XCTAssertThrowsError(try leader.decline(kid: "nobody")) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .unknownRequest)
        }
    }

    /// #55: the code carries the store's write credential. A join the
    /// store never accepted must leave none of it behind — nor a
    /// config-less team dir.
    func testARefusedJoinLeavesNoCredentialOnDisk() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: "t0ken", paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        // The remote goes away between the code and the request.
        try FileManager.default.removeItem(at: scratch.appendingPathComponent("remote.git"))

        let (mp, ms) = machine("joiner")
        XCTAssertThrowsError(try TeamClient.request(code: code, name: "Bo", devices: [], platform: "linux",
                                                    paths: mp, secrets: ms, now: 1_010))
        XCTAssertNil(ms.read(TeamClient.tokenName(leader.config.id)), "no store token survives a refused join")
        XCTAssertEqual(mp.teamIDs(), [])
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: mp.base.path)) ?? []).filter { $0 != "secrets" }
        XCTAssertEqual(left, [], "no half-made team dir either")
        // The identity is this machine's, not the team's: it stays.
        XCTAssertEqual(ms.read(TeamClient.identitySecretName)?.count, 32)
    }

    /// A leader key signs whatever `team` string it likes into a code —
    /// `TeamCode.decode` only checks the signature, not the id's shape.
    /// `"secrets"` aliases `TeamPaths.secretsDir`, so a join refused by a
    /// dead remote must not let the request's cleanup `defer` delete the
    /// machine identity and every other team's store token living there.
    func testJoinRejectsATeamIDThatAliasesTheSecretsDir() throws {
        let forger = TeamIdentity.random()
        let code = try TeamCode(team: "secrets", name: "Papaya", remote: "file:///nonexistent/nope.git",
                                token: "t0ken", leader: forger.keys, expires: 2_000).encoded(by: forger)

        let (mp, ms) = machine("joiner")
        _ = try TeamClient.identity(paths: mp, secrets: ms) // seeds the identity secret under <base>/secrets
        XCTAssertThrowsError(try TeamClient.request(code: code, name: "Bo", devices: [], platform: "linux",
                                                    paths: mp, secrets: ms, now: 1_000)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .badCode)
        }
        XCTAssertEqual(mp.teamIDs(), [])
        XCTAssertEqual(ms.read(TeamClient.identitySecretName)?.count, 32, "the secrets dir must survive intact")
    }

    /// Same defect, the path-traversal vector: `TeamPaths.teamDir` is a
    /// bare `appendingPathComponent`, so `".."` walks out of `<base>`.
    func testJoinRejectsATraversingTeamID() throws {
        let forger = TeamIdentity.random()
        let code = try TeamCode(team: "../victim", name: "Papaya", remote: "file:///nonexistent/nope.git",
                                token: "t0ken", leader: forger.keys, expires: 2_000).encoded(by: forger)
        // scratch/joiner/../victim resolves to scratch/victim: a sentinel
        // the refused-join `defer` would `removeItem` recursively if the
        // guard above ever regressed.
        let victim = scratch.appendingPathComponent("victim/sentinel")
        try FileManager.default.createDirectory(at: victim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: victim)

        let (mp, ms) = machine("joiner")
        XCTAssertThrowsError(try TeamClient.request(code: code, name: "Bo", devices: [], platform: "linux",
                                                    paths: mp, secrets: ms, now: 1_000)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .badCode)
        }
        XCTAssertEqual(mp.teamIDs(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "the traversal target survives")
    }
}
