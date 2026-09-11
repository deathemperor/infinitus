import XCTest
@testable import InfinitusCore

final class WindowTelemetryTests: XCTestCase {
    private func win(_ pct: Double, resetsAt: Double?) -> UsageSample.Window {
        .init(pct: pct, resetsAt: resetsAt)
    }

    private func sample(t: Double, email: String = "a@x", number: Int = 1,
                        fh: UsageSample.Window? = nil) -> UsageSample {
        UsageSample(t: t, email: email, number: number,
                    fiveHour: fh, sevenDay: nil, scoped: nil)
    }

    func testTwoConsecutiveWindowsWithResetJump() {
        // Window 1: resetsAt 18000 (start 0), peaks at 40. Window 2 opens
        // on the jump, resetsAt 36000 (start 18000), peaks at 90, and is
        // still ticking as of `now`.
        let s = [sample(t: 100, fh: win(10, resetsAt: 18000)),
                 sample(t: 9000, fh: win(40, resetsAt: 18000)),
                 sample(t: 18100, fh: win(5, resetsAt: 36000)),
                 sample(t: 27000, fh: win(90, resetsAt: 36000))]
        let windows = WindowTelemetry.fiveHourWindows(s, now: 30000)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, 0)
        XCTAssertEqual(windows[0].resetsAt, 18000)
        XCTAssertEqual(windows[0].peakPct, 40)
        XCTAssertEqual(windows[0].samples, 2)
        XCTAssertTrue(windows[0].closed)
        XCTAssertEqual(windows[1].start, 18000)
        XCTAssertEqual(windows[1].resetsAt, 36000)
        XCTAssertEqual(windows[1].peakPct, 90)
        XCTAssertFalse(windows[1].closed)   // 36000 not past `now` (30000)
    }

    func testResetJitterWithinSlackStaysOneWindow() {
        let s = [sample(t: 100, fh: win(20, resetsAt: 18000)),
                 sample(t: 9000, fh: win(55, resetsAt: 18000.4)),  // sub-second jitter
                 sample(t: 17000, fh: win(60, resetsAt: 17950))]   // < 120s jitter
        let windows = WindowTelemetry.fiveHourWindows(s, now: 30000)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].peakPct, 60)
        XCTAssertEqual(windows[0].samples, 3)
    }

    func testWindowVanishesCloses() {
        let s = [sample(t: 100, fh: win(30, resetsAt: 18000)),
                 sample(t: 18100, fh: nil)]
        let windows = WindowTelemetry.fiveHourWindows(s, now: 30000)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows[0].closed)
        XCTAssertEqual(windows[0].peakPct, 30)
    }

    func testOpenWindowNotPastNowStaysOpen() {
        let s = [sample(t: 100, fh: win(20, resetsAt: 18000))]
        let windows = WindowTelemetry.fiveHourWindows(s, now: 9000)
        XCTAssertEqual(windows.count, 1)
        XCTAssertFalse(windows[0].closed)
        let closedNow = WindowTelemetry.fiveHourWindows(s, now: 19000)
        XCTAssertTrue(closedNow[0].closed)
    }

    func testSummaryCountsUnusedClosedWindows() {
        let s = [sample(t: 100, fh: win(2, resetsAt: 18000)),      // closed, unused (<5)
                 sample(t: 18100, fh: win(80, resetsAt: 36000)),   // closed, used
                 sample(t: 36100, fh: win(3, resetsAt: 54000))]    // still open
        let windows = WindowTelemetry.fiveHourWindows(s, now: 40000)
        XCTAssertEqual(windows.count, 3)
        let summary = WindowTelemetry.summary(windows)
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.meanPeak, (2 + 80 + 3) / 3, accuracy: 0.001)
        XCTAssertEqual(summary.unusedWindows, 1)   // the open one doesn't count
    }

    func testDailyRhythmBinsByLocalStartHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Starts at 1970-01-01 02:00 UTC and 1970-01-01 02:xx UTC (same
        // hour bucket), then 14:00 UTC.
        let w1 = FiveHourWindow(email: "a@x", number: 1, start: 2 * 3600,
                                resetsAt: 2 * 3600 + 18000, peakPct: 10,
                                samples: 1, closed: true)
        let w2 = FiveHourWindow(email: "a@x", number: 1, start: 2 * 3600 + 900,
                                resetsAt: 2 * 3600 + 900 + 18000, peakPct: 10,
                                samples: 1, closed: true)
        let w3 = FiveHourWindow(email: "a@x", number: 1, start: 14 * 3600,
                                resetsAt: 14 * 3600 + 18000, peakPct: 10,
                                samples: 1, closed: true)
        let hist = WindowTelemetry.dailyRhythm([w1, w2, w3], calendar: cal)
        XCTAssertEqual(hist[2], 2)
        XCTAssertEqual(hist[14], 1)
        XCTAssertEqual(hist.values.reduce(0, +), 3)
    }
}
