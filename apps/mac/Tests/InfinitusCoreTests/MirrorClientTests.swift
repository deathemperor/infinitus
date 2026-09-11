import XCTest
@testable import InfinitusCore

final class MirrorClientTests: XCTestCase {
    private func request(host: String, id: String? = "dev-1", name: String? = "Titan") -> MirrorTransport.Request {
        var headers = ["host": host]
        if let id { headers[MirrorClient.idHeader] = id }
        if let name { headers[MirrorClient.nameHeader] = name }
        return MirrorTransport.Request(method: "GET", target: "/snapshot", headers: headers)
    }

    func testRouteFromHost() {
        XCTAssertEqual(MirrorClient(request: request(host: "192.168.2.36:47824")).route, "Wi-Fi")
        XCTAssertEqual(MirrorClient(request: request(host: "100.101.3.9:47824")).route, "Tailscale")
        XCTAssertEqual(MirrorClient(request: request(host: "abc-def.trycloudflare.com")).route, "quick tunnel")
        XCTAssertEqual(MirrorClient(request: request(host: "tunnel.infinitus.run")).route, "tunnel.infinitus.run")
        XCTAssertEqual(MirrorClient(request: request(host: "infinitus")).route, "Wi-Fi")
    }

    func testLegacyPhoneWithoutHeaders() {
        let client = MirrorClient(request: request(host: "192.168.2.36:47824", id: nil, name: nil))
        XCTAssertEqual(client.id, "legacy")
        XCTAssertEqual(client.name, "a phone")
    }

    func testMergeKeepsOneRowPerDeviceNewestFirstAndCaps() {
        let now = Date()
        var list: [MirrorClient] = []
        for i in 0..<10 {
            list = MirrorClient.merge(MirrorClient(id: "d\(i)", name: "p", route: "Wi-Fi", lastSeen: now), into: list)
        }
        XCTAssertEqual(list.count, 8)
        XCTAssertEqual(list.first?.id, "d9")
        list = MirrorClient.merge(MirrorClient(id: "d5", name: "p", route: "Tailscale", lastSeen: now + 1), into: list)
        XCTAssertEqual(list.count, 8)
        XCTAssertEqual(list.first?.id, "d5")
        XCTAssertEqual(list.first?.route, "Tailscale")
        XCTAssertEqual(list.filter { $0.id == "d5" }.count, 1)
    }

    func testActiveWindow() {
        let client = MirrorClient(id: "d", name: "p", route: "Wi-Fi", lastSeen: Date())
        XCTAssertTrue(client.isActive())
        XCTAssertFalse(client.isActive(now: Date() + 120))
    }
}
