import XCTest
@testable import InfinitusCore

final class T3ThreadSettledTests: XCTestCase {
    private func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private let NOW = ISO8601DateFormatter().date(from: "2026-06-02T00:00:00Z")!
    private func t(_ build: (inout T3Thread) -> Void = { _ in }) -> T3Thread {
        var x = T3Thread(id: "t", title: "T", createdAt: d("2026-06-01T00:00:00Z"), updatedAt: d("2026-06-01T00:00:00Z"))
        build(&x); return x
    }

    // hasQueuedTurnStart
    func testQueuedTurnStartRequiresAFreshMessageNoTurnHasAdopted() {
        let msg = NOW.addingTimeInterval(-30)
        XCTAssertTrue(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = msg }, now: NOW))
        // adopted: the turn's requestedAt equals the message time
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = msg; $0.latestTurn = .init(state: .running, requestedAt: msg, startedAt: nil, completedAt: nil) }, now: NOW))
        // older turn than the message: still queued
        XCTAssertTrue(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = msg; $0.latestTurn = .init(state: .completed, requestedAt: msg.addingTimeInterval(-600), startedAt: nil, completedAt: msg.addingTimeInterval(-500)) }, now: NOW))
    }
    func testQueuedTurnStartIsBoundedBothWays() {
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = NOW.addingTimeInterval(-121) }, now: NOW))
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = NOW.addingTimeInterval(121) }, now: NOW))   // clock ahead
        XCTAssertTrue(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = NOW.addingTimeInterval(119) }, now: NOW))
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = NOW.addingTimeInterval(-30); $0.session = .init(status: .error, updatedAt: NOW) }, now: NOW))
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(t(), now: NOW))
    }

    // effectiveSnoozed / raisedHand
    func testSnoozedUntilTheWakeTime() {
        let s = t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.snoozedAt = d("2026-06-01T12:00:00Z") }
        XCTAssertTrue(T3ThreadSettled.effectiveSnoozed(s, now: NOW))
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(s, now: d("2026-06-03T09:00:00Z")))   // wakeAt <= now
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(t(), now: NOW))
    }
    func testARaisedHandEndsTheSnooze() {
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.hasPendingApprovals = true }, now: NOW))
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.hasPendingUserInput = true }, now: NOW))
        // a fresh failure raises the hand; a failure older than the snooze does not
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.snoozedAt = d("2026-06-01T12:00:00Z"); $0.session = .init(status: .error, updatedAt: d("2026-06-01T13:00:00Z")) }, now: NOW))
        XCTAssertTrue(T3ThreadSettled.effectiveSnoozed(t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.snoozedAt = d("2026-06-01T12:00:00Z"); $0.session = .init(status: .error, updatedAt: d("2026-06-01T11:00:00Z")) }, now: NOW))
        // a turn completing after the snooze raises the hand
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.snoozedAt = d("2026-06-01T12:00:00Z"); $0.latestTurn = .init(state: .completed, requestedAt: d("2026-06-01T12:30:00Z"), startedAt: nil, completedAt: d("2026-06-01T12:40:00Z")) }, now: NOW))
    }
    func testWokeAt() {
        let snoozed = t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.snoozedAt = d("2026-06-01T12:00:00Z") }
        XCTAssertNil(T3ThreadSettled.wokeAt(snoozed, now: NOW))
        XCTAssertEqual(T3ThreadSettled.wokeAt(snoozed, now: d("2026-06-03T10:00:00Z")), d("2026-06-03T09:00:00Z"))
        let completed = t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.snoozedAt = d("2026-06-01T12:00:00Z"); $0.latestTurn = .init(state: .completed, requestedAt: d("2026-06-01T12:30:00Z"), startedAt: nil, completedAt: d("2026-06-01T12:40:00Z")) }
        XCTAssertEqual(T3ThreadSettled.wokeAt(completed, now: NOW), d("2026-06-01T12:40:00Z"))
        let failed = t { $0.snoozedUntil = d("2026-06-03T09:00:00Z"); $0.snoozedAt = d("2026-06-01T12:00:00Z"); $0.session = .init(status: .error, updatedAt: d("2026-06-01T13:00:00Z")) }
        XCTAssertEqual(T3ThreadSettled.wokeAt(failed, now: NOW), d("2026-06-01T13:00:00Z"))
    }

    // canSnooze + gate expiry
    func testCanSnoozeUnlessBlockedOrQueued() {
        XCTAssertTrue(T3ThreadSettled.canSnooze(t(), now: NOW))
        XCTAssertFalse(T3ThreadSettled.canSnooze(t { $0.hasPendingApprovals = true }, now: NOW))
        XCTAssertFalse(T3ThreadSettled.canSnooze(t { $0.latestUserMessageAt = NOW.addingTimeInterval(-10) }, now: NOW))
        XCTAssertEqual(T3ThreadSettled.snoozeGateExpiry(t { $0.latestUserMessageAt = NOW.addingTimeInterval(-10) }, now: NOW), NOW.addingTimeInterval(110))
        XCTAssertNil(T3ThreadSettled.snoozeGateExpiry(t { $0.hasPendingUserInput = true; $0.latestUserMessageAt = NOW.addingTimeInterval(-10) }, now: NOW))
        XCTAssertNil(T3ThreadSettled.snoozeGateExpiry(t(), now: NOW))
    }

    // snoozeWakeLabel — minutes round up, never "0m"
    func testWakeLabel() {
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: NOW.addingTimeInterval(1), now: NOW), "1m")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: NOW.addingTimeInterval(59 * 60 + 1), now: NOW), "60m")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: NOW.addingTimeInterval(3600), now: NOW), "1h")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: NOW.addingTimeInterval(3600 * 5.5), now: NOW), "6h")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: NOW.addingTimeInterval(86400 * 2.2), now: NOW), "3d")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: NOW, now: NOW), "now")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: NOW.addingTimeInterval(-5), now: NOW), "now")
    }

    // snoozePresets — evening only while it is >1h away; Sunday collapses next-week into tomorrow
    func testPresetsMorningWeekday() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let wed10 = d("2026-06-03T10:00:00Z")   // Wednesday
        let p = T3ThreadSettled.snoozePresets(now: wed10, calendar: cal)
        XCTAssertEqual(p.map(\.id), [.hour, .threeHours, .evening, .tomorrow, .nextWeek])
        XCTAssertEqual(p[0].snoozedUntil, d("2026-06-03T11:00:00Z"))
        XCTAssertEqual(p[2].snoozedUntil, d("2026-06-03T18:00:00Z"))
        XCTAssertEqual(p[3].snoozedUntil, d("2026-06-04T09:00:00Z"))
        XCTAssertEqual(p[4].snoozedUntil, d("2026-06-08T09:00:00Z"))   // next Monday
        XCTAssertEqual(p.map(\.label), ["In 1 hour", "In 3 hours", "This evening", "Tomorrow", "Next week"])
    }
    func testPresetsLateEveningAndSunday() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let wed1730 = d("2026-06-03T17:30:00Z")
        XCTAssertEqual(T3ThreadSettled.snoozePresets(now: wed1730, calendar: cal).map(\.id), [.hour, .threeHours, .tomorrow, .nextWeek])
        let wed20 = d("2026-06-03T20:00:00Z")   // past evening: no "This evening" (and never tomorrow's 18:00)
        XCTAssertEqual(T3ThreadSettled.snoozePresets(now: wed20, calendar: cal).map(\.id), [.hour, .threeHours, .tomorrow, .nextWeek])
        XCTAssertEqual(T3ThreadSettled.snoozePresets(now: wed20, calendar: cal)[2].snoozedUntil, d("2026-06-04T09:00:00Z"))
        let sun = d("2026-06-07T10:00:00Z")   // Sunday: tomorrow == next Monday
        XCTAssertEqual(T3ThreadSettled.snoozePresets(now: sun, calendar: cal).map(\.id), [.hour, .threeHours, .evening, .tomorrow])
    }

    // The exact grace boundary: upstream's `Math.abs(nowMs - messageAt) > QUEUED_TURN_START_GRACE_MS`
    // excludes only strictly-greater-than-120s ages — exactly 120s either side is still queued.
    func testQueuedTurnStartGraceBoundaryIsInclusiveAtExactly120Seconds() {
        XCTAssertTrue(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = NOW.addingTimeInterval(-120) }, now: NOW))
        XCTAssertTrue(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = NOW.addingTimeInterval(120) }, now: NOW))
    }

    // MARK: - Transcribed from threadSnoozed.test.ts (the real upstream suite for
    // threadSettled.ts — packages/client-runtime/src/state/threadSnoozed.test.ts).
    // One XCTest per `it`, titles kept as lowerCamel method names. `makeShell`'s
    // fixtures: NOW2 = 2026-04-10T12:00Z, SNOOZED_AT2 = 09:00Z (default snoozedAt
    // once snoozedUntil is set), FUTURE_WAKE2 = next day 09:00Z, PAST_WAKE2 = 10:00Z;
    // a session, when present, always stamps updatedAt at 11:00Z, matching upstream.
    // Upstream's "never hides / never reads on malformed ... data" cases have no
    // Swift analogue: `Date` isn't a string, so a malformed timestamp can't reach
    // these functions at all (the port's parse boundary maps it to nil, already
    // exercised by the "no snooze state" / "still-snoozed" nil cases below).

    private let NOW2 = ISO8601DateFormatter().date(from: "2026-04-10T12:00:00Z")!
    private let SNOOZED_AT2 = ISO8601DateFormatter().date(from: "2026-04-10T09:00:00Z")!
    private let FUTURE_WAKE2 = ISO8601DateFormatter().date(from: "2026-04-11T09:00:00Z")!
    private let PAST_WAKE2 = ISO8601DateFormatter().date(from: "2026-04-10T10:00:00Z")!

    private func shell(snoozedUntil: Date? = nil, snoozedAt: Date? = nil, sessionStatus: T3Thread.SessionStatus? = nil,
                        pendingApproval: Bool = false, pendingUserInput: Bool = false, turnCompletedAt: Date? = nil) -> T3Thread {
        t {
            $0.snoozedUntil = snoozedUntil
            $0.snoozedAt = snoozedAt ?? (snoozedUntil != nil ? SNOOZED_AT2 : nil)
            $0.hasPendingApprovals = pendingApproval
            $0.hasPendingUserInput = pendingUserInput
            if let sessionStatus { $0.session = .init(status: sessionStatus, updatedAt: d("2026-04-10T11:00:00Z")) }
            if let turnCompletedAt { $0.latestTurn = .init(state: .completed, requestedAt: SNOOZED_AT2, startedAt: nil, completedAt: turnCompletedAt) }
        }
    }

    // describe("effectiveSnoozed")
    func testHidesAThreadWhoseWakeTimeIsInTheFuture() {
        XCTAssertTrue(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: FUTURE_WAKE2), now: NOW2))
    }
    func testStopsClassifyingAsSnoozedOnceTheWakeTimePasses() {
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: PAST_WAKE2), now: NOW2))
    }
    func testNeverSnoozesAThreadWithNoSnoozeState() {
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(shell(), now: NOW2))
    }
    func testWakesEarlyWhenTheAgentIsBlockedOnTheUser() {
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: FUTURE_WAKE2, pendingApproval: true), now: NOW2))
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: FUTURE_WAKE2, pendingUserInput: true), now: NOW2))
    }
    func testWakesEarlyOnAFailureThatHappenedAfterTheSnooze() {
        // shell stamps session.updatedAt at 11:00, after the default snoozedAt (9:00).
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: FUTURE_WAKE2, sessionStatus: .error), now: NOW2))
    }
    func testStaysSnoozedWhenTheFailurePredatesTheSnoozeTheUserSawIt() {
        XCTAssertTrue(T3ThreadSettled.effectiveSnoozed(
            shell(snoozedUntil: FUTURE_WAKE2, snoozedAt: d("2026-04-10T11:30:00Z"), sessionStatus: .error), now: NOW2))
    }
    func testStaysSnoozedWhileTheSessionKeepsWorkingSnoozeNeverPausesTheAgent() {
        XCTAssertTrue(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: FUTURE_WAKE2, sessionStatus: .running), now: NOW2))
    }
    func testWakesEarlyWhenARunCompletesAfterTheSnoozeWasSet() {
        XCTAssertFalse(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: FUTURE_WAKE2, turnCompletedAt: d("2026-04-10T10:30:00Z")), now: NOW2))
    }
    func testIgnoresRunsThatCompletedBeforeTheSnoozeTheUserSawThatResult() {
        XCTAssertTrue(T3ThreadSettled.effectiveSnoozed(shell(snoozedUntil: FUTURE_WAKE2, turnCompletedAt: d("2026-04-10T08:00:00Z")), now: NOW2))
    }

    // describe("threadRaisedHandWhileSnoozed")
    func testIsFalseForAQuietSnoozedThread() {
        XCTAssertFalse(T3ThreadSettled.raisedHandWhileSnoozed(shell(snoozedUntil: FUTURE_WAKE2)))
    }
    func testIsTrueForApprovalsInputAndFailures() {
        XCTAssertTrue(T3ThreadSettled.raisedHandWhileSnoozed(shell(snoozedUntil: FUTURE_WAKE2, pendingApproval: true)))
        XCTAssertTrue(T3ThreadSettled.raisedHandWhileSnoozed(shell(snoozedUntil: FUTURE_WAKE2, pendingUserInput: true)))
        XCTAssertTrue(T3ThreadSettled.raisedHandWhileSnoozed(shell(snoozedUntil: FUTURE_WAKE2, sessionStatus: .error)))
    }

    // describe("canSnooze")
    func testAllowsSnoozingQuietAndWorkingThreadsAlike() {
        XCTAssertTrue(T3ThreadSettled.canSnooze(shell(), now: NOW2))
        XCTAssertTrue(T3ThreadSettled.canSnooze(shell(sessionStatus: .running), now: NOW2))
    }
    func testRefusesBlockedOnYouWork() {
        XCTAssertFalse(T3ThreadSettled.canSnooze(shell(pendingApproval: true), now: NOW2))
        XCTAssertFalse(T3ThreadSettled.canSnooze(shell(pendingUserInput: true), now: NOW2))
    }
    func testRefusesAQueuedTurnStartSameInvisiblePendingWorkRuleAsSettle() {
        // Fresh user message, no turn has adopted it, within the grace window.
        XCTAssertFalse(T3ThreadSettled.canSnooze(t { $0.latestUserMessageAt = d("2026-04-10T11:59:30Z") }, now: NOW2))
        // Outside the grace window the message is stale data, not queued work.
        XCTAssertTrue(T3ThreadSettled.canSnooze(t { $0.latestUserMessageAt = d("2026-04-10T11:00:00Z") }, now: NOW2))
    }

    // describe("hasQueuedTurnStart")
    func testExpiresQueuedStateAfterTwoMinutes() {
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(t { $0.latestUserMessageAt = d("2026-04-10T11:57:59Z") }, now: NOW2))
    }
    func testClearsQueuedStateWhenATurnAdoptsTheMessageOrTheSessionFails() {
        let messageAt = d("2026-04-10T11:59:00Z")
        let adopted = t { $0.latestUserMessageAt = messageAt; $0.latestTurn = .init(state: .running, requestedAt: messageAt, startedAt: nil, completedAt: nil) }
        let failed = t { $0.latestUserMessageAt = messageAt; $0.session = .init(status: .error, updatedAt: NOW2) }
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(adopted, now: NOW2))
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(failed, now: NOW2))
    }
    func testBoundsFutureClientClockSkew() {
        let farAhead = t { $0.latestUserMessageAt = d("2026-04-10T12:03:00Z") }
        let slightlyAhead = t { $0.latestUserMessageAt = d("2026-04-10T12:01:00Z") }
        XCTAssertFalse(T3ThreadSettled.hasQueuedTurnStart(farAhead, now: NOW2))
        XCTAssertTrue(T3ThreadSettled.hasQueuedTurnStart(slightlyAhead, now: NOW2))
    }

    // describe("threadWokeAt")
    func testIsNullForNeverSnoozedAndStillSnoozedThreads() {
        XCTAssertNil(T3ThreadSettled.wokeAt(shell(), now: NOW2))
        XCTAssertNil(T3ThreadSettled.wokeAt(shell(snoozedUntil: FUTURE_WAKE2), now: NOW2))
    }
    func testReportsTheWakeTimeForATimerWake() {
        XCTAssertEqual(T3ThreadSettled.wokeAt(shell(snoozedUntil: PAST_WAKE2), now: NOW2), PAST_WAKE2)
    }
    func testReportsTheCompletionTimeForAnEarlyRunCompletedWake() {
        XCTAssertEqual(T3ThreadSettled.wokeAt(shell(snoozedUntil: FUTURE_WAKE2, turnCompletedAt: d("2026-04-10T10:30:00Z")), now: NOW2), d("2026-04-10T10:30:00Z"))
    }
    func testFallsBackToSessionActivityForBlockedFailedEarlyWakes() {
        XCTAssertEqual(T3ThreadSettled.wokeAt(shell(snoozedUntil: FUTURE_WAKE2, sessionStatus: .error), now: NOW2), d("2026-04-10T11:00:00Z"))
    }
    func testKeepsTheEarlyWakeAuthoritativeAfterTheScheduledTimePasses() {
        // Woke early at 09:30 via run-completed; the scheduled wake (PAST_WAKE2
        // 10:00, relative to a later now) has ALSO passed. Reporting the scheduled
        // time would resurface a Woke indicator the user already cleared by
        // visiting between the early wake and now.
        XCTAssertEqual(T3ThreadSettled.wokeAt(shell(snoozedUntil: PAST_WAKE2, turnCompletedAt: d("2026-04-10T09:30:00Z")), now: NOW2), d("2026-04-10T09:30:00Z"))
    }

    // describe("snoozeWakeLabel")
    func testFormatsRemainingTimeCoarselyRoundingUp() {
        let now3 = d("2026-06-02T00:00:00Z")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: d("2026-06-02T00:30:00Z"), now: now3), "30m")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: d("2026-06-02T01:30:00Z"), now: now3), "2h")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: d("2026-06-03T02:00:00Z"), now: now3), "2d")
    }
    func testNeverReadsZeroOrNegativeWhileStillSnoozed() {
        let now3 = d("2026-06-02T00:00:00Z")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: d("2026-06-02T00:00:30Z"), now: now3), "1m")
        XCTAssertEqual(T3ThreadSettled.snoozeWakeLabel(until: d("2026-06-01T23:59:59Z"), now: now3), "now")
    }

    // describe("resolveSnoozePresets")
    func testOffersTheSharedDesktopAndMobileChoices() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let presets = T3ThreadSettled.snoozePresets(now: d("2026-04-08T10:00:00Z"), calendar: cal)
        XCTAssertEqual(presets.map(\.id), [.hour, .threeHours, .evening, .tomorrow, .nextWeek])
        XCTAssertEqual(presets.first { $0.id == .threeHours }?.snoozedUntil, d("2026-04-08T13:00:00Z"))
        XCTAssertEqual(presets.first { $0.id == .threeHours }?.label, "In 3 hours")
        XCTAssertEqual(presets.first { $0.id == .evening }?.label, "This evening")
        let tomorrow = presets.first { $0.id == .tomorrow }!.snoozedUntil
        XCTAssertEqual(cal.component(.hour, from: tomorrow), 9)
    }
    func testDropsTheEveningChoiceOnceEveningIsNearOrPast() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(T3ThreadSettled.snoozePresets(now: d("2026-04-08T17:30:00Z"), calendar: cal).map(\.id), [.hour, .threeHours, .tomorrow, .nextWeek])
    }
    func testPutsNextWeekOnTheFollowingMonday() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        // 2026-04-06 IS a Monday: exercises the `% 7 == 0 -> 7` branch (today's
        // weekday already is Monday, so "next week" must land 7 days out, not 0).
        let presets = T3ThreadSettled.snoozePresets(now: d("2026-04-06T10:00:00Z"), calendar: cal)
        let nextWeek = presets.first { $0.id == .nextWeek }!.snoozedUntil
        XCTAssertEqual(cal.component(.weekday, from: nextWeek), 2)   // Monday
        XCTAssertEqual(cal.component(.day, from: nextWeek), 13)
    }
    func testDropsNextWeekOnSundaysWhenItLandsOnTheSameMondayAsTomorrow() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        // Sunday 2026-08-30 07:01: "Tomorrow" and "Next week" are both Monday 9:00.
        let presets = T3ThreadSettled.snoozePresets(now: d("2026-08-30T07:01:00Z"), calendar: cal)
        XCTAssertEqual(presets.map(\.id), [.hour, .threeHours, .evening, .tomorrow])
        let tomorrow = presets.first { $0.id == .tomorrow }!.snoozedUntil
        XCTAssertEqual(cal.component(.weekday, from: tomorrow), 2)   // Monday
    }
}
