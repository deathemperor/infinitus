import XCTest
@testable import InfinitusCore

final class TeamIdentityTests: XCTestCase {
    func testBase32MatchesRFC4648Vectors() {
        XCTAssertEqual(Base32.encode(Data()), "")
        XCTAssertEqual(Base32.encode(Data("f".utf8)), "my")
        XCTAssertEqual(Base32.encode(Data("fo".utf8)), "mzxq")
        XCTAssertEqual(Base32.encode(Data("foo".utf8)), "mzxw6")
        XCTAssertEqual(Base32.encode(Data("foobar".utf8)), "mzxw6ytboi")
    }

    func testCanonicalJSONIsSortedAndStable() throws {
        struct Doc: Codable { var b: Int; var a: String; var path: String }
        let data = try CanonicalJSON.encode(Doc(b: 2, a: "x", path: "m/k/1"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":"x","b":2,"path":"m/k/1"}"#)
        XCTAssertEqual(try CanonicalJSON.decode(Doc.self, from: data).path, "m/k/1")
    }

    func testIdentityIsDeterministicFromTheSecret() throws {
        let secret = Data((0..<32).map { UInt8($0) })
        let a = try TeamIdentity(secret: secret)
        let b = try TeamIdentity(secret: secret)
        XCTAssertEqual(a.keys, b.keys)
        XCTAssertEqual(a.kid.count, 26)
        XCTAssertTrue(a.kid.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        XCTAssertEqual(a.kid, TeamKeys.kid(forEncryptionKey: a.encryption.publicKey.rawRepresentation,
                                           signingKey: a.signing.publicKey.rawRepresentation))
        XCTAssertNotEqual(a.keys, TeamIdentity.random().keys)
        XCTAssertThrowsError(try TeamIdentity(secret: Data([1, 2, 3])))
    }

    func testSignaturesVerifyWithThePublishedKey() throws {
        let id = TeamIdentity.random()
        let msg = Data("hello".utf8)
        let sig = try id.sign(msg)
        XCTAssertTrue(try id.keys.signingKey().isValidSignature(sig, for: msg))
        XCTAssertFalse(try id.keys.signingKey().isValidSignature(sig, for: Data("hellp".utf8)))
        XCTAssertEqual(try id.keys.encryptionKey().rawRepresentation, id.encryption.publicKey.rawRepresentation)
    }

    /// Spec §11: identity derivation vectors (fixed secret → fixed kids)
    /// and the exact canonical-JSON bytes of a signed roster. Pinned on
    /// macOS; Linux CI is what proves the two Foundation/crypto stacks
    /// agree, which is what lets a signature travel between them.
    func testPinnedDerivationAndSignedRosterBytes() throws {
        let signer = try TeamIdentity(secret: Data((0..<32).map { UInt8($0) }))
        XCTAssertEqual(signer.keys.kid, "r2fp4grnvjgu5bvfmlnb6gp4fa")
        XCTAssertEqual(signer.keys.enc, "VSh04Y1J5bmVnKpmZpFFCXeCgXKi7vLdhANqP91rD1Q=")
        XCTAssertEqual(signer.keys.sig, "z99uY2cGfaoiVpCEuFuCMknko3pCpdqwVGKT1tIH4TY=")

        let other = try TeamIdentity(secret: Data(repeating: 1, count: 32))
        XCTAssertEqual(other.keys.kid, "dbkl6x62alzbgd6uaxu4por4a4")
        let roster = TeamRoster(id: "team-fixture", name: "P\u{e2}paya \u{1F348}", createdAt: 1_700_000_000,
                                leaders: [TeamRoster.Member(keys: signer.keys, name: "Loc",
                                                            since: 1_700_000_000, founder: true)],
                                members: [TeamRoster.Member(keys: other.keys, name: "Bo", since: 1_700_000_100,
                                                            devices: ["Mac"],
                                                            sharesTo: ["stats": .team,
                                                                       "transcripts": .members(["k1"])])],
                                rev: 7)
        // The bytes every signature is computed over.
        XCTAssertEqual(String(decoding: try CanonicalJSON.encode(roster), as: UTF8.self), #"{"createdAt":1700000000,"id":"team-fixture","leaders":[{"devices":[],"founder":true,"keys":{"enc":"VSh04Y1J5bmVnKpmZpFFCXeCgXKi7vLdhANqP91rD1Q=","kid":"r2fp4grnvjgu5bvfmlnb6gp4fa","sig":"z99uY2cGfaoiVpCEuFuCMknko3pCpdqwVGKT1tIH4TY="},"name":"Loc","sharesTo":{},"since":1700000000}],"members":[{"devices":["Mac"],"founder":false,"keys":{"enc":"9CVWEHrQ5Bio0O1NmD8r+CUV/VoVpVu32YhmWcu7QVA=","kid":"dbkl6x62alzbgd6uaxu4por4a4","sig":"a/dzIb+R5fSo4Nqf4BYis9T6ntm5bpCt+VsOsqdB6iY="},"name":"Bo","sharesTo":{"stats":"team","transcripts":["k1"]},"since":1700000100}],"name":"Pâpaya 🍈","policy":{"membersSeeEachOther":false,"requests":"code"},"removed":[],"rev":7,"schema":1}"#)

        // One whole Signed<TeamRoster>, recorded from this identity: it must
        // decode, re-encode to the same bytes and verify. CryptoKit adds
        // randomness to Ed25519, so a fresh signature over the same document
        // differs every time and cannot itself be pinned.
        let pinned = #"{"by":"r2fp4grnvjgu5bvfmlnb6gp4fa","doc":{"createdAt":1700000000,"id":"team-fixture","leaders":[{"devices":[],"founder":true,"keys":{"enc":"VSh04Y1J5bmVnKpmZpFFCXeCgXKi7vLdhANqP91rD1Q=","kid":"r2fp4grnvjgu5bvfmlnb6gp4fa","sig":"z99uY2cGfaoiVpCEuFuCMknko3pCpdqwVGKT1tIH4TY="},"name":"Loc","sharesTo":{},"since":1700000000}],"members":[{"devices":["Mac"],"founder":false,"keys":{"enc":"9CVWEHrQ5Bio0O1NmD8r+CUV/VoVpVu32YhmWcu7QVA=","kid":"dbkl6x62alzbgd6uaxu4por4a4","sig":"a/dzIb+R5fSo4Nqf4BYis9T6ntm5bpCt+VsOsqdB6iY="},"name":"Bo","sharesTo":{"stats":"team","transcripts":["k1"]},"since":1700000100}],"name":"Pâpaya 🍈","policy":{"membersSeeEachOther":false,"requests":"code"},"removed":[],"rev":7,"schema":1},"sig":"ZRaqLWUDWESjp6BDCb56C28VEpEzr5F2YYLMXrxGNbG96I7KcEmeGr5zdVvjpIiS4WyOLQsSzQQ69HfHRIQ8AA=="}"#
        let signed = try CanonicalJSON.decode(Signed<TeamRoster>.self, from: Data(pinned.utf8))
        XCTAssertEqual(signed.doc, roster)
        XCTAssertEqual(String(decoding: try CanonicalJSON.encode(signed), as: UTF8.self), pinned)
        XCTAssertNoThrow(try signed.verify(with: signer.keys))
        // And a signature made now over the same document verifies too.
        XCTAssertNoThrow(try Signed.make(roster, by: signer).verify(with: signer.keys))
    }

    /// #57: a request that pairs a victim's encryption key (and its kid)
    /// with the attacker's signing key must not decode — the kid binds both.
    func testKidBindsTheSigningKeyToo() throws {
        let victim = try TeamIdentity(secret: Data((0..<32).map { UInt8($0) }))
        let attacker = try TeamIdentity(secret: Data(repeating: 1, count: 32))
        let forged = TeamKeys(kid: victim.keys.kid, enc: victim.keys.enc, sig: attacker.keys.sig)
        let bytes = try CanonicalJSON.encode(forged)
        XCTAssertThrowsError(try CanonicalJSON.decode(TeamKeys.self, from: bytes)) {
            XCTAssertEqual($0 as? TeamKeys.KeyError, .badKey)
        }
        XCTAssertNoThrow(try CanonicalJSON.decode(TeamKeys.self, from: try CanonicalJSON.encode(victim.keys)))
    }
}
