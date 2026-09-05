import XCTest
@testable import InfinitusWinUI
@testable import InfinitusCore

final class PairingChecklistTests: XCTestCase {
    func testWalkthroughStepsFromState() {
        let routes = [
            PairingChecklist.RouteItem(id: "lan", title: "Wi-Fi (LAN)", endpoint: "http://192.168.1.10:47824")
        ]

        // 1. Stopped, nothing served, no routes
        let s1 = PairingChecklist.steps(serving: false, port: 47824, lastServed: nil, routes: [])
        XCTAssertEqual(s1.map(\.done), [false, false, false, false])

        // 2. Serving, but no routes and never served
        let s2 = PairingChecklist.steps(serving: true, port: 47824, lastServed: nil, routes: [])
        XCTAssertEqual(s2.map(\.done), [true, false, false, false])

        // 3. Serving, with routes, but never served
        let s3 = PairingChecklist.steps(serving: true, port: 47824, lastServed: nil, routes: routes)
        XCTAssertEqual(s3.map(\.done), [true, false, true, false])

        // 4. Serving, with routes, phone connected (lastServed set)
        let s4 = PairingChecklist.steps(serving: true, port: 47824, lastServed: Date(), routes: routes)
        XCTAssertEqual(s4.map(\.done), [true, true, true, true])
    }

    func testAgentBriefOmitsTokenWhenMasked() {
        let steps = PairingChecklist.steps(serving: true, port: 47824, lastServed: nil, routes: [])
        let brief = PairingChecklist.agentBrief(
            steps: steps,
            serving: true,
            port: 47824,
            routes: [],
            token: "SECRETTOKEN1234567890AB",
            revealToken: false,
            tailscaleAddress: nil,
            machineName: "TestBox"
        )

        XCTAssertTrue(brief.contains("<hidden — in Infinitus: Settings → Devices → Pairing token → Reveal/Copy>"))
        XCTAssertFalse(brief.contains("SECRETTOKEN1234567890AB"))
    }

    func testAgentBriefIncludesTokenWhenRevealed() {
        let steps = PairingChecklist.steps(serving: true, port: 47824, lastServed: nil, routes: [])
        let brief = PairingChecklist.agentBrief(
            steps: steps,
            serving: true,
            port: 47824,
            routes: [],
            token: "SECRETTOKEN1234567890AB",
            revealToken: true,
            tailscaleAddress: "100.104.227.59",
            machineName: "TestBox"
        )

        XCTAssertTrue(brief.contains("SECRETTOKEN1234567890AB"))
        XCTAssertTrue(brief.contains("connected · 100.104.227.59"))
        XCTAssertTrue(brief.contains("curl.exe"))
    }

    func testPairURLListsLANThenTailnet() {
        let addresses = ["192.168.1.100", "100.104.227.59"]
        var endpoints: [String] = []
        if let lan = MirrorPairing.lanAddress(in: addresses) {
            endpoints.append("http://\(lan):47824")
        }
        if let tailnet = MirrorPairing.tailnetAddress(in: addresses) {
            endpoints.append("http://\(tailnet):47824")
        }

        XCTAssertEqual(endpoints, ["http://192.168.1.100:47824", "http://100.104.227.59:47824"])
        let pairURL = MirrorPairing.pairURL(endpoints: endpoints, token: "ABC")
        guard let parsed = MirrorPairing.parsePairURL(pairURL) else {
            XCTFail("Failed to parse pairURL")
            return
        }
        XCTAssertEqual(parsed.endpoints[0], "http://192.168.1.100:47824")
        XCTAssertEqual(parsed.endpoints[1], "http://100.104.227.59:47824")
    }

    func testPortChangeWarnsWhenNotDefault() {
        XCTAssertNil(PairingChecklist.portChangeWarning(port: 47824))
        XCTAssertNotNil(PairingChecklist.portChangeWarning(port: 50000))
    }
}
