import XCTest
import InfinitusCore

// Weekly pace math and the adapter paths that supply account gauges.

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86400

private func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// A reset that leaves `elapsed` behind it in the current weekly cycle.
private func reset(elapsed: TimeInterval, cyclesAgo: Double = 0) -> String {
    iso(now.addingTimeInterval(Pace.weeklyPeriod - elapsed - cyclesAgo * Pace.weeklyPeriod))
}

final class PaceTests: XCTestCase {
    func testElapsedFromNextReset() {
        let pace = Pace.compute(pct: 50, resetsAt: reset(elapsed: day), fetchedAt: now)
        XCTAssertEqual(pace?.elapsed, day)
        XCTAssertEqual(pace?.expectedPct ?? 0, 100 / 7, accuracy: 0.0001)
    }

    /// A reset several cycles in the past still folds to this cycle's
    /// elapsed — a last-good reading is judged against its own clock.
    func testStaleResetFoldsToTheSameElapsed() {
        let pace = Pace.compute(pct: 50, resetsAt: reset(elapsed: day, cyclesAgo: 2), fetchedAt: now)
        XCTAssertEqual(pace?.elapsed, day)
    }

    /// The reset second itself: no elapsed span, so no rate to read.
    func testExactBoundaryIsSuppressed() {
        XCTAssertNil(Pace.compute(pct: 50, resetsAt: iso(now), fetchedAt: now))
    }

    /// A minute in is the floor, rather than suppressing the whole first day.
    func testMinimumElapsedSpan() {
        XCTAssertNil(Pace.compute(pct: 50, resetsAt: reset(elapsed: 59), fetchedAt: now))
        XCTAssertNotNil(Pace.compute(pct: 50, resetsAt: reset(elapsed: 60), fetchedAt: now))
        XCTAssertNotNil(Pace.compute(pct: 50, resetsAt: reset(elapsed: day / 2), fetchedAt: now))
    }

    func testFirstDayAheadAndBehindSignals() throws {
        let at = reset(elapsed: day / 2) // expected ≈ 7.1%
        let ahead = Pace.applied(to: UsageWindow(pct: 33, resetsAt: at), fetchedAt: now)
        XCTAssertEqual(ahead.expectedPct ?? 0, 100 / 14, accuracy: 0.0001)
        XCTAssertEqual(ahead.aheadOfPace, true)
        XCTAssertGreaterThan(GaugeMath.burnHeat(usedPct: ahead.pct,
            expectedPct: ahead.expectedPct, ahead: ahead.aheadOfPace), 0)
        XCTAssertEqual(ahead.willLastToReset, false)
        XCTAssertNotNil(ahead.projectedExhaustionAt)

        let behind = Pace.applied(to: UsageWindow(pct: 1, resetsAt: at), fetchedAt: now)
        XCTAssertEqual(behind.aheadOfPace, false)
        XCTAssertGreaterThan(GaugeMath.chillDepth(usedPct: behind.pct,
            expectedPct: behind.expectedPct, ahead: behind.aheadOfPace), 0)
        XCTAssertEqual(behind.willLastToReset, true)

        // A small overshoot still does not trigger the ahead effect.
        let near = try XCTUnwrap(Pace.compute(pct: 10, resetsAt: at, fetchedAt: now))
        XCTAssertFalse(near.ahead)
    }

    func testUnusableInputs() {
        XCTAssertNil(Pace.compute(pct: 50, resetsAt: nil, fetchedAt: now))
        XCTAssertNil(Pace.compute(pct: 50, resetsAt: "not a date", fetchedAt: now))
    }

    func testAheadThreshold() {
        let at = reset(elapsed: day)  // expected ≈ 14.3%
        XCTAssertEqual(Pace.compute(pct: 50, resetsAt: at, fetchedAt: now)?.ahead, true)
        XCTAssertEqual(Pace.compute(pct: 20, resetsAt: at, fetchedAt: now)?.ahead, false)
        XCTAssertEqual(Pace.compute(pct: 5, resetsAt: at, fetchedAt: now)?.ahead, false)
    }

    func testProjection() throws {
        let pace = try XCTUnwrap(Pace.compute(pct: 50, resetsAt: reset(elapsed: day), fetchedAt: now))
        // 50% in a day → the other 50% takes another day.
        XCTAssertEqual(try XCTUnwrap(Pace.exhaustsAt(pace, fetchedAt: now)).timeIntervalSince1970,
                       now.addingTimeInterval(day).timeIntervalSince1970, accuracy: 1)

        let full = try XCTUnwrap(Pace.compute(pct: 100, resetsAt: reset(elapsed: day), fetchedAt: now))
        XCTAssertEqual(Pace.exhaustsAt(full, fetchedAt: now), now)

        let idle = try XCTUnwrap(Pace.compute(pct: 0, resetsAt: reset(elapsed: day), fetchedAt: now))
        XCTAssertNil(Pace.exhaustsAt(idle, fetchedAt: now))
    }

    /// Ungated, unlike `ahead`: it flips the moment actual passes expected
    /// (bracketed rather than sat on — at the exact boundary
    /// `100/7 × 7` rounds a hair above 100).
    func testLastsToReset() throws {
        let at = reset(elapsed: day)
        let onPace = try XCTUnwrap(Pace.compute(pct: 100 / 7 - 0.1, resetsAt: at, fetchedAt: now))
        XCTAssertEqual(Pace.lastsToReset(onPace), true)
        let over = try XCTUnwrap(Pace.compute(pct: 100 / 7 + 0.1, resetsAt: at, fetchedAt: now))
        XCTAssertEqual(Pace.lastsToReset(over), false)
        let idle = try XCTUnwrap(Pace.compute(pct: 0, resetsAt: at, fetchedAt: now))
        XCTAssertEqual(Pace.lastsToReset(idle), true)
    }

    /// The deliberate in-between band: not far enough ahead to burn, still
    /// on course to run out before the reset.
    func testBandBetweenMarkerAndRunningOut() throws {
        let pace = try XCTUnwrap(Pace.compute(pct: 25, resetsAt: reset(elapsed: day), fetchedAt: now))
        XCTAssertFalse(pace.ahead)
        XCTAssertEqual(Pace.lastsToReset(pace), false)
    }

    func testAppliedFillsTheWindowOrLeavesItAlone() {
        let window = UsageWindow(pct: 50, resetsAt: reset(elapsed: day))
        let paced = Pace.applied(to: window, fetchedAt: now)
        XCTAssertEqual(paced.aheadOfPace, true)
        XCTAssertEqual(paced.expectedPct ?? 0, 100 / 7, accuracy: 0.0001)
        XCTAssertNotNil(paced.projectedExhaustionAt)
        XCTAssertEqual(paced.willLastToReset, false)
        XCTAssertEqual(paced.pct, window.pct)

        let fresh = Pace.applied(to: UsageWindow(pct: 50, resetsAt: iso(now)), fetchedAt: now)
        XCTAssertNil(fresh.expectedPct)
        XCTAssertNil(fresh.aheadOfPace)
    }

    // MARK: - The engines that needed it (#125 was swapd-only)

    func testNineRouterWeeklyWindowsCarryPace() throws {
        let at = reset(elapsed: day / 2)
        let json = """
        {"quotas": {"session (5h)": {"used": 50, "resetAt": "\(at)"},
                    "weekly (7d)": {"used": 50, "resetAt": "\(at)"},
                    "weekly opus (7d)": {"used": 50, "resetAt": "\(at)"}}}
        """
        guard case .ok(let usage, _) = NineRouterUsage.parse(Data(json.utf8), now: now) else {
            return XCTFail("expected quotas")
        }
        XCTAssertEqual(usage?.sevenDay?.aheadOfPace, true)
        XCTAssertEqual(usage?.scoped?.first?.aheadOfPace, true)
        // A 5h window resets too fast for pace to say anything.
        XCTAssertNil(usage?.fiveHour?.aheadOfPace)
    }

    func testProxyWeeklyWindowsCarryPace() throws {
        let at = reset(elapsed: day / 2)
        let json = """
        {"five_hour": {"utilization": 50, "resets_at": "\(at)"},
         "seven_day": {"utilization": 50, "resets_at": "\(at)"},
         "limits": [{"scope": {"model": {"display_name": "Opus"}},
                     "percent": 50, "resets_at": "\(at)"}]}
        """
        let usage = try XCTUnwrap(OAuthUsage.parse(Data(json.utf8), now: now))
        XCTAssertEqual(usage.sevenDay?.aheadOfPace, true)
        XCTAssertEqual(usage.scoped?.first?.aheadOfPace, true)
        XCTAssertNil(usage.fiveHour?.aheadOfPace)
    }
}
