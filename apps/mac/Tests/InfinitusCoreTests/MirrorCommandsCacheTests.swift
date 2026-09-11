import XCTest
@testable import InfinitusCore

/// #486 slice 2: `MirrorCommandsCache` moved here from `Sources/Infinitus`
/// so the Mac and the Linux tray share one cache instead of two.
final class MirrorCommandsCacheTests: XCTestCase {
    func testHitWithinTTLSkipsMake() {
        let cache = MirrorCommandsCache()
        let now = Date()
        var makes = 0
        func make() -> Data? { makes += 1; return Data("fresh".utf8) }
        let first = cache.data(cwd: "/repo", now: now, make: make)
        let second = cache.data(cwd: "/repo", now: now.addingTimeInterval(2), make: make)
        XCTAssertEqual(first, Data("fresh".utf8))
        XCTAssertEqual(second, first)
        XCTAssertEqual(makes, 1)
    }

    func testPastTTLRebuilds() {
        let cache = MirrorCommandsCache()
        let now = Date()
        var makes = 0
        func make() -> Data? { makes += 1; return Data("v\(makes)".utf8) }
        _ = cache.data(cwd: "/repo", now: now, make: make)
        let later = cache.data(cwd: "/repo", now: now.addingTimeInterval(6), make: make)
        XCTAssertEqual(later, Data("v2".utf8))
        XCTAssertEqual(makes, 2)
    }

    func testDifferentCwdsCacheSeparately() {
        let cache = MirrorCommandsCache()
        let now = Date()
        _ = cache.data(cwd: "/a", now: now) { Data("a".utf8) }
        let b = cache.data(cwd: "/b", now: now) { Data("b".utf8) }
        XCTAssertEqual(b, Data("b".utf8))
    }
}
