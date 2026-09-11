import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// Home's ages and thread keys; the session → `T3Thread` mapping is the
/// Core bridge's (T3ThreadBridgeTests), the list order `T3ThreadList`'s.
final class T3HomeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testRelativeTimeMatchesT3() {
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-30), now: now), "<1m")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-21 * 3600 - 59), now: now), "21h")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-3 * 86_400), now: now), "3d")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(60), now: now), "<1m")
    }

    func testThreadKeysByMac() {
        let s = SessionDetail(pid: 7, cwd: "/r/limitless", status: "idle", kind: "claude", startedAt: 900_000_000)
        let other = T3Thread(session: s, facts: nil, progress: nil, environmentId: T3HomeThreads.environmentId("mac-2"), now: now)
        let primary = T3Thread(session: s, facts: nil, progress: nil, environmentId: T3HomeThreads.environmentId(nil), now: now)
        XCTAssertEqual(other.key, "mac-2:pid:7")
        XCTAssertEqual(primary.key, "primary:pid:7")
        XCTAssertNotEqual(other.key, primary.key)
    }
}
