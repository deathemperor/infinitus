import XCTest
@testable import InfinitusCore

final class TeamEnvelopeTests: XCTestCase {
    let alice = TeamIdentity.random()
    let bob = TeamIdentity.random()
    let eve = TeamIdentity.random()

    func lookup(_ kid: String) -> TeamKeys? {
        [alice, bob, eve].first { $0.kid == kid }?.keys
    }

    func testSealedFileOpensForEveryRecipientAndNobodyElse() throws {
        let plain = Data("{\"schema\":1,\"n\":42}".utf8)
        let file = try Envelope.seal(plain, kind: "stats", from: alice, to: [bob.keys], at: 1_800_000_000)
        let header = try Envelope.header(of: file)
        XCTAssertEqual(header.v, 1)
        XCTAssertEqual(header.kind, "stats")
        XCTAssertEqual(header.from, alice.kid)
        XCTAssertEqual(Set(header.to.map(\.kid)), [alice.kid, bob.kid])   // sender is always a recipient
        XCTAssertEqual(header.at, 1_800_000_000)
        XCTAssertNotNil(header.sig)

        let (h1, p1) = try Envelope.open(file, as: bob, senderKey: lookup)
        XCTAssertEqual(p1, plain)
        XCTAssertEqual(h1, header)
        XCTAssertEqual(try Envelope.open(file, as: alice, senderKey: lookup).1, plain)
        XCTAssertThrowsError(try Envelope.open(file, as: eve, senderKey: lookup)) {
            XCTAssertEqual($0 as? Envelope.EnvelopeError, .notARecipient)
        }
    }

    func testAnotherVersionIsRefusedBeforeAnythingElse() throws {
        let file = try Envelope.seal(Data("x".utf8), kind: "now", from: alice, to: [bob.keys])
        let text = String(decoding: file, as: UTF8.self)
        let bumped = Data(text.replacingOccurrences(of: "\"v\":1", with: "\"v\":2").utf8)
        XCTAssertNotEqual(bumped, file)
        XCTAssertThrowsError(try Envelope.open(bumped, as: bob, senderKey: lookup)) {
            XCTAssertEqual($0 as? Envelope.EnvelopeError, .badVersion)
        }
    }

    func testTamperingAndUnknownSendersAreRejected() throws {
        let file = try Envelope.seal(Data("x".utf8), kind: "now", from: alice, to: [bob.keys])
        // Flip a ciphertext byte.
        var bent = file
        bent[bent.count - 1] ^= 0x01
        XCTAssertThrowsError(try Envelope.open(bent, as: bob, senderKey: lookup))
        // Flip a header byte (the kind).
        var text = String(decoding: file, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"kind\":\"now\"", with: "\"kind\":\"nox\"")
        XCTAssertThrowsError(try Envelope.open(Data(text.utf8), as: bob, senderKey: lookup))
        // Sender not in the roster.
        XCTAssertThrowsError(try Envelope.open(file, as: bob, senderKey: { _ in nil })) {
            XCTAssertEqual($0 as? Envelope.EnvelopeError, .unknownSender)
        }
        // Sender's key swapped for another → signature fails.
        XCTAssertThrowsError(try Envelope.open(file, as: bob, senderKey: { _ in self.eve.keys })) {
            XCTAssertEqual($0 as? Envelope.EnvelopeError, .badSignature)
        }
        XCTAssertThrowsError(try Envelope.header(of: Data("not json\n".utf8)))
    }

    func testEachEnvelopeUsesFreshKeyMaterial() throws {
        let a = try Envelope.seal(Data("same".utf8), kind: "k", from: alice, to: [], at: 1)
        let b = try Envelope.seal(Data("same".utf8), kind: "k", from: alice, to: [], at: 1)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(try Envelope.header(of: a).eph, try Envelope.header(of: b).eph)
    }
}
