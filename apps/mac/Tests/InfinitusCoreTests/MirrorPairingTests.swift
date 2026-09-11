import XCTest
@testable import InfinitusCore

/// The backend-free remote access rules (#9): the pairing token, what a
/// QR encodes, which of this machine's addresses is worth offering, and
/// how cloudflared announces a quick tunnel.
final class MirrorPairingTests: XCTestCase {
    func testGeneratedTokenIsBase32AndUnrepeated() {
        let token = MirrorPairing.generateToken()
        XCTAssertEqual(token.count, MirrorPairing.tokenLength)
        XCTAssertTrue(token.allSatisfy(Set(MirrorPairing.alphabet).contains))
        // 32^24 of entropy: a collision in ten draws would mean the RNG
        // isn't one.
        XCTAssertEqual(Set((0..<10).map { _ in MirrorPairing.generateToken() }).count, 10)
    }

    func testNormalizeSurvivesHumanTyping() {
        XCTAssertEqual(MirrorPairing.normalize(" abcd-2345\n"), "ABCD2345")
        // 0/1/8/9 aren't in the alphabet at all, so they can't be a token.
        XCTAssertEqual(MirrorPairing.normalize("A0B1C8"), "ABC")
        XCTAssertEqual(MirrorPairing.normalize(""), "")
    }

    func testMatchesComparesWholeToken() {
        XCTAssertTrue(MirrorPairing.matches("ABCDEF", "ABCDEF"))
        XCTAssertFalse(MirrorPairing.matches("ABCDEF", "ABCDEG"))
        XCTAssertFalse(MirrorPairing.matches("ABCDE", "ABCDEF"))
        XCTAssertFalse(MirrorPairing.matches("", "ABCDEF"))
    }

    func testMaskShowsTheEnds() {
        XCTAssertEqual(MirrorPairing.mask("ABCD234567WXYZ"), "ABCD••••••WXYZ")
        XCTAssertEqual(MirrorPairing.mask("ABCD"), "••••")
    }

    func testPairURLRoundTrips() {
        let url = MirrorPairing.pairURL(endpoint: "http://192.168.1.20:47824",
                                        token: "abcd2345")
        XCTAssertTrue(url.hasPrefix("infinitus://pair?url="))
        // The endpoint's own colons and slashes are escaped, so they
        // can't be read as another query parameter.
        XCTAssertFalse(url.contains("http://192.168.1.20:47824"))
        let pairing = MirrorPairing.parsePairURL(url)
        XCTAssertEqual(pairing?.endpoints, ["http://192.168.1.20:47824"])
        XCTAssertEqual(pairing?.endpoint, "http://192.168.1.20:47824")
        XCTAssertEqual(pairing?.token, "ABCD2345")
    }

    /// One QR, every route (#9 pair once, every route) — repeated `url=`
    /// in order, so a tunnel that changes on restart just falls through
    /// to the next one instead of forcing a rescan.
    func testPairURLCarriesEveryRouteInOrder() {
        let url = MirrorPairing.pairURL(
            endpoints: ["http://192.168.1.20:47824", "http://100.90.1.2:47824",
                        "https://calm-fox.trycloudflare.com"],
            token: "abcd2345")
        XCTAssertEqual(url.components(separatedBy: "url=").count - 1, 3)
        let pairing = MirrorPairing.parsePairURL(url)
        XCTAssertEqual(pairing?.endpoints, [
            "http://192.168.1.20:47824", "http://100.90.1.2:47824",
            "https://calm-fox.trycloudflare.com",
        ])
        XCTAssertEqual(pairing?.token, "ABCD2345")
    }

    /// Duplicate `url=` values collapse to one, keeping the first
    /// occurrence's position.
    func testPairURLDeduplicatesEndpoints() {
        let pairing = MirrorPairing.parsePairURL(
            "infinitus://pair?url=http://a&url=http://b&url=http://a&token=AB")
        XCTAssertEqual(pairing?.endpoints, ["http://a", "http://b"])
    }

    func testParsePairURLRejectsAnythingElse() {
        XCTAssertNil(MirrorPairing.parsePairURL("https://evil.example/pair?token=AB"))
        XCTAssertNil(MirrorPairing.parsePairURL("infinitus://other?token=AB"))
        // No token, no pairing.
        XCTAssertNil(MirrorPairing.parsePairURL("infinitus://pair?url=http://x"))
        // A token with no endpoint at all is useless too — a pairing
        // needs at least one route to try.
        XCTAssertNil(MirrorPairing.parsePairURL("infinitus://pair?token=AB"))
        // A tunnel QR carries an https endpoint and no port.
        let tunnel = MirrorPairing.parsePairURL(
            MirrorPairing.pairURL(endpoint: "https://calm-fox.trycloudflare.com",
                                  token: "ZZZZ7777"))
        XCTAssertEqual(tunnel?.endpoint, "https://calm-fox.trycloudflare.com")
    }

    func testTailnetAddressIsTheCGNATOne() {
        let addresses = ["192.168.1.20", "100.101.102.103", "169.254.9.9"]
        XCTAssertEqual(MirrorPairing.tailnetAddress(in: addresses), "100.101.102.103")
        // 100.128.x is public space, not Tailscale's 100.64.0.0/10.
        XCTAssertNil(MirrorPairing.tailnetAddress(in: ["100.128.0.1", "100.63.0.1"]))
        XCTAssertNil(MirrorPairing.tailnetAddress(in: []))
    }

    func testLanAddressSkipsLoopbackLinkLocalAndTailnet() {
        XCTAssertEqual(MirrorPairing.lanAddress(
            in: ["127.0.0.1", "169.254.1.1", "100.90.1.2", "192.168.2.36"]),
                       "192.168.2.36")
        XCTAssertNil(MirrorPairing.lanAddress(in: ["100.90.1.2", "fe80::1"]))
    }

    // MARK: - Several Macs per phone (#144 phase 1)

    func testReplacesPrimaryWhenNoneYet() {
        XCTAssertTrue(MirrorPairing.Others.replacesPrimary(
            scannedToken: "ABCD2345", primaryToken: "", primaryEndpoints: []))
    }

    func testReplacesPrimaryWhenTokenMatches() {
        XCTAssertTrue(MirrorPairing.Others.replacesPrimary(
            scannedToken: "abcd-2345", primaryToken: "ABCD2345", primaryEndpoints: ["http://a"]))
    }

    func testReplacesPrimaryWithoutTokenOrOnSharedEndpoint() {
        // Endpoints typed by hand but no token yet: the scan completes the pairing.
        XCTAssertTrue(MirrorPairing.Others.replacesPrimary(
            scannedToken: "ABCD2345", primaryToken: "", primaryEndpoints: ["http://a"]))
        // The primary Mac regenerated its token: same endpoint, new token — still the primary.
        XCTAssertTrue(MirrorPairing.Others.replacesPrimary(
            scannedToken: "WXYZ7777", primaryToken: "ABCD2345", primaryEndpoints: ["http://a", "http://b"],
            scannedEndpoints: ["http://b"]))
    }

    func testDoesNotReplacePrimaryForAnotherMac() {
        XCTAssertFalse(MirrorPairing.Others.replacesPrimary(
            scannedToken: "WXYZ7777", primaryToken: "ABCD2345", primaryEndpoints: ["http://a"]))
    }

    func testUpsertAddsThenReplacesByNormalizedToken() {
        let first = MirrorPairing.MacPairing(id: "ABCD2345", name: "Study", endpoints: ["http://a"], token: "ABCD2345")
        var list = MirrorPairing.Others.upsert(first, into: [])
        XCTAssertEqual(list.map(\.id), ["ABCD2345"])
        let updated = MirrorPairing.MacPairing(id: "ABCD2345", name: "Study", endpoints: ["http://b"], token: "ABCD2345")
        list = MirrorPairing.Others.upsert(updated, into: list)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.endpoints, ["http://b"])
    }

    func testSwapPrimaryMovesFieldsBothWays() {
        let oldPrimary = MirrorPairing.Pairing(endpoints: ["http://study"], token: "OLDTOKEN")
        let chosen = MirrorPairing.MacPairing(id: "NEWTOKEN", name: "Garage", endpoints: ["http://garage"], token: "NEWTOKEN")
        let others = [chosen, MirrorPairing.MacPairing(id: "OTHER", name: "Bedroom", endpoints: ["http://bedroom"], token: "OTHER")]
        let result = MirrorPairing.Others.swapPrimary(
            oldPrimary: oldPrimary, oldPrimaryName: "Study", chosen: chosen, others: others)
        XCTAssertEqual(result.primary.endpoints, ["http://garage"])
        XCTAssertEqual(result.primary.token, "NEWTOKEN")
        XCTAssertEqual(result.others.map(\.id).sorted(), ["OLDTOKEN", "OTHER"])
        let demoted = result.others.first { $0.id == "OLDTOKEN" }
        XCTAssertEqual(demoted?.name, "Study")
        XCTAssertEqual(demoted?.endpoints, ["http://study"])
    }

    func testQuickTunnelURLOutOfCloudflaredNoise() {
        let line = "2026-09-02T10:00:00Z INF |  https://calm-fox-1234.trycloudflare.com  |"
        XCTAssertEqual(MirrorPairing.quickTunnelURL(in: line),
                       "https://calm-fox-1234.trycloudflare.com")
        // cloudflared logs plenty of other https URLs (docs, metrics).
        XCTAssertNil(MirrorPairing.quickTunnelURL(
            in: "INF see https://developers.cloudflare.com/argo-tunnel"))
        XCTAssertNil(MirrorPairing.quickTunnelURL(in: "INF starting tunnel"))
    }
}
