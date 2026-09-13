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
        XCTAssertTrue(text.contains(#""leases":true"#))
        XCTAssertTrue(text.contains(#""prefs":true"#))
        #if os(macOS)
        XCTAssertEqual(d.platform, "macos")
        #else
        XCTAssertEqual(d.platform, "linux")
        #endif
        XCTAssertEqual(d.machineId, "m1")
        XCTAssertEqual(MirrorTransport.wellKnownPath, "/.well-known/infinitus")
        let older = try JSONDecoder().decode(MirrorDescriptor.self, from: Data(
            #"{"machineId":"m","label":"l","platform":"macos","appVersion":"0","capabilities":{}}"#.utf8))
        XCTAssertNil(older.capabilities.leases)
        XCTAssertNil(older.capabilities.prefs)
    }

    /// It still only claims what a Linux session can deliver (no leases, …).
    func testTrayDescriptorClaimsWhatALinuxSessionServes() throws {
        let d = MirrorDescriptor.tray(machineId: "m1", label: "omarchy-box", appVersion: "dev")
        XCTAssertEqual(d.platform, "linux")
        for other in [d.capabilities.leases, d.capabilities.prefs] {
            XCTAssertEqual(other, false)
        }
        let text = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        XCTAssertTrue(text.contains(#""leases":false"#), text)
    }
}
