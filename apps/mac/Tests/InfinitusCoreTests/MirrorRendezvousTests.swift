import XCTest
@testable import InfinitusCore

final class MirrorRendezvousTests: XCTestCase {
    func testKeyIsSHA256HexOfTheNormalizedToken() {
        // Tokens normalize to the upper-case alphabet: echo -n ABC | shasum -a 256
        XCTAssertEqual(MirrorRendezvous.key(token: "abc"),
                       "b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78")
        XCTAssertEqual(MirrorRendezvous.key(token: " abc\n"), MirrorRendezvous.key(token: "abc"))
        XCTAssertNil(MirrorRendezvous.key(token: "  "))
    }

    func testSHA256KnownVectors() {
        // FIPS 180-4 examples, plus the two-block boundary.
        XCTAssertEqual(SHA256.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Array("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex(Array(String(repeating: "a", count: 1_000).utf8)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testURLUsesTheDefaultBase() {
        XCTAssertEqual(MirrorRendezvous.url(token: "abc")?.absoluteString,
                       "https://infinitus.run/rendezvous/b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78")
    }

    func testOnlyQuickTunnelURLsAreEphemeral() {
        XCTAssertTrue(MirrorRendezvous.isEphemeral("https://abc-def.trycloudflare.com"))
        XCTAssertFalse(MirrorRendezvous.isEphemeral("https://tunnel.infinitus.run"))
        XCTAssertFalse(MirrorRendezvous.isEphemeral("192.168.2.36:47824"))
    }

    func testLookupParsesOnlyQuickTunnelURLs() {
        XCTAssertEqual(MirrorRendezvous.parseLookup(Data(#"{"url":"https://x.trycloudflare.com"}"#.utf8)),
                       "https://x.trycloudflare.com")
        XCTAssertNil(MirrorRendezvous.parseLookup(Data(#"{"url":"https://evil.example"}"#.utf8)))
        XCTAssertNil(MirrorRendezvous.parseLookup(Data("nope".utf8)))
    }

    func testPublishBody() {
        XCTAssertEqual(String(decoding: MirrorRendezvous.publishBody(url: "https://x.trycloudflare.com"), as: UTF8.self),
                       #"{"url":"https:\/\/x.trycloudflare.com"}"#)
    }
}
