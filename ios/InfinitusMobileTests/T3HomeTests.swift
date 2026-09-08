import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// Home's shelves and ages (C-6), until A's list reducer replaces them.
final class T3HomeTests: XCTestCase {
    private func row(_ pid: Int, status: SessionListPresentation.Attention = .ready, ago: Double = 0,
                       pinnedAt: Date? = nil, snoozed: Bool = false, settled: Bool = false, title: String = "t") -> T3HomeEntry {
        T3HomeEntry(session: SessionDetail(pid: pid, cwd: "/r", status: "idle", kind: "claude", startedAt: 0), macId: nil,
                    title: title, repo: "r", branch: nil, macLabel: nil, status: status, pinnedAt: pinnedAt,
                    snoozed: snoozed, settled: settled, lastActivity: Date(timeIntervalSince1970: 10_000 - ago))
    }

    func testRelativeTimeMatchesT3() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-30), now: now), "<1m")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-21 * 3600 - 59), now: now), "21h")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(-3 * 86_400), now: now), "3d")
        XCTAssertEqual(T3Time.relative(now.addingTimeInterval(60), now: now), "<1m")
    }

    func testShelvesPinnedThenWaitingThenRecentAndTheRestByShelf() {
        let split = T3HomeShelves.split([
            row(1, ago: 10),
            row(2, status: .approval, ago: 500),
            row(3, ago: 900, pinnedAt: Date(timeIntervalSince1970: 1)),
            row(4, ago: 900, pinnedAt: Date(timeIntervalSince1970: 2), settled: true),
            row(5, ago: 5, snoozed: true),
            row(6, ago: 1, settled: true),
        ])
        XCTAssertEqual(split.live.map(\.session.pid), [4, 3, 2, 1])
        XCTAssertEqual(split.snoozed.map(\.session.pid), [5])
        XCTAssertEqual(split.settled.map(\.session.pid), [6])
    }

    func testSearchMatchesTitleRepoOrBranch() {
        let e = T3HomeEntry(session: SessionDetail(pid: 1, cwd: "/x/limitless", status: "idle", kind: "claude", startedAt: 0),
                            macId: nil, title: "Fix the flicker", repo: "limitless", branch: "t3-c6", macLabel: nil,
                            status: .ready, pinnedAt: nil, snoozed: false, settled: false, lastActivity: Date())
        XCTAssertTrue(T3HomeShelves.matches(e, search: "FLICK"))
        XCTAssertTrue(T3HomeShelves.matches(e, search: "c6"))
        XCTAssertTrue(T3HomeShelves.matches(e, search: "  "))
        XCTAssertFalse(T3HomeShelves.matches(e, search: "banyan"))
    }
}
