import XCTest
@testable import InfinitusCore

final class MirrorDescriptorTests: XCTestCase {
    func testMachineIdIsMintedOnceAndKept() {
        let defaults = UserDefaults(suiteName: "descriptor-\(UUID().uuidString)")!
        let first = MachineIdentity.current(defaults: defaults)
        XCTAssertEqual(UUID(uuidString: first)?.uuidString, first)
        XCTAssertEqual(MachineIdentity.current(defaults: defaults), first)
    }

    func testDescriptorAdvertisesThisBuildAndOmitsUnknownCapabilities() throws {
        let d = MirrorDescriptor.current(machineId: "m1", label: "Studio", appVersion: "1.2.3")
        let text = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        XCTAssertTrue(text.contains(#""timeline":true"#))
        XCTAssertTrue(text.contains(#""attention":true"#))
        XCTAssertTrue(text.contains(#""sequence":true"#))
        XCTAssertTrue(text.contains(#""leases":true"#))
        // The phone gates its Files pill on this, never on the platform (#223).
        XCTAssertTrue(text.contains(#""files":true"#))
        #if os(macOS)
        XCTAssertEqual(d.platform, "macos")
        #else
        XCTAssertEqual(d.platform, "linux")
        #endif
        XCTAssertEqual(d.machineId, "m1")
        XCTAssertEqual(MirrorTransport.wellKnownPath, "/.well-known/infinitus")
        let older = try JSONDecoder().decode(MirrorDescriptor.self, from: Data(
            #"{"machineId":"m","label":"l","platform":"macos","appVersion":"0","capabilities":{}}"#.utf8))
        XCTAssertNil(older.capabilities.timeline)
        XCTAssertNil(older.capabilities.files)
    }

    /// #486 first slice: the tray answers the descriptor too, but only
    /// claims what `infinitus-tray serve` actually serves.
    func testTrayDescriptorClaimsOnlyFiles() throws {
        let d = MirrorDescriptor.tray(machineId: "m1", label: "omarchy-box", appVersion: "dev")
        XCTAssertEqual(d.platform, "linux")
        XCTAssertEqual(d.capabilities.files, true)
        for other in [d.capabilities.timeline, d.capabilities.sequence, d.capabilities.attention,
                     d.capabilities.leases, d.capabilities.ownedSessions, d.capabilities.checkpoints,
                     d.capabilities.team, d.capabilities.pastSessions, d.capabilities.images] {
            XCTAssertEqual(other, false)
        }
        let text = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        XCTAssertTrue(text.contains(#""timeline":false"#), text)
    }
}
