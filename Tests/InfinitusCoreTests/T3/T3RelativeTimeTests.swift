import XCTest
@testable import InfinitusCore

/// Transcribed from `apps/web/src/timestampFormat.ts`'s `formatRelativeTime`
/// (the function `Sidebar.tsx`'s `threadTimeLabel`/`settledTimeLabel` both
/// go through, via `compactSidebarTimeLabel`): pure elapsed-duration math,
/// no `Intl`/calendar involved, so — unlike `T3ThreadSettled.snoozePresets`
/// — there is no Calendar/TimeZone to pin here. `timestampFormat.test.ts`
/// carries no dedicated `describe("formatRelativeTime", …)` data table (only
/// the invalid-input and one `getRelativeTimeState` case); this table
/// transcribes those plus every boundary the source's own if-chain implies.
/// Upstream never falls back to an absolute calendar date (no "Sep 2" case
/// exists in the ported function — days count up unbounded), so the brief's
/// speculative date-fallback example is skipped; see the task report.
final class T3RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    // (seconds before `now`, expected label); a negative value is `now` ahead of `date`.
    private let cases: [(seconds: TimeInterval, expected: String)] = [
        (-5, "now"),          // clock skew: `date` in the future reads "now", not negative
        (0, "now"),
        (59, "now"),
        (60, "1m"),
        (119, "1m"),
        (120, "2m"),
        (900, "15m"),         // timestampFormat.test.ts "returns relative parts for valid timestamps"
        (3599, "59m"),
        (3600, "1h"),
        (86399, "23h"),
        (86400, "1d"),
        (172800, "2d"),
        (30 * 86400, "30d"),  // no month/year fallback upstream — unbounded day count
    ]

    func testLabelMatchesUpstreamsBoundaries() {
        for c in cases {
            let date = now.addingTimeInterval(-c.seconds)
            XCTAssertEqual(T3RelativeTime.label(from: date, now: now), c.expected, "seconds=\(c.seconds)")
        }
    }
}
