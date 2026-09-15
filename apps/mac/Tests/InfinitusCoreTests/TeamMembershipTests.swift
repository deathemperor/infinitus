import XCTest
@testable import InfinitusCore

final class TeamMembershipTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teammember-\(UUID().uuidString)")
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

    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    /// Leader + one approved member on a fresh bare remote.
    func team() throws -> (leader: TeamClient, member: TeamClient, remote: String) {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (mp, ms) = machine("member")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let member = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Bo", devices: [],
                                            platform: "linux", paths: mp, secrets: ms, now: 1_010)
        _ = try leader.fetch()
        try leader.approve(kid: member.identity.kid, now: 1_020)
        _ = try member.fetch()
        return (leader, member, remote)
    }

    // MARK: roster rules

    func testRosterSchemaIsChecked() throws {
        let leader = TeamIdentity.random()
        var roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: leader.keys, name: "L", since: 1, founder: true)], rev: 1)
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(try Signed.make(roster, by: leader), previous: nil))
        roster.schema = 2
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(try Signed.make(roster, by: leader), previous: nil)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .badSchema)
        }
    }

    func testAudiencesAreExplicit() {
        let l = TeamIdentity.random(), a = TeamIdentity.random(), b = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: l.keys, name: "L", since: 1, founder: true)],
                                members: [TeamRoster.Member(keys: a.keys, name: "A", since: 2),
                                          TeamRoster.Member(keys: b.keys, name: "B", since: 3)], rev: 1)
        XCTAssertEqual(roster.recipients(for: .leaders).map(\.kid), [l.kid])
        XCTAssertEqual(Set(roster.recipients(for: .team).map(\.kid)), [l.kid, a.kid, b.kid])
        XCTAssertEqual(roster.recipients(for: .members([b.kid])).map(\.kid), [b.kid])          // no implicit leader
        XCTAssertEqual(Set(roster.recipients(for: .members([l.kid, b.kid])).map(\.kid)), [l.kid, b.kid])
        XCTAssertEqual(roster.recipients(for: .members(["nobody"])), [])
    }

    func testRemovedKeysServeOnlyEarlierEnvelopes() {
        let l = TeamIdentity.random(), gone = TeamIdentity.random()
        let roster = TeamRoster(id: "t", name: "T", createdAt: 1,
                                leaders: [TeamRoster.Member(keys: l.keys, name: "L", since: 1, founder: true)],
                                removed: [TeamRoster.Removed(kid: gone.kid, at: 500, keys: gone.keys)], rev: 2)
        XCTAssertEqual(roster.keys(for: gone.kid, at: 499), gone.keys)
        // Spec §3/§10: rejected only when sealed AFTER the removal. The
        // removal instant itself is still theirs — a member removed at
        // 500 was a member at 500.
        XCTAssertEqual(roster.keys(for: gone.kid, at: 500), gone.keys)
        XCTAssertNil(roster.keys(for: gone.kid, at: 501))
        XCTAssertEqual(roster.keys(for: l.kid, at: 999_999), l.keys)
        XCTAssertNil(roster.keys(for: "stranger", at: 0))
        // A removed entry without keys (older roster) serves nothing.
        var legacy = roster; legacy.removed = [TeamRoster.Removed(kid: gone.kid, at: 500)]
        XCTAssertNil(legacy.keys(for: gone.kid, at: 1))
    }

    func testKindsFollowPathShape() {
        func kind(_ p: String) -> String? { TeamKinds.expected(at: p)?.kind }
        XCTAssertEqual(kind("m/k/days/2026-09-05.json"), "stats")
        XCTAssertEqual(kind("m/k/now.json"), "now")
        XCTAssertEqual(kind("m/k/sessions/index.json"), "sessions")
        XCTAssertEqual(kind("m/k/transcripts/s1/3.jsonl"), "transcripts")
        XCTAssertEqual(kind("m/k/transcripts/s1/subagents/agent-a/1.jsonl"), "transcripts")
        XCTAssertEqual(kind("m/k/crashes.json"), "crashes")
        XCTAssertEqual(kind("m/k/aggregates/week.json"), "aggregates")
        XCTAssertEqual(kind("roster/aggregates/week.json"), "aggregates")
        XCTAssertEqual(TeamKinds.expected(at: "m/k/now.json")?.from, "k")
        XCTAssertNil(TeamKinds.expected(at: "roster/aggregates/week.json")?.from)
        XCTAssertNil(kind("m/k/other.json"))
        XCTAssertNil(kind("m/k/days/x/y.json"))
        XCTAssertNil(kind("requests/k.json"))
        XCTAssertNil(kind("m/k/transcripts/s1/3.json"))
        // #321: transcripts publish to t/<kid>, which holds nothing else;
        // chunks from before the split still read from m/<kid>.
        XCTAssertEqual(kind("t/k/transcripts/s1/3.jsonl"), "transcripts")
        XCTAssertEqual(kind("t/k/transcripts/s1/subagents/agent-a/1.jsonl"), "transcripts")
        XCTAssertEqual(TeamKinds.expected(at: "t/k/transcripts/s1/3.jsonl")?.from, "k")
        XCTAssertNil(kind("t/k/now.json"))
        XCTAssertNil(kind("t/k/days/2026-09-05.json"))
        XCTAssertEqual(TeamKinds.storePath("transcripts/s1/3.jsonl", kid: "k"), "t/k/transcripts/s1/3.jsonl")
        XCTAssertEqual(TeamKinds.storePath("now.json", kid: "k"), "m/k/now.json")
        XCTAssertEqual(TeamKinds.storePath("other.json", kid: "k"), "m/k/other.json")   // then `check` refuses it

        let h = Envelope.Header(v: 1, kind: "now", from: "k", eph: "", to: [], at: 1, nonce: "", sig: nil)
        XCTAssertNoThrow(try TeamKinds.check(h, at: "m/k/now.json"))
        XCTAssertThrowsError(try TeamKinds.check(h, at: "m/k/days/2026-09-05.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }
        XCTAssertThrowsError(try TeamKinds.check(h, at: "m/other/now.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .senderMismatch)
        }
        XCTAssertThrowsError(try TeamKinds.check(h, at: "m/k/nope")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .badPath)
        }
    }

    // MARK: roster edits over the store

    func testPromoteAndRemove() throws {
        let (leader, member, remote) = try team()
        // A second member, to be promoted.
        let (cp, cs) = machine("carol")
        let carol = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_030), name: "Carol", devices: [],
                                           platform: "linux", paths: cp, secrets: cs, now: 1_031)
        _ = try leader.fetch()
        try leader.approve(kid: carol.identity.kid, now: 1_032)
        XCTAssertThrowsError(try leader.promote(kid: "nobody")) { XCTAssertEqual($0 as? TeamClient.ClientError, .unknownMember) }
        try leader.promote(kid: carol.identity.kid, now: 1_040)
        XCTAssertEqual(leader.roster?.doc.rev, 4)
        XCTAssertTrue(leader.roster?.doc.isLeader(carol.identity.kid) ?? false)
        XCTAssertEqual(leader.roster?.doc.members.map(\.name), ["Bo"])
        XCTAssertThrowsError(try leader.promote(kid: carol.identity.kid)) { XCTAssertEqual($0 as? TeamClient.ClientError, .alreadyLeader) }

        _ = try carol.fetch()
        XCTAssertTrue(carol.isLeader)
        XCTAssertNoThrow(try carol.code(expiresIn: 60, now: 1_041))
        // From now on a leaders-audience envelope wraps to carol too (§6.5).
        _ = try member.fetch()
        let path = try member.publish(kind: "now", path: "now.json", plaintext: Data("{}".utf8), audience: .leaders, now: 1_050)
        _ = try carol.fetch()
        XCTAssertEqual(try carol.read(path).1, Data("{}".utf8))

        // A co-leader cannot remove the founder; the founder removes the co-leader.
        XCTAssertThrowsError(try carol.remove(kid: leader.identity.kid, now: 1_060)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .founder)
        }
        XCTAssertThrowsError(try leader.remove(kid: "nobody", now: 1_060)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .unknownMember)
        }
        _ = try leader.fetch()
        try leader.remove(kid: carol.identity.kid, now: 1_060)
        let roster = try XCTUnwrap(leader.roster?.doc)
        XCTAssertEqual(roster.rev, 5)
        XCTAssertFalse(roster.isLeader(carol.identity.kid))
        XCTAssertEqual(roster.removed, [TeamRoster.Removed(kid: carol.identity.kid, at: 1_060, keys: carol.identity.keys)])
        // Members are not leaders: no roster edits.
        XCTAssertThrowsError(try member.remove(kid: carol.identity.kid)) { XCTAssertEqual($0 as? TeamClient.ClientError, .notALeader) }
        _ = remote
    }

    /// #55 (a): a removed member's envelopes sealed BEFORE removal stay
    /// readable; those sealed after are ignored, and once the member
    /// fetches the roster it cannot publish at all.
    func testRemovedMembersLaterEnvelopesAreIgnored() throws {
        let (leader, member, _) = try team()
        let before = try member.publish(kind: "stats", path: "days/2026-09-01.json", plaintext: Data("{\"schema\":1}".utf8),
                                        audience: .leaders, now: 1_030)
        _ = try leader.fetch()
        try leader.remove(kid: member.identity.kid, now: 1_040)
        // The member still holds rev 2 and can still push to its branch.
        let after = try member.publish(kind: "stats", path: "days/2026-09-02.json", plaintext: Data("{\"schema\":1}".utf8),
                                       audience: .leaders, now: 1_050)
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path), [before])
        XCTAssertEqual(try leader.read(before).1, Data("{\"schema\":1}".utf8))
        XCTAssertThrowsError(try leader.read(after)) { XCTAssertEqual($0 as? Envelope.EnvelopeError, .unknownSender) }
        _ = try member.fetch()
        XCTAssertFalse(member.isMember)
        XCTAssertThrowsError(try member.publish(kind: "now", path: "now.json", plaintext: Data(), audience: .leaders)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .notInTeam)
        }
    }

    /// #55: the boundary itself. Two envelopes one second apart around
    /// the removal — the earlier one (sealed AT the removal instant)
    /// stays readable, the later one does not.
    func testTheEnvelopeSealedAtTheRemovalInstantIsStillReadable() throws {
        try skipOffPOSIX()
        let (leader, member, _) = try team()
        let at = try member.publish(kind: TeamKinds.stats, path: "days/2026-09-01.json",
                                    plaintext: Data("{\"schema\":1}".utf8), audience: .leaders, now: 1_040)
        let after = try member.publish(kind: TeamKinds.stats, path: "days/2026-09-02.json",
                                       plaintext: Data("{\"schema\":1}".utf8), audience: .leaders, now: 1_041)
        _ = try leader.fetch()
        try leader.remove(kid: member.identity.kid, now: 1_040)
        XCTAssertEqual(try leader.readable().map(\.path), [at])
        XCTAssertEqual(try leader.read(at).1, Data("{\"schema\":1}".utf8))
        XCTAssertThrowsError(try leader.read(after)) { XCTAssertEqual($0 as? Envelope.EnvelopeError, .unknownSender) }
    }

    /// #55 (b): the path is outside the signature, so a valid envelope
    /// replayed under another member's branch, or under a path whose
    /// shape names a different kind, is ignored.
    func testEnvelopesAreCheckedAgainstTheirPath() throws {
        let (leader, member, remote) = try team()
        let (cp, cs) = machine("carol")
        let carol = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_030), name: "Carol", devices: [],
                                           platform: "linux", paths: cp, secrets: cs, now: 1_031)
        _ = try leader.fetch(); try leader.approve(kid: carol.identity.kid, now: 1_032); _ = try carol.fetch()

        let good = try member.publish(kind: "now", path: "now.json", plaintext: Data("{}".utf8), audience: .leaders, now: 1_040)
        // Carol replays Bo's envelope under her branch, and writes a
        // "now" envelope of her own under a days/ path.
        let raw = TeamGit(dir: cp.storeDir(leader.config.id), remote: remote, token: nil, author: carol.identity.kid)
        try raw.open(); try raw.sync()
        let bytes = try XCTUnwrap(try raw.get(good))
        try raw.put("m/\(carol.identity.kid)/now.json", bytes)
        let wrongKind = try Envelope.seal(Data("{}".utf8), kind: "now", from: carol.identity, to: [leader.identity.keys], at: 1_041)
        try raw.put("m/\(carol.identity.kid)/days/2026-09-05.json", wrongKind)
        // The client itself refuses a kind/path mismatch on write.
        XCTAssertThrowsError(try carol.publish(kind: "stats", path: "now.json", plaintext: Data(), audience: .leaders)) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }

        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path), [good])
        XCTAssertThrowsError(try leader.read("m/\(carol.identity.kid)/now.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .senderMismatch)
        }
        XCTAssertThrowsError(try leader.read("m/\(carol.identity.kid)/days/2026-09-05.json")) {
            XCTAssertEqual($0 as? TeamKinds.KindError, .kindMismatch)
        }
    }

    func testBatchedPublishIsOnePushAndUnpublishDeletes() throws {
        let (leader, member, _) = try team()
        let paths = try member.publish([
            TeamClient.PublishItem(kind: "now", path: "now.json", plaintext: Data("n".utf8), audience: .leaders),
            TeamClient.PublishItem(kind: "stats", path: "days/2026-09-05.json", plaintext: Data("d".utf8), audience: .team),
        ], now: 1_030)
        XCTAssertEqual(paths, ["m/\(member.identity.kid)/now.json", "m/\(member.identity.kid)/days/2026-09-05.json"])
        _ = try leader.fetch()
        XCTAssertEqual(Set(try leader.readable().map(\.path)), Set(paths))
        try member.unpublish(path: "now.json")
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readable().map(\.path), [paths[1]])
        XCTAssertEqual(try member.publish([], now: 1_031), [])
    }

    // MARK: plan 5 — founder name, leave

    func testCreateNamesTheFounder() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, leaderName: "Ann", paths: lp, secrets: ls, now: 1_000)
        XCTAssertEqual(leader.roster?.doc.leaders.first?.name, "Ann")
        XCTAssertEqual(leader.roster?.doc.leaders.first?.founder, true)
    }

    func testLeaveDeletesOwnFilesAndLeavesANote() throws {
        let (leader, member, _) = try team()
        try member.publish(kind: TeamKinds.now, path: "now.json",
                           plaintext: try CanonicalJSON.encode(TeamDocs.Now(at: 1, sessions: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: [:])),
                           audience: .leaders, now: 1_030)
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readableHeaders().count, 1)
        try member.leave(now: 1_040)
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readableHeaders().count, 0, "own files are gone")
        XCTAssertNotNil(try leader.store.get("requests/\(member.identity.kid).leave"), "the leaders get a note")
        XCTAssertEqual(try leader.requests().count, 0, ".leave is not a join request")
    }

    func testLeaveSyncsFirstSoAnotherDeviceOfMineIsNotLeftBehind() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (mp, ms) = machine("member")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let member = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Bo", devices: [],
                                            platform: "linux", paths: mp, secrets: ms, now: 1_010)
        _ = try leader.fetch()
        try leader.approve(kid: member.identity.kid, now: 1_020)
        _ = try member.fetch()

        // A second device under the same identity: same config and keys,
        // its own local store dir (so its own remote-tracking refs).
        let (mp2, ms2) = machine("member2")
        try ms2.write(TeamClient.identitySecretName, member.identity.secret)
        try FileManager.default.createDirectory(at: mp2.teamDir(member.config.id), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: mp.configFile(member.config.id), to: mp2.configFile(member.config.id))
        try FileManager.default.copyItem(at: mp.rosterFile(member.config.id), to: mp2.rosterFile(member.config.id))
        let member2 = try TeamClient.open(id: member.config.id, paths: mp2, secrets: ms2)
        try member2.publish(kind: TeamKinds.now, path: "now.json",
                            plaintext: try CanonicalJSON.encode(TeamDocs.Now(at: 1, sessions: [], fleets: [], blockers: [], crashesToday: 0, sharesTo: [:])),
                            audience: .leaders, now: 1_030)

        // `member` (device A) never fetched/synced since device B published.
        try member.leave(now: 1_040)
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readableHeaders().count, 0, "device B's file under the same kid must be gone too")
    }

    /// #55: `team list` used to abort on the first envelope it could not
    /// read. A garbled blob is counted and skipped, and nothing is
    /// decrypted just to list it.
    func testReadableScanSkipsUnreadableBlobsAndCountsThem() throws {
        try skipOffPOSIX()
        let (leader, member, remote) = try team()
        let good = try member.publish(kind: TeamKinds.now, path: "now.json", plaintext: Data("{}".utf8),
                                      audience: .leaders, now: 1_030)
        // Anyone holding the store credential can write nonsense under a
        // member's branch; here it is a second member's own path.
        let raw = TeamGit(dir: scratch.appendingPathComponent("vandal"), remote: remote, token: nil, author: "v")
        try raw.open()
        try raw.put("m/\(member.identity.kid)/crashes.json", Data("not an envelope".utf8))

        _ = try leader.fetch()
        let scan = try leader.readableScan()
        XCTAssertEqual(scan.headers.map(\.entry.path), [good])
        XCTAssertEqual(scan.skipped, 1)
        XCTAssertEqual(try leader.readableHeaders().map(\.entry.path), [good], "the old entry point is unchanged")
    }

    /// #55: `--team <id>` is interpolated into `<base>/<id>/config.json`.
    func testPathSegmentsAreOneSegment() {
        XCTAssertTrue(TeamClient.isPathSegment("6f0d4c2e-0000-4000-8000-000000000000"))
        XCTAssertFalse(TeamClient.isPathSegment(""))
        XCTAssertFalse(TeamClient.isPathSegment("."))
        XCTAssertFalse(TeamClient.isPathSegment(".."))
        XCTAssertFalse(TeamClient.isPathSegment("../other"))
        XCTAssertFalse(TeamClient.isPathSegment("a/b"))
        XCTAssertFalse(TeamClient.isPathSegment("a\\b"))
    }

    /// Spec §6.5: "Member key rotation is offered so even the member
    /// can't reopen old envelopes."
    func testLeaveCanRotateThisMachinesIdentity() throws {
        try skipOffPOSIX()
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (mp, ms) = machine("member")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let member = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Bo", devices: [],
                                            platform: "linux", paths: mp, secrets: ms, now: 1_010)
        _ = try leader.fetch(); try leader.approve(kid: member.identity.kid, now: 1_020); _ = try member.fetch()
        let old = member.identity
        // An envelope this Mac could open before it left.
        let sealed = try Envelope.seal(Data("secret".utf8), kind: TeamKinds.now, from: leader.identity,
                                       to: [old.keys], at: 1_030)

        try member.leave(rotateIdentity: true, now: 1_040)

        let fresh = try TeamClient.identity(paths: mp, secrets: ms)
        XCTAssertNotEqual(fresh.kid, old.kid, "a fresh identity was minted")
        XCTAssertNotEqual(ms.read(TeamClient.identitySecretName), old.secret, "the old secret is gone, not kept alongside")
        XCTAssertThrowsError(try Envelope.open(sealed, as: fresh, senderKey: { _ in leader.identity.keys })) {
            XCTAssertEqual($0 as? Envelope.EnvelopeError, .notARecipient)
        }
        // The leave itself still happened.
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readableHeaders().count, 0)
        XCTAssertNotNil(try leader.store.get("requests/\(old.kid).leave"))
    }

    /// The identity is this MACHINE's, not this team's: rotating it while
    /// another team on the same Mac knows the old kid would silently
    /// unmake that membership.
    func testRotationIsRefusedWhileAnotherTeamOnThisMacKnowsTheKid() throws {
        try skipOffPOSIX()
        let remote = try makeRemote()
        let (lp, ls) = machine("leader"), (mp, ms) = machine("member")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let member = try TeamClient.request(code: try leader.code(expiresIn: 600, now: 1_000), name: "Bo", devices: [],
                                            platform: "linux", paths: mp, secrets: ms, now: 1_010)
        _ = try leader.fetch(); try leader.approve(kid: member.identity.kid, now: 1_020); _ = try member.fetch()
        try member.publish(kind: TeamKinds.now, path: "now.json", plaintext: Data("{}".utf8),
                           audience: .leaders, now: 1_025)
        // A second team on the same machine, same identity.
        _ = try TeamClient.create(name: "Other", remote: try makeRemote("other.git"), token: nil,
                                  paths: mp, secrets: ms, now: 1_030)

        XCTAssertThrowsError(try member.leave(rotateIdentity: true, now: 1_040)) {
            XCTAssertEqual($0 as? TeamClient.ClientError, .identityInUse)
        }
        XCTAssertEqual(ms.read(TeamClient.identitySecretName), member.identity.secret, "nothing rotated")
        _ = try leader.fetch()
        XCTAssertEqual(try leader.readableHeaders().count, 1, "the guard ran before anything was pushed: the file is still there")
        // Leaving without rotation is unaffected.
        XCTAssertNoThrow(try member.leave(now: 1_041))
    }
}
