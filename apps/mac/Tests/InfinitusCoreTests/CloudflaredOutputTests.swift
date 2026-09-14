import XCTest
@testable import InfinitusCore

final class CloudflaredOutputTests: XCTestCase {
    func testQuickTunnelURLIsPulledOutOfTheBoxedLine() {
        let line = "2026-01-01T00:00:00Z INF |  https://tall-oak-1234.trycloudflare.com    |"
        XCTAssertEqual(CloudflaredOutput.quickTunnelURL(in: line),
                       "https://tall-oak-1234.trycloudflare.com")
        XCTAssertNil(CloudflaredOutput.quickTunnelURL(
            in: "INF |  https://api.trycloudflare.com/docs  |"))
        XCTAssertNil(CloudflaredOutput.quickTunnelURL(in: "INF starting tunnel"))
    }
}
