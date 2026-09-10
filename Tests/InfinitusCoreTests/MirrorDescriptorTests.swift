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
        // The PTY host is the Mac app's (#507 step 3); a Core build on Linux
        // links the same `.current()` and must still say no.
        XCTAssertEqual(d.capabilities.terminal, true)
        #else
        XCTAssertEqual(d.platform, "linux")
        XCTAssertEqual(d.capabilities.terminal, false)
        #endif
        XCTAssertEqual(d.machineId, "m1")
        XCTAssertEqual(MirrorTransport.wellKnownPath, "/.well-known/infinitus")
        let older = try JSONDecoder().decode(MirrorDescriptor.self, from: Data(
            #"{"machineId":"m","label":"l","platform":"macos","appVersion":"0","capabilities":{}}"#.utf8))
        XCTAssertNil(older.capabilities.timeline)
        XCTAssertNil(older.capabilities.files)
    }

    /// #486 slice 2 gave the tray timeline and sequence; slice 3 the
    /// control socket that writes checkpoints on Linux, so `checkpoints` is
    /// a claim now. It still only claims what a Linux session can deliver
    /// (no team, no leases, …).
    func testTrayDescriptorClaimsFilesTimelineSequenceAndCheckpoints() throws {
        let d = MirrorDescriptor.tray(machineId: "m1", label: "omarchy-box", appVersion: "dev")
        XCTAssertEqual(d.platform, "linux")
        for served in [d.capabilities.files, d.capabilities.timeline, d.capabilities.sequence,
                       d.capabilities.checkpoints] {
            XCTAssertEqual(served, true)
        }
        for other in [d.capabilities.attention, d.capabilities.leases, d.capabilities.ownedSessions,
                     d.capabilities.team, d.capabilities.pastSessions, d.capabilities.images,
                     d.capabilities.terminal] {
            XCTAssertEqual(other, false)
        }
        let text = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        XCTAssertTrue(text.contains(#""timeline":true"#), text)
        XCTAssertTrue(text.contains(#""checkpoints":true"#), text)
        XCTAssertTrue(text.contains(#""attention":false"#), text)
    }
}
