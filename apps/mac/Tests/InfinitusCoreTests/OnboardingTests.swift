import XCTest
@testable import InfinitusCore

#if !os(iOS)
final class SwapdLocatorTests: XCTestCase {
    func testBundledEngineOutranksACopyOnPath() {
        let paths = SwapdLocator.defaultCandidates(home: "/fixture", bundledExecutableDirectory: "/fixture/Infinitus.app/Contents/MacOS")
        let bundled = "/fixture/Infinitus.app/Contents/MacOS/swapd"
        XCTAssertEqual(SwapdLocator.locate(candidates: paths, exists: { $0 == bundled }), bundled)
        // A stale `cargo install` on PATH must not shadow the release's engine (#1530).
        XCTAssertEqual(SwapdLocator.locate(candidates: paths, exists: { $0 == bundled || $0 == "/fixture/.cargo/bin/swapd" }), bundled)
        // A source build with nothing beside it still finds the PATH copy.
        XCTAssertEqual(SwapdLocator.locate(candidates: paths, exists: { $0 == "/fixture/.cargo/bin/swapd" }), "/fixture/.cargo/bin/swapd")
        XCTAssertNil(SwapdLocator.locate(candidates: paths, exists: { _ in false }))
    }
}
#endif
