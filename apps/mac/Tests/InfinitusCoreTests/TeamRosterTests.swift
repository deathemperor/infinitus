import XCTest
@testable import InfinitusCore

final class TeamRosterTests: XCTestCase {
    let leader = TeamIdentity.random()
    let member = TeamIdentity.random()
    let stranger = TeamIdentity.random()

    func roster(rev: Int, leaders: [TeamIdentity], members: [TeamIdentity] = []) -> TeamRoster {
        TeamRoster(id: "team-1", name: "Papaya", createdAt: 100,
                   leaders: leaders.map { TeamRoster.Member(keys: $0.keys, name: "L", since: 100, founder: $0.kid == leader.kid) },
                   members: members.map { TeamRoster.Member(keys: $0.keys, name: "M", since: 200) },
                   rev: rev)
    }

    func testSignedDocumentsVerifyOnlyWithTheSignersKey() throws {
        let doc = try Signed.make(TeamRequest(keys: member.keys, name: "Bo", devices: ["Mac"], platform: "macos", at: 5),
                                  by: member)
        XCTAssertEqual(doc.by, member.kid)
        XCTAssertNoThrow(try doc.verify(with: member.keys))
        XCTAssertThrowsError(try doc.verify(with: stranger.keys))
        var forged = doc
        forged.doc.name = "Bob"
        XCTAssertThrowsError(try forged.verify(with: member.keys))
        // Round trip through JSON keeps the signature valid (canonical encoding).
        let again = try CanonicalJSON.decode(Signed<TeamRequest>.self, from: try CanonicalJSON.encode(doc))
        XCTAssertNoThrow(try again.verify(with: member.keys))
    }

    func testRosterAcceptanceRules() throws {
        let first = try Signed.make(roster(rev: 1, leaders: [leader]), by: leader)
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(first, previous: nil))
        // A first roster signed by someone not listed as a leader.
        let bogus = try Signed.make(roster(rev: 1, leaders: [leader]), by: stranger)
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(bogus, previous: nil))
        // rev must grow.
        let same = try Signed.make(roster(rev: 1, leaders: [leader], members: [member]), by: leader)
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(same, previous: first)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .lowerRev)
        }
        // A member can't sign the next roster.
        let coup = try Signed.make(roster(rev: 2, leaders: [member]), by: member)
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(coup, previous: first)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .notALeader)
        }
        // The leader promoting a member is fine; then the new leader may sign.
        let promoted = try Signed.make(roster(rev: 2, leaders: [leader, member]), by: leader)
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(promoted, previous: first))
        let byNewLeader = try Signed.make(roster(rev: 3, leaders: [leader, member]), by: member)
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(byNewLeader, previous: promoted))
        // Different team id.
        var other = roster(rev: 2, leaders: [leader]); other.id = "team-2"
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(try Signed.make(other, by: leader), previous: first)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .differentTeam)
        }
        // No leaders at all.
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(try Signed.make(roster(rev: 2, leaders: []), by: leader), previous: first)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .noLeaders)
        }
    }

    func testRecipientsFollowTheShareTarget() throws {
        let r = roster(rev: 1, leaders: [leader], members: [member, stranger])
        XCTAssertEqual(r.recipients(for: .leaders).map(\.kid), [leader.kid])
        XCTAssertEqual(Set(r.recipients(for: .team).map(\.kid)), [leader.kid, member.kid, stranger.kid])
        XCTAssertEqual(r.recipients(for: .members([stranger.kid, "nobody"])).map(\.kid), [stranger.kid])   // #55 (d): leaders only when named
        XCTAssertTrue(r.isLeader(leader.kid)); XCTAssertFalse(r.isLeader(member.kid))
        XCTAssertEqual(r.keys(for: member.kid), member.keys)
        // ShareTarget JSON shapes.
        XCTAssertEqual(String(decoding: try CanonicalJSON.encode(TeamRoster.ShareTarget.leaders), as: UTF8.self), "\"leaders\"")
        XCTAssertEqual(String(decoding: try CanonicalJSON.encode(TeamRoster.ShareTarget.members(["a"])), as: UTF8.self), "[\"a\"]")
        XCTAssertEqual(try CanonicalJSON.decode(TeamRoster.ShareTarget.self, from: Data("\"team\"".utf8)), .team)
        XCTAssertEqual(try CanonicalJSON.decode(TeamRoster.ShareTarget.self, from: Data("[\"a\",\"b\"]".utf8)), .members(["a", "b"]))
    }

    func testGarbledSignerKeysReadAsABadSignature() throws {
        let signed = try Signed.make(roster(rev: 1, leaders: [leader], members: []), by: leader)
        let garbled = TeamKeys(kid: leader.kid, enc: leader.keys.enc, sig: "not base64!")
        XCTAssertThrowsError(try signed.verify(with: garbled)) {
            XCTAssertEqual($0 as? Signed<TeamRoster>.SignedError, .badSignature)
        }
        XCTAssertNoThrow(try signed.verify(with: leader.keys))
    }

    func testTeamCodeRoundTripExpiryAndSignature() throws {
        let code = TeamCode(team: "team-1", name: "Papaya", remote: "file:///tmp/x.git", token: "tok",
                            leader: leader.keys, expires: 2_000)
        let text = try code.encoded(by: leader)
        XCTAssertTrue(text.hasPrefix(TeamCode.prefix))
        XCTAssertFalse(text.contains("+")); XCTAssertFalse(text.contains("/tmp"))   // base64url, opaque
        XCTAssertEqual(try TeamCode.decode(text, now: 1_000), code)
        XCTAssertEqual(try TeamCode.decode(String(text.dropFirst(TeamCode.prefix.count)), now: 1_000), code)
        XCTAssertThrowsError(try TeamCode.decode(text, now: 3_000)) { XCTAssertEqual($0 as? TeamCode.CodeError, .expired) }
        XCTAssertThrowsError(try TeamCode.decode("infinitus://join/nope", now: 1_000))
        // A code whose signature doesn't match the leader key it carries.
        var forged = code; forged.leader = stranger.keys
        let forgedText = try forged.encoded(by: leader)
        XCTAssertThrowsError(try TeamCode.decode(forgedText, now: 1_000)) { XCTAssertEqual($0 as? TeamCode.CodeError, .badSignature) }
    }

    func testFirstRosterMustBeSignedByTheLeaderTheCodeNamed() throws {
        // A code holder writes a rev-1 roster that lists itself next to the
        // real leader and signs it (C1).
        let forged = try Signed.make(roster(rev: 1, leaders: [leader, stranger]), by: stranger)
        // With no trust root the old rule still holds: a listed leader signed it.
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(forged, previous: nil))
        // The code named the real leader, so only that leader's signature counts.
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(forged, previous: nil, trustRoot: leader.kid)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .notALeader)
        }
        // The same roster signed by the code's leader is fine.
        let honest = try Signed.make(roster(rev: 1, leaders: [leader, stranger]), by: leader)
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(honest, previous: nil, trustRoot: leader.kid))
        // A forger is accepted only by a joiner whose code named the forger.
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(forged, previous: nil, trustRoot: stranger.kid))
        // The trust root must still be a leader of the roster it signed.
        XCTAssertThrowsError(try TeamRoster.Acceptance.check(honest, previous: nil, trustRoot: member.kid)) {
            XCTAssertEqual($0 as? TeamRoster.RosterError, .notALeader)
        }
        // A later roster is judged by the previous one, not the trust root.
        let next = try Signed.make(roster(rev: 2, leaders: [leader, stranger]), by: stranger)
        XCTAssertNoThrow(try TeamRoster.Acceptance.check(next, previous: honest, trustRoot: leader.kid))
    }

    func testTeamKeysDecodingBindsTheKidToTheEncryptionKey() throws {
        // C2: kid, enc and sig used to be three independent strings, so a
        // store writer could put anyone's kid on their own keys.
        let good = try CanonicalJSON.encode(member.keys)
        XCTAssertEqual(try CanonicalJSON.decode(TeamKeys.self, from: good), member.keys)
        let forged = try CanonicalJSON.encode(TeamKeys(kid: leader.kid, enc: stranger.keys.enc, sig: stranger.keys.sig))
        XCTAssertThrowsError(try CanonicalJSON.decode(TeamKeys.self, from: forged))
        // enc that isn't base64 at all.
        XCTAssertThrowsError(try CanonicalJSON.decode(TeamKeys.self, from: Data(#"{"enc":"!!!","kid":"x","sig":"y"}"#.utf8)))
    }
}
