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
        #if os(Windows)
        try XCTSkipIf(true, "Team git shellouts / POSIX file modes are not ported to Windows yet")
        #endif
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
        #if os(Windows)
        try XCTSkipIf(true, "Team git shellouts / POSIX file modes are not ported to Windows yet")
        #endif
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
    /// #499: a pass whose fetch brought nothing and whose publish pushed
    /// nothing answers from the last scan; anything that moves a ref (a
    /// publish, a roster change) scans and folds again.
    func testTheScanIsReusedWhileTheStoreRefsHoldAndRedoneWhenTheyMove() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        _ = try leader.publish(kind: "now", path: "now.json", plaintext: Data("{\"busy\":1}".utf8), audience: .team, now: 1_005)
        let docs = TeamReader.DocCache(), scans = TeamReader.ScanCache()
        let first = TeamReader.scan(client: leader, docs: docs, scans: scans)
        XCTAssertEqual(first.headers.map(\.entry.path), ["m/\(leader.identity.kid)/now.json"])
        XCTAssertEqual(scans.hits, 0)

        _ = try leader.fetch()   // nothing new on the remote
        let second = TeamReader.scan(client: leader, docs: docs, scans: scans)
        XCTAssertEqual(scans.hits, 1)
        XCTAssertEqual(second.headers.map(\.entry.path), first.headers.map(\.entry.path))
        XCTAssertEqual(second.reader?.members[leader.identity.kid]?.now, first.reader?.members[leader.identity.kid]?.now)

        _ = try leader.publish(kind: "sessions", path: "sessions/index.json", plaintext: Data("{\"sessions\":[]}".utf8), audience: .team, now: 1_010)
        let third = TeamReader.scan(client: leader, docs: docs, scans: scans)
        XCTAssertEqual(scans.hits, 1, "a publish moved m/<kid>, so the scan must run again")
        XCTAssertEqual(third.headers.map(\.entry.path).sorted(),
                       ["m/\(leader.identity.kid)/now.json", "m/\(leader.identity.kid)/sessions/index.json"])
        // And the new fingerprint is the one reused next.
        _ = TeamReader.scan(client: leader, docs: docs, scans: scans)
        XCTAssertEqual(scans.hits, 2)
    }

    /// A pass whose scan or fold failed is never the cached answer: the
    /// next pass runs the scan again instead of a hit on an empty roster.
    func testAFailedScanIsNotCachedUnderTheFingerprint() throws {
        struct Broken: Error {}
        let scans = TeamReader.ScanCache()
        let failed = TeamReader.scan(fingerprint: "f1", scans: scans, headers: { throw Broken() }, fold: { _ in TeamReader() })
        XCTAssertTrue(failed.headers.isEmpty); XCTAssertNil(failed.reader)
        let unfolded = TeamReader.scan(fingerprint: "f1", scans: scans, headers: { [] }, fold: { _ in throw Broken() })
        XCTAssertTrue(unfolded.headers.isEmpty); XCTAssertNil(unfolded.reader)
        XCTAssertEqual(scans.hits, 0)
        var scanned = 0
        let good = TeamReader.scan(fingerprint: "f1", scans: scans, headers: { scanned += 1; return [] }, fold: { _ in TeamReader() })
        XCTAssertNotNil(good.reader); XCTAssertEqual(scanned, 1)
        _ = TeamReader.scan(fingerprint: "f1", scans: scans, headers: { scanned += 1; return [] }, fold: { _ in TeamReader() })
        XCTAssertEqual(scanned, 1); XCTAssertEqual(scans.hits, 1)
        // No fingerprint (the store could not be read): scanned, never stored.
        _ = TeamReader.scan(fingerprint: nil, scans: scans, headers: { scanned += 1; return [] }, fold: { _ in TeamReader() })
        XCTAssertEqual(scanned, 2); XCTAssertEqual(scans.hits, 1)
    }

    /// #499: with a memo attached, the headers are listed once per store
    /// state — a publish moves a ref and lists again; without one, never memoised.
    func testReadableHeadersAreMemoisedWhileTheStoreRefsHold() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        _ = try leader.publish(kind: "now", path: "now.json", plaintext: Data("{\"busy\":1}".utf8), audience: .team, now: 1_005)
        let plain = try leader.readableHeaders()
        XCTAssertEqual(plain.map(\.entry.path), ["m/\(leader.identity.kid)/now.json"])
        let memo = TeamClient.HeaderMemo()
        leader.headerMemo = memo
        XCTAssertEqual(try leader.readableHeaders().map(\.entry.path), plain.map(\.entry.path))
        XCTAssertEqual(memo.hits, 0)
        // A fetch that brought nothing: its own senders lookup is a hit, and so is the next read.
        _ = try leader.fetch()
        XCTAssertEqual(memo.hits, 1)
        XCTAssertEqual(try leader.readableHeaders().map(\.entry.path), plain.map(\.entry.path))
        XCTAssertEqual(memo.hits, 2)
        _ = try leader.publish(kind: "sessions", path: "sessions/index.json", plaintext: Data("{\"sessions\":[]}".utf8), audience: .team, now: 1_010)
        XCTAssertEqual(try leader.readableHeaders().map(\.entry.path).sorted(),
                       ["m/\(leader.identity.kid)/now.json", "m/\(leader.identity.kid)/sessions/index.json"])
        XCTAssertEqual(memo.hits, 2, "the publish moved m/<kid>: listed again")
        _ = try leader.readableHeaders()
        XCTAssertEqual(memo.hits, 3)
        // The roster in memory is part of the key: a client filtering by a
        // different roster under the same refs lists again.
        XCTAssertNotEqual(try leader.storeFingerprint(), try leader.store.refsFingerprint() + "\n")
    }

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

    /// #55: every leader action re-signs the roster as the leader who made
    /// it, while a code names its minter as the trust root. On a team with
    /// two leaders the roster's signer is whoever edited last, so a code
    /// from the other leader must be accepted through the roster's own
    /// history: back to a roster the code's leader signed, then forward
    /// one accepted step at a time. A forged step still fails.
    func testACodeFromEitherLeaderJoinsWhenTheOtherLeaderSignedTheRosterLast() throws {
        let remote = try makeRemote()
        let (fp, fs) = machine("founder")
        let (cp, cs) = machine("coleader")
        let founder = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: fp, secrets: fs, now: 1_000)
        let coleader = try TeamClient.request(code: try founder.code(expiresIn: 600, now: 1_000), name: "Cy",
                                              devices: [], platform: "linux", paths: cp, secrets: cs, now: 1_010)
        _ = try founder.fetch()
        try founder.approve(kid: coleader.identity.kid, now: 1_020)
        try founder.promote(kid: coleader.identity.kid, now: 1_030)
        _ = try coleader.fetch()
        XCTAssertTrue(coleader.isLeader)

        // The co-leader approves someone: the roster's tip is now theirs.
        let (dp, ds) = machine("dee")
        let dee = try TeamClient.request(code: try founder.code(expiresIn: 600, now: 1_030), name: "Dee",
                                         devices: [], platform: "linux", paths: dp, secrets: ds, now: 1_040)
        _ = try coleader.fetch()
        try coleader.approve(kid: dee.identity.kid, now: 1_050)
        XCTAssertEqual(coleader.roster?.by, coleader.identity.kid)
        XCTAssertEqual(coleader.roster?.doc.rev, 4)

        // A founder code still works: the chain runs founder → founder → founder → co-leader.
        let (ep, es) = machine("eve")
        let eve = try TeamClient.request(code: try founder.code(expiresIn: 600, now: 1_050), name: "Eve",
                                         devices: [], platform: "linux", paths: ep, secrets: es, now: 1_060)
        XCTAssertEqual(try eve.status().role, "pending")
        XCTAssertEqual(eve.roster?.doc.rev, 4)
        XCTAssertEqual(eve.config.leaderKid, founder.identity.kid)

        // And the mirror: the founder edits last, a co-leader code joins.
        _ = try founder.fetch()
        try founder.approve(kid: eve.identity.kid, now: 1_070)
        XCTAssertEqual(founder.roster?.by, founder.identity.kid)
        let (gp, gs) = machine("gil")
        let gil = try TeamClient.request(code: try coleader.code(expiresIn: 600, now: 1_070), name: "Gil",
                                         devices: [], platform: "linux", paths: gp, secrets: gs, now: 1_080)
        XCTAssertEqual(gil.roster?.doc.rev, 5)
        XCTAssertEqual(gil.config.leaderKid, coleader.identity.kid)
        // Later fetches step from the roster the join accepted.
        _ = try coleader.fetch()
        try coleader.approve(kid: gil.identity.kid, now: 1_090)
        XCTAssertEqual(try gil.fetch().rev, 6)
        XCTAssertTrue(gil.isMember)

        // A forged step on top (a member with the store credential names
        // themselves leader) breaks the chain for a newcomer, whichever
        // leader's code they hold.
        let mal = TeamIdentity.random()
        var forged = try XCTUnwrap(coleader.roster).doc
        forged.rev += 1
        forged.leaders.append(TeamRoster.Member(keys: mal.keys, name: "Mal", since: 1_095))
        let raw = TeamGit(dir: scratch.appendingPathComponent("mal-store"), remote: remote, token: nil, author: mal.kid)
        try raw.open(); try raw.sync()
        try raw.put("roster/team.json", try CanonicalJSON.encode(try Signed.make(forged, by: mal)))
        for (code, name) in [(try founder.code(expiresIn: 600, now: 1_095), "hal-f"),
                             (try coleader.code(expiresIn: 600, now: 1_095), "hal-c")] {
            let (hp, hs) = machine(name)
            XCTAssertThrowsError(try TeamClient.request(code: code, name: "Hal", devices: [], platform: "linux",
                                                        paths: hp, secrets: hs, now: 1_100), name) {
                XCTAssertEqual($0 as? TeamClient.ClientError, .badCode)
            }
            XCTAssertEqual(hp.teamIDs(), [])
        }
    }

    /// #321: transcript chunks publish to `t/<kid>`; a routine fetch pulls
    /// that branch only for readers the sender's `now.json` hint names,
    /// anyone else pulls it on demand, chunks from before the split still
    /// read from `m/<kid>`, and leaving clears both branches.
    func testTranscriptsRideTheirOwnBranchFetchedByHintOrOnDemand() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (ap, asec) = machine("ann"), (bp, bs) = machine("bo")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let code = try leader.code(expiresIn: 600, now: 1_000)
        let ann = try TeamClient.request(code: code, name: "Ann", devices: [], platform: "linux", paths: ap, secrets: asec, now: 1_010)
        let bo = try TeamClient.request(code: code, name: "Bo", devices: [], platform: "linux", paths: bp, secrets: bs, now: 1_011)
        _ = try leader.fetch()
        try leader.approve(kid: ann.identity.kid, now: 1_020)
        try leader.approve(kid: bo.identity.kid, now: 1_021)
        _ = try ann.fetch(); _ = try bo.fetch()
        let annT = "origin/t/\(ann.identity.kid)"

        // A chunk from before the split, sealed to the leaders under m/.
        let old = "m/\(ann.identity.kid)/transcripts/s1/1.jsonl"
        try ann.store.put(old, try Envelope.seal(Data("old\n".utf8), kind: TeamKinds.transcripts, from: ann.identity,
                                                 to: leader.roster!.doc.recipients(for: .leaders), at: 1_025))
        // Today's publish: the hint says transcripts reach the leaders.
        let now = TeamDocs.Now(at: 1_030, sessions: [], fleets: [], blockers: [], crashesToday: 0,
                               sharesTo: [TeamKinds.transcripts: .leaders])
        let paths = try ann.publish([
            .init(kind: TeamKinds.now, path: "now.json", plaintext: try CanonicalJSON.encode(now), audience: .team),
            .init(kind: TeamKinds.transcripts, path: "transcripts/s1/2.jsonl", plaintext: Data("new\n".utf8), audience: .leaders),
        ], now: 1_030)
        let chunk = "t/\(ann.identity.kid)/transcripts/s1/2.jsonl"
        XCTAssertEqual(paths, ["m/\(ann.identity.kid)/now.json", chunk])

        // The leader's routine fetch brings Ann's transcript branch by hint…
        _ = try leader.fetch()
        XCTAssertTrue(remoteBranches(in: lp.storeDir(leader.config.id)).contains(annT))
        XCTAssertEqual(try TeamReader.load(client: leader).members[ann.identity.kid]?.transcripts["s1"], [old, chunk])
        XCTAssertEqual(try leader.read(chunk).1, Data("new\n".utf8))
        // …and Bo's does not: the hint names the leaders, so the bytes never move to him.
        _ = try bo.fetch()
        XCTAssertFalse(remoteBranches(in: bp.storeDir(leader.config.id)).contains(annT))
        XCTAssertFalse(try bo.readable().map(\.path).contains(chunk))
        // On demand the branch arrives; the envelope still isn't his to read.
        try bo.fetchTranscripts(from: ann.identity.kid)
        XCTAssertTrue(remoteBranches(in: bp.storeDir(leader.config.id)).contains(annT))
        XCTAssertFalse(try bo.readable().map(\.path).contains(chunk))
        XCTAssertThrowsError(try bo.fetchTranscripts(from: "../x"))

        // Leaving clears m/ and t/ alike.
        try ann.leave(now: 1_040)
        try leader.fetchTranscripts(from: ann.identity.kid)
        _ = try leader.fetch()
        XCTAssertEqual(try leader.store.list("m/\(ann.identity.kid)/"), [])
        XCTAssertEqual(try leader.store.list("t/\(ann.identity.kid)/"), [])
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
        #if os(Windows)
        try XCTSkipIf(true, "Team git shellouts / POSIX file modes are not ported to Windows yet")
        #endif
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
