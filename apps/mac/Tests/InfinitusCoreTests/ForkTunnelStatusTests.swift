import XCTest
@testable import InfinitusCore

final class ForkTunnelStatusTests: XCTestCase {
    private func state(enabled: Bool = true, port: Int = 3773, allowed: Bool = true, available: Bool = true,
                       running: Bool = false, url: String? = nil) -> ForkTunnelStatus.State {
        ForkTunnelStatus.derive(enabled: enabled, port: port, allowed: allowed, available: available,
                                running: running, url: url).state
    }

    /// First reason wins, in the order a user would fix them.
    func testTheStateFollowsTheFirstBlockingReason() {
        XCTAssertEqual(state(enabled: false, port: 0, allowed: false, available: false), .off)
        XCTAssertEqual(state(port: 0, allowed: false, available: false), .invalidPort)
        XCTAssertEqual(state(port: 65536), .invalidPort)
        XCTAssertEqual(state(allowed: false, available: false, url: "https://x.trycloudflare.com"), .blocked)
        XCTAssertEqual(state(available: false, running: true), .unavailable)
        XCTAssertEqual(state(running: true, url: "https://a-b.trycloudflare.com"), .up)
        XCTAssertEqual(state(running: true), .starting)
        XCTAssertEqual(state(), .stopped)
    }

    func testTheURLAndHostnameAreReportedOnlyWhileUp() {
        let up = ForkTunnelStatus.derive(enabled: true, port: 3773, allowed: true, available: true,
                                         running: true, url: "https://a-b.trycloudflare.com")
        XCTAssertEqual(up.url, "https://a-b.trycloudflare.com")
        XCTAssertEqual(up.hostname, "a-b.trycloudflare.com")
        let blocked = ForkTunnelStatus.derive(enabled: true, port: 3773, allowed: false, available: true,
                                              running: true, url: "https://a-b.trycloudflare.com")
        XCTAssertNil(blocked.url)
        XCTAssertNil(blocked.hostname)
    }

    func testThePortRangeAndT3sDefault() {
        XCTAssertEqual(ForkTunnelStatus.defaultPort, 3773)
        XCTAssertTrue(ForkTunnelStatus.isValidPort(1))
        XCTAssertTrue(ForkTunnelStatus.isValidPort(65535))
        XCTAssertFalse(ForkTunnelStatus.isValidPort(0))
        XCTAssertFalse(ForkTunnelStatus.isValidPort(65536))
    }

    /// The `status` reply's `forkTunnel` keys, as documented in the manifest.
    func testTheStatusEncodesTheDocumentedKeys() throws {
        let status = ForkTunnelStatus(enabled: true, port: 3774, state: .up, url: "https://a-b.trycloudflare.com")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        XCTAssertEqual(json?["enabled"] as? Bool, true)
        XCTAssertEqual(json?["port"] as? Int, 3774)
        XCTAssertEqual(json?["state"] as? String, "up")
        XCTAssertEqual(json?["url"] as? String, "https://a-b.trycloudflare.com")
        XCTAssertEqual(json?["hostname"] as? String, "a-b.trycloudflare.com")
        let off = ForkTunnelStatus(enabled: false, port: 3773, state: .off, url: nil)
        let offJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any]
        XCTAssertNil(offJSON?["url"])
        XCTAssertEqual(offJSON?["state"] as? String, "off")
    }
}
