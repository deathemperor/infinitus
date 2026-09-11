import XCTest
import InfinitusUI
@testable import InfinitusMobile

/// Appearance → Text size: the pref clamps to upstream's 11…22 and drives
/// `T3Font.mobileScale` off the 16 pt reference.
@MainActor
final class T3TextSizeTests: XCTestCase {
    private func freshModel() -> MirrorModel {
        let suite = "t3-text-size-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MirrorModel(defaults: defaults)
    }

    override func tearDown() { T3Font.mobileScale = 1 }

    func testDefaultsToTheReferenceSize() {
        let model = freshModel()
        XCTAssertEqual(model.t3TextSize, 16)
        XCTAssertEqual(T3Font.mobileScale, 1)
    }

    func testTheSliderScalesTheMobileFonts() {
        let model = freshModel()
        model.t3TextSize = 20
        XCTAssertEqual(T3Font.mobileScale, 1.25, accuracy: 0.0001)
        model.t3TextSize = 30
        XCTAssertEqual(model.t3TextSize, 22)
        model.t3TextSize = 3
        XCTAssertEqual(model.t3TextSize, 11)
        XCTAssertEqual(T3Font.mobileScale, 11.0 / 16.0, accuracy: 0.0001)
    }
}
