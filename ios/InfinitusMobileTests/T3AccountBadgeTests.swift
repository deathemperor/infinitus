import XCTest
@testable import InfinitusMobile

/// `providerInstanceInitials` (T3 `ProviderInstanceIcon.tsx:7`) and the
/// badge's own rule: only a Mac with several accounts gets one.
final class T3AccountBadgeTests: XCTestCase {
    func testInitialsFollowT3() {
        XCTAssertEqual(T3AccountBadge.initials("work"), "WO")
        XCTAssertEqual(T3AccountBadge.initials("Personal Max"), "PM")
        XCTAssertEqual(T3AccountBadge.initials("team_alpha-two"), "TA")
        XCTAssertEqual(T3AccountBadge.initials("  "), "")
    }
}
