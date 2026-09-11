#if os(macOS) || os(Linux)
import XCTest
@testable import InfinitusCore

/// The real socket on this host: an advertiser and a browser in one
/// process hear each other through multicast loopback. Skipped where
/// the host has no multicast (a container without a multicast route,
/// or `INFINITUS_SKIP_MDNS` set) — the pure tests cover the logic.
final class MDNSSocketTests: XCTestCase {
    func testAdvertiserIsFoundByTheBrowser() throws {
        if ProcessInfo.processInfo.environment["INFINITUS_SKIP_MDNS"] != nil { throw XCTSkip("INFINITUS_SKIP_MDNS set") }
        let instance = "infinitus-test-" + String(UUID().uuidString.prefix(8))
        let service = MDNS.Service(instance: instance, host: MDNS.hostLabel(instance), port: 1,
                                   txt: NearbyRecord.hidden.txtStrings, ipv4: "127.0.0.1")
        let advertiser: MDNS.Advertiser
        do {
            advertiser = try MDNS.Advertiser(service: service)
            try advertiser.start()
        } catch {
            throw XCTSkip("no multicast here: \(error)")
        }
        defer { advertiser.stop() }
        let peers: [MDNS.Peer]
        do { peers = try MDNS.browse(seconds: 2) } catch { throw XCTSkip("no multicast here: \(error)") }
        // A host whose multicast route swallows loopback hears nobody:
        // that is the environment, not the code. Seeing peers but not
        // our own instance is the real failure.
        if peers.isEmpty { throw XCTSkip("no multicast loopback here: browsed nothing in 2 s") }
        let mine = try XCTUnwrap(peers.first { $0.instance == instance }, "peers seen: \(peers.map(\.instance))")
        XCTAssertEqual(mine.port, 1)
        XCTAssertEqual(mine.txt, ["d=0"])
        XCTAssertEqual(mine.ipv4, "127.0.0.1")
        XCTAssertEqual(mine.host, MDNS.hostLabel(instance) + ".local.")
    }
}
#endif
