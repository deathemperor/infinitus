import UIKit
import XCTest

/// The three DM Sans faces the T3 screens set (spec §3.2) are bundled and
/// registered through `UIAppFonts`; a missing one would silently fall back
/// to the system face and fail every parity capture.
final class T3FontsTests: XCTestCase {
    func testTheThreeDMSansFacesRegister() {
        for name in ["DMSans-Regular", "DMSans-Medium", "DMSans-Bold"] {
            XCTAssertNotNil(UIFont(name: name, size: 15), "\(name) is not registered")
        }
    }
}
